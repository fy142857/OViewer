"""Run upload XCTest in its separate simulator app; never build or launch Runner."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid

if __package__:
    from .prepare_upload_ios_framework import select_framework
    from .verify_upload_ios_project import validate
else:
    from prepare_upload_ios_framework import select_framework
    from verify_upload_ios_project import validate


def simulator(devices: dict, identifier: str) -> dict:
    matches = [(runtime, item) for runtime, entries in devices.get('devices', {}).items()
               for item in entries if item.get('udid') == identifier and item.get('isAvailable') is True]
    if len(matches) != 1:
        raise ValueError('Choose one available iOS Simulator UDID from xcrun simctl list devices available.')
    runtime, item = matches[0]
    if not runtime.startswith('com.apple.CoreSimulator.SimRuntime.iOS-'):
        raise ValueError('Upload XCTest requires an iOS Simulator, not a physical device or another platform.')
    return {'udid': identifier, 'runtime': runtime, 'name': item.get('name')}


def command(root: Path, flutter_root: Path, identifier: str, output: Path) -> list[str]:
    return ['xcodebuild', 'test', '-project', str(root / 'ios/Runner.xcodeproj'),
            '-scheme', 'UploadValidation', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
            '-destination', f'platform=iOS Simulator,id={identifier}',
            '-parallel-testing-enabled', 'NO', '-only-testing:UploadValidationTests',
            '-derivedDataPath', str(output / 'DerivedData'), '-resultBundlePath', str(output / 'UploadValidation.xcresult'),
            f'FLUTTER_ROOT={flutter_root}', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-']


def passed_methods(log: str) -> set[str]:
    names = set()
    for case in re.findall(r'Test [Cc]ase [\'“](.+?)[\'”] passed', log):
        names.update(re.findall(r'\b(test[A-Za-z0-9_]+)\b', case))
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-root', type=Path, required=True, help='The Flutter 3.16.0 SDK directory')
    parser.add_argument('--simulator-id', required=True, help='Available iOS Simulator UDID; no physical devices')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    validate(root)
    if sys.platform != 'darwin':
        parser.error('Xcode/XCTest execution requires macOS. Project structure validation is a separate check.')
    flutter_root = args.flutter_root.expanduser().resolve()
    flutter = flutter_root / 'bin/flutter'
    version = json.loads(subprocess.check_output([str(flutter), '--version', '--machine'], text=True))
    if version.get('frameworkVersion') != '3.16.0':
        raise ValueError('Use Flutter 3.16.0, matching the project build convention.')
    subprocess.run([str(flutter), 'precache', '--ios'], check=True, cwd=root)
    select_framework(flutter_root, set())
    selected = simulator(json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], text=True)), args.simulator_id)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    output = root / 'build/ios-upload-validation' / stamp
    output.mkdir(parents=True)
    expected = set()
    for source in (root / 'ios/RunnerTests').glob('*Tests.swift'):
        expected.update(re.findall(r'func\s+(test\w+)\s*\(', source.read_text(encoding='utf-8')))
    if not expected:
        raise ValueError('No upload XCTest methods were found.')
    argv = command(root, flutter_root, selected['udid'], output)
    log_path = output / 'xcodebuild.log'
    with log_path.open('w', encoding='utf-8') as log:
        process = subprocess.Popen(argv, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, encoding='utf-8', errors='replace')
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
        code = process.wait()
    passed = passed_methods(log_path.read_text(encoding='utf-8'))
    missing = sorted(expected - passed)
    result = {'passed': code == 0 and not missing, 'xcodebuild_exit_code': code, 'flutter': '3.16.0',
              'scheme': 'UploadValidation', 'host_bundle': 'com.oviewer.oviewer.uploadvalidation',
              'simulator': selected, 'expected_tests': len(expected), 'observed_passed_tests': len(expected & passed),
              'missing_passed_tests': missing, 'xcresult': str(output / 'UploadValidation.xcresult'),
              'limitations': 'Simulator unit tests do not establish real-device background upload reliability or iOS 12 runtime compatibility.'}
    (output / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['passed'] else (code or 1)


if __name__ == '__main__':
    raise SystemExit(main())
