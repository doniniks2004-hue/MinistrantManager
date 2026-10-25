#!/usr/bin/env python3
"""Reject APK/AAB 64-bit native libraries incompatible with 16 KB pages.

Checks ELF PT_LOAD segments in both formats and uncompressed APK ZIP offsets.
This is a packaging check, not a substitute for running on a 16 KB device.
"""
import argparse
from pathlib import Path
import struct
import zipfile

PAGE_SIZE = 16384


def check_elf(data):
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('expected a little-endian ELF64 library')
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    if size < 56 or not count or offset + size * count > len(data):
        raise ValueError('invalid program header table')
    loads = 0
    for i in range(count):
        header = struct.unpack_from('<IIQQQQQQ', data, offset + i * size)
        kind, _, file_offset, address, _, _, _, alignment = header
        if kind != 1:  # PT_LOAD
            continue
        loads += 1
        if alignment < PAGE_SIZE or alignment & (alignment - 1):
            raise ValueError(f'PT_LOAD alignment {alignment} is not 16 KB compatible')
        if (address - file_offset) % PAGE_SIZE:
            raise ValueError('PT_LOAD virtual address and offset disagree modulo 16 KB')
    if not loads:
        raise ValueError('ELF has no loadable segments')


def check_package(path):
    path = Path(path)
    if path.suffix not in ('.apk', '.aab'):
        raise ValueError('expected .apk or .aab')
    errors, checked = [], 0
    with path.open('rb') as raw, zipfile.ZipFile(path) as archive:
        prefix = 'base/lib/' if path.suffix == '.aab' else 'lib/'
        for entry in archive.infolist():
            name = entry.filename
            if not any(name.startswith(prefix + abi + '/') for abi in ('arm64-v8a', 'x86_64')) or not name.endswith('.so'):
                continue
            checked += 1
            try:
                check_elf(archive.read(entry))
                if path.suffix == '.apk' and entry.compress_type == zipfile.ZIP_STORED:
                    raw.seek(entry.header_offset)
                    header = raw.read(30)
                    if len(header) != 30 or header[:4] != b'PK\x03\x04':
                        raise ValueError('invalid ZIP local header')
                    name_size, extra_size = struct.unpack_from('<HH', header, 26)
                    data_offset = entry.header_offset + 30 + name_size + extra_size
                    if data_offset % PAGE_SIZE:
                        raise ValueError(f'uncompressed APK entry offset {data_offset} is not 16 KB aligned')
            except (ValueError, struct.error, zipfile.BadZipFile) as exc:
                errors.append(f'{name}: {exc}')
    if not checked:
        errors.append('no 64-bit native libraries found')
    if errors:
        raise ValueError('\n'.join(errors))
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('packages', nargs='+', type=Path)
    args = parser.parse_args()
    for path in args.packages:
        try:
            count = check_package(path)
        except (OSError, ValueError, zipfile.BadZipFile) as exc:
            parser.exit(1, f'FAIL {path}:\n{exc}\n')
        print(f'PASS {path}: {count} native libraries, 16 KB ELF/APK alignment')


if __name__ == '__main__':
    main()
