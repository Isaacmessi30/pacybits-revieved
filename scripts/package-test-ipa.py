#!/usr/bin/env python3
"""Package the inspected original IPA with the native revival transport, for ESign."""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path

from original_transport_patch import install as install_original_transport

EXPECTED_SOURCE = 'caa1c8c25dc960e93ed4bac7230e05db280b8e5b7c148d8ec1d11feb5b2b055c'
DYLIB_PATH = '@executable_path/Frameworks/RevivalBootstrap.dylib'
TEST_BUNDLE = 'com.pacybitsrevival.fut20.launchtest'


def configure_google(info, config):
    bundle = config.get('BUNDLE_ID')
    client = config.get('CLIENT_ID', '')
    scheme = config.get('REVERSED_CLIENT_ID', '')
    suffix = '.apps.googleusercontent.com'
    if bundle != 'com.pacybitsrevival.fut20' or not client.endswith(suffix) \
            or not client[:-len(suffix)] \
            or scheme != 'com.googleusercontent.apps.' + client[:-len(suffix)]:
        raise ValueError('Missing or inconsistent Google iOS client configuration')
    info['CFBundleIdentifier'] = bundle
    types = list(info.get('CFBundleURLTypes', []))
    if not any(scheme in item.get('CFBundleURLSchemes', []) for item in types):
        types.append({'CFBundleURLName': 'RevivalGoogleLogin', 'CFBundleTypeRole': 'Editor',
                      'CFBundleURLSchemes': [scheme]})
    info['CFBundleURLTypes'] = types
    info['RevivalAuthenticationProvider'] = 'google.com'


def arm64_slice(binary):
    if binary[:4] != bytes.fromhex('cafebabe'):
        raise ValueError('Expected the inspected universal executable')
    count = struct.unpack_from('>I', binary, 4)[0]
    for i in range(count):
        cpu, subtype, offset, size, alignment = struct.unpack_from('>5I', binary, 8 + 20*i)
        if cpu == 0x0100000C:
            return binary[offset:offset+size]
    raise ValueError('No arm64 slice')


def add_library(binary):
    data = bytearray(binary)
    magic, cpu, subtype, filetype, count, command_size, flags, reserved = struct.unpack_from('<8I', data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
        raise ValueError('Expected an arm64 Mach-O executable')
    commands_end = 32 + command_size
    pos = 32
    first_section = len(data)
    found_encryption = False
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, pos)
        if length < 8 or pos + length > commands_end:
            raise ValueError('Invalid load command')
        if command == 0x2C:
            found_encryption = True
            if struct.unpack_from('<I', data, pos+16)[0] != 0:
                raise ValueError('Encrypted arm64 binaries are not supported')
        if command == 0x19:
            sections = struct.unpack_from('<I', data, pos+64)[0]
            for index in range(sections):
                offset = struct.unpack_from('<I', data, pos+72+80*index+48)[0]
                if offset:
                    first_section = min(first_section, offset)
        pos += length
    if pos != commands_end or not found_encryption:
        raise ValueError('Unexpected executable structure')
    name = DYLIB_PATH.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    end = commands_end + size
    if end > first_section or any(data[commands_end:end]):
        raise ValueError('Insufficient empty header padding; no code will be overwritten')
    load = struct.pack('<6I', 0xC, size, 24, 0, 0, 0) + name
    data[commands_end:end] = load.ljust(size, b'\0')
    struct.pack_into('<II', data, 16, count+1, command_size+size)
    assert data[end:] == binary[end:]
    return bytes(data)


def package(source, module, output, firebase=None, build_version='1203', island=None):
    if not build_version.isdecimal() or int(build_version) < 1:
        raise ValueError('Build version must be a positive integer')
    if output.exists():
        raise ValueError('Output already exists; choose a new output path')
    if hashlib.sha256(source.read_bytes()).hexdigest() != EXPECTED_SOURCE:
        raise ValueError('Source IPA differs from the inspected original')
    dylib = module.read_bytes()
    if struct.unpack_from('<II', dylib) != (0xFEEDFACF, 0x0100000C):
        raise ValueError('Module must be arm64 Mach-O')
    if struct.unpack_from('<I', dylib, 12)[0] != 6:
        raise ValueError('Module must be a dynamic library')
    island = island or module.with_name('LegacySendIsland.o')
    if not island.exists():
        raise ValueError('Missing LegacySendIsland.o; build the bootstrap first')
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive:
        infos = [n for n in archive.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(infos) != 1:
            raise ValueError('Expected exactly one app')
        info_path = infos[0]
        root = info_path.rsplit('/', 1)[0] + '/'
        info = plistlib.loads(archive.read(info_path))
        executable = root + info['CFBundleExecutable']
        original_arm64 = arm64_slice(archive.read(executable))
        with_library = add_library(original_arm64)
        patched = install_original_transport(original_arm64, with_library, island.read_bytes())
        info['CFBundleIdentifier'] = TEST_BUNDLE
        info['CFBundleDisplayName'] = 'Pacybits Revival Test'
        info['MinimumOSVersion'] = '15.0'
        info['RevivalLaunchTest'] = 1 if firebase is None else 3
        if firebase is not None:
            info['CFBundleVersion'] = build_version
            config_data = firebase.read_bytes()
            config = plistlib.loads(config_data)
            if config.get('PROJECT_ID') != 'pacybits---revival' or not config.get('API_KEY'):
                raise ValueError('Unexpected Firebase project configuration')
            configure_google(info, config)
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as result:
            for entry in archive.infolist():
                if not entry.filename.startswith('Payload/'):
                    continue
                if '/_CodeSignature/' in entry.filename or entry.filename.endswith('/embedded.mobileprovision'):
                    continue
                content = archive.read(entry)
                if entry.filename == executable:
                    content = patched
                elif entry.filename == info_path:
                    content = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
                result.writestr(entry, content)
            if firebase is not None:
                result.writestr(root + 'RevivalFirebase.plist', config_data)
            entry = zipfile.ZipInfo(root + 'Frameworks/RevivalBootstrap.dylib')
            entry.create_system = 3
            entry.external_attr = 0o100755 << 16
            result.writestr(entry, dylib, compress_type=zipfile.ZIP_DEFLATED)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert archive.read(executable) == patched
        assert archive.read(root + 'Frameworks/RevivalBootstrap.dylib') == dylib
        assert plistlib.loads(archive.read(info_path))['CFBundleIdentifier'] == info['CFBundleIdentifier']
    report = {
        'output': str(output), 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
        'source_sha256': EXPECTED_SOURCE, 'module_sha256': hashlib.sha256(dylib).hexdigest(),
        'bundle_id': info['CFBundleIdentifier'], 'build_version': info.get('CFBundleVersion'),
        'minimum_ios': '15.0', 'architecture': 'arm64',
        'signing': 'Requires ESign signing with user certificate',
        'validation': 'Archive integrity, SHA/prologue-checked sender hook, embedded module bytes',
        'device_launch_tested': False, 'restored_trading': True,
        'trading_client_connected': firebase is not None,
        'google_callback_configured': firebase is not None,
        'device_trading_verified': False
    }
    output.with_suffix('.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('module', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--firebase', type=Path)
    parser.add_argument('--build-version', default='1203')
    parser.add_argument('--island', type=Path)
    args = parser.parse_args()
    package(args.source, args.module, args.output, args.firebase, args.build_version, args.island)
