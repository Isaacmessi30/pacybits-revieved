#!/usr/bin/env python3
"""Local structural check; requires the inspected image and assembled island."""
import importlib.util
import struct
from pathlib import Path
import original_transport_patch as patch

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('packager', root / 'scripts/package-test-ipa.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
original = (root / 'analysis/arm64-binary').read_bytes()
island = (root / 'build/bootstrap/LegacySendIsland.o').read_bytes()
baseline = packager.add_library(original)
output = patch.install(original, baseline, island)


def destination(address):
    instruction = struct.unpack_from('<I', output, address - patch.BASE)[0]
    immediate = instruction & 0x3ffffff
    if immediate & (1 << 25):
        immediate -= 1 << 26
    return address + 4 * immediate


assert destination(patch.SENDER) == patch.BASE + patch.ISLAND_OFFSET
assert destination(patch.BASE + patch.ISLAND_OFFSET + 0x24) == patch.DLSYM
assert destination(patch.BASE + patch.ISLAND_OFFSET + 0x7c) == patch.SENDER + 16
for index, (before, after) in enumerate(zip(baseline, output)):
    if before != after:
        assert (patch.ISLAND_OFFSET <= index < patch.ISLAND_OFFSET + len(patch.object_text(island))
                or patch.SENDER - patch.BASE <= index < patch.SENDER - patch.BASE + 4)
for altered in [original[:100], original[:100] + b'x' + original[101:]]:
    try:
        patch.install(altered, baseline, island)
        raise AssertionError('Different original image accepted')
    except ValueError:
        pass
for source, target in [(0, 2), (0, 1 << 27), (1 << 27, -4)]:
    try:
        patch.branch(source, target)
        raise AssertionError('Invalid branch accepted')
    except ValueError:
        pass
print('PASS: source hash, isolated changes, branch targets and branch bounds; no device execution')
