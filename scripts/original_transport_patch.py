"""Install the outbound adapter into the inspected, unencrypted arm64 image.

This does not enable trading by itself. The module must export PBRLegacyOutbound.
The island falls through to the original sender when that adapter declines a call.
"""
import hashlib
import struct

SOURCE_SHA256 = '5c2a3e2df854a92f582cb761942654825c29fada4d5cdf1dba788c3304bbcc0f'
BASE = 0x100000000
SENDER = 0x1006e3b6c
DLSYM = 0x100d1e118
ISLAND_OFFSET = 0x3000
PROLOGUE = bytes.fromhex('ff0305d1fc6f0ea9fa670fa9f85f10a9')


def branch(source, target, link=False):
    delta = target - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('Unaligned or out-of-range arm64 branch')
    return struct.pack('<I', (0x94000000 if link else 0x14000000) | ((delta // 4) & 0x3ffffff))


def object_text(data):
    magic, cpu, _, kind, count, size = struct.unpack_from('<6I', data)
    if (magic, cpu, kind) != (0xfeedfacf, 0x100000c, 1):
        raise ValueError('Expected an arm64 Mach-O object')
    pos, text = 32, None
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, pos)
        if length < 8 or pos + length > 32 + size:
            raise ValueError('Invalid object load command')
        if cmd == 0x19:
            for i in range(struct.unpack_from('<I', data, pos + 64)[0]):
                section = pos + 72 + i * 80
                name = data[section:section + 16].rstrip(b'\0')
                if name == b'__text':
                    section_length, offset = struct.unpack_from('<QI', data, section + 40)
                    relocations = struct.unpack_from('<I', data, section + 60)[0]
                    if relocations or offset + section_length > len(data) or text is not None:
                        raise ValueError('Unexpected island relocations or section layout')
                    text = data[offset:offset + section_length]
        pos += length
    if text is None:
        raise ValueError('Missing island code')
    return text


def install(original, with_library, island_object):
    if hashlib.sha256(original).hexdigest() != SOURCE_SHA256:
        raise ValueError('Unsupported original executable')
    if len(with_library) != len(original) or with_library[0x3000:] != original[0x3000:]:
        raise ValueError('Input must have only the approved library header modification')
    if original[SENDER - BASE:SENDER - BASE + 16] != PROLOGUE:
        raise ValueError('Sender prologue changed')
    code = bytearray(object_text(island_object))
    if not (0x90 <= len(code) <= 0x100) or code[0x6c:0x7c] != PROLOGUE:
        raise ValueError('Unexpected island layout')
    if code[0x24:0x28] != struct.pack('<I', 0x94000000) or code[0x7c:0x80] != struct.pack('<I', 0x14000000):
        raise ValueError('Island branch placeholders changed')
    if code[0x80:0x92] != b'PBRLegacyOutbound\0':
        raise ValueError('Unexpected adapter symbol')
    end = ISLAND_OFFSET + len(code)
    commands_end = 32 + struct.unpack_from('<I', with_library, 20)[0]
    if commands_end > ISLAND_OFFSET or end > 20872 or any(with_library[ISLAND_OFFSET:end]):
        raise ValueError('Island does not fit unused executable header padding')
    address = BASE + ISLAND_OFFSET
    code[0x24:0x28] = branch(address + 0x24, DLSYM, link=True)
    code[0x7c:0x80] = branch(address + 0x7c, SENDER + 16)
    output = bytearray(with_library)
    output[ISLAND_OFFSET:end] = code
    offset = SENDER - BASE
    # Only the first instruction is replaced; fallback replays all four then resumes.
    output[offset:offset + 4] = branch(SENDER, address)
    return bytes(output)
