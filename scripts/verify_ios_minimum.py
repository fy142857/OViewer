"""Inspect every device Mach-O slice in an app, without trusting Pod overrides.

This checks deployment declarations, not runtime API availability or signing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct

THIN = {b'\xce\xfa\xed\xfe': ('<', False), b'\xcf\xfa\xed\xfe': ('<', True),
        b'\xfe\xed\xfa\xce': ('>', False), b'\xfe\xed\xfa\xcf': ('>', True)}
FAT = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
       b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
LIMIT = (12, 0, 0)


def version(text: str) -> tuple[int, int, int]:
    parts = text.split('.')
    if not 1 <= len(parts) <= 3 or any(not p.isdecimal() for p in parts):
        raise ValueError(f'Invalid minimum OS: {text!r}')
    return tuple(map(int, parts)) + (0,) * (3 - len(parts))


def packed_version(value: int) -> str:
    return f'{value >> 16}.{(value >> 8) & 255}.{value & 255}'


def macho_slices(data: bytes) -> list[dict]:
    magic = data[:4]
    if magic in FAT:
        endian, wide = FAT[magic]
        if len(data) < 8:
            raise ValueError('Truncated universal header')
        count = struct.unpack_from(endian + 'I', data, 4)[0]
        stride = 32 if wide else 20
        if not count or 8 + count * stride > len(data):
            raise ValueError('Invalid universal architecture table')
        result, regions = [], []
        for index in range(count):
            cursor = 8 + index * stride
            cpu, subtype = struct.unpack_from(endian + 'II', data, cursor)
            offset, size = struct.unpack_from(endian + ('QQ' if wide else 'II'), data, cursor + 8)
            if offset < 8 + count * stride or size < 4 or offset + size > len(data):
                raise ValueError('Invalid universal slice bounds')
            if any(offset < end and offset + size > start for start, end in regions):
                raise ValueError('Overlapping universal slices')
            regions.append((offset, offset + size))
            if data[offset:offset + 4] not in THIN:
                raise ValueError('Unrecognized universal slice')
            slices = macho_slices(data[offset:offset + size])
            if slices[0]['cpu_type'] != cpu or slices[0]['cpu_subtype'] != subtype:
                raise ValueError('Universal architecture does not match slice')
            result.extend(slices)
        return result
    if magic not in THIN:
        raise ValueError('Unrecognized Mach-O executable')
    endian, wide = THIN[magic]
    header_size = 32 if wide else 28
    if len(data) < header_size:
        raise ValueError('Truncated Mach-O header')
    cpu, subtype, file_type, count, size = struct.unpack_from(endian + 'IIIII', data, 4)
    if file_type not in {2, 6, 8}:  # MH_EXECUTE, MH_DYLIB, MH_BUNDLE
        raise ValueError(f'Unexpected Mach-O file type: {file_type}')
    end = header_size + size
    if end > len(data) or count > size // 8:
        raise ValueError('Invalid load-command table')
    cursor, minima = header_size, []
    for _ in range(count):
        if cursor + 8 > end:
            raise ValueError('Truncated load command')
        command, length = struct.unpack_from(endian + 'II', data, cursor)
        if length < 8 or cursor + length > end:
            raise ValueError('Invalid load-command size')
        if command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            if length != 16:
                raise ValueError('Invalid iOS minimum command')
            minima.append(packed_version(struct.unpack_from(endian + 'I', data, cursor + 8)[0]))
        elif command == 0x32:  # LC_BUILD_VERSION
            if length < 24:
                raise ValueError('Invalid build-version command')
            platform, minimum = struct.unpack_from(endian + 'II', data, cursor + 8)
            if platform != 2:
                raise ValueError(f'Non-device-iOS platform: {platform}')
            minima.append(packed_version(minimum))
        elif command in {0x24, 0x2f, 0x30}:
            raise ValueError('Non-iOS deployment command')
        cursor += length
    if cursor != end or len(minima) != 1:
        raise ValueError('Missing, duplicate or malformed minimum OS declaration')
    if cpu not in {12, 0x100000c}:  # arm / arm64 (reject legacy simulator commands)
        raise ValueError(f'Non-device CPU: {cpu}')
    if version(minima[0]) > LIMIT:
        raise ValueError(f'Mach-O requires iOS {minima[0]}, above 12.0')
    return [{'cpu_type': cpu, 'cpu_subtype': subtype, 'minimum_os': minima[0]}]


def inspect_app(app: Path) -> dict:
    app = app.resolve()
    report = {'schema': 1, 'app': app.name, 'maximum_ios': '12.0',
              'runtime_device_test': 'not_performed', 'binaries': [], 'bundles': [], 'errors': []}
    expected = set()
    bundles = [app] + sorted(p for p in app.rglob('*') if p.is_dir() and p.suffix in {'.framework', '.app', '.appex'})
    for bundle in bundles:
        try:
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            minimum = info.get('MinimumOSVersion')
            if minimum is None or version(minimum) > LIMIT or (bundle == app and version(minimum) != LIMIT):
                raise ValueError(f'Invalid bundle MinimumOSVersion: {minimum!r}')
            executable = info.get('CFBundleExecutable')
            if not executable or Path(executable).name != executable:
                raise ValueError('Missing or invalid CFBundleExecutable')
            binary = (bundle / executable).resolve()
            if not binary.is_relative_to(app) or not binary.is_file():
                raise ValueError('Bundle executable missing or outside app')
            expected.add(binary)
            report['bundles'].append({'path': bundle.relative_to(app).as_posix(), 'minimum_os': minimum})
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
            report['errors'].append(f'{bundle.relative_to(app)}: {error}')
    seen = set()
    for path in sorted(app.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(app).as_posix()
        if not path.resolve().is_relative_to(app):
            report['errors'].append(f'{relative}: symlink outside app')
            continue
        with path.open('rb') as source:
            magic = source.read(4)
        if magic not in THIN and magic not in FAT and path.resolve() not in expected and path.suffix != '.dylib':
            continue
        if path.resolve() in seen:
            continue
        seen.add(path.resolve())
        data = path.read_bytes()
        record = {'path': relative, 'sha256': hashlib.sha256(data).hexdigest()}
        try:
            record['slices'] = macho_slices(data)
        except ValueError as error:
            record['error'] = str(error)
            report['errors'].append(f'{relative}: {error}')
        report['binaries'].append(record)
    for missing in expected - seen:
        report['errors'].append(f'Uninspected executable: {missing.relative_to(app)}')
    if not report['binaries']:
        report['errors'].append('No Mach-O binaries found')
    report['passed'] = not report['errors']
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    report = inspect_app(args.app)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
