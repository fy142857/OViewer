"""Prepare only Flutter's simulator framework for the isolated native XCTest host.

This is an Xcode build phase, not a Flutter application build or a release step.
"""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import shutil
import sys
import uuid


def select_framework(flutter_root: Path, architectures: set[str]) -> Path:
    flutter_root = flutter_root.resolve()
    version_file = flutter_root / 'version'
    if not version_file.is_file() or version_file.read_text(encoding='utf-8').strip() != '3.16.0':
        raise ValueError('Upload native tests require Flutter 3.16.0. Run that SDK once before building.')
    xcframework = flutter_root / 'bin/cache/artifacts/engine/ios/Flutter.xcframework'
    manifest = xcframework / 'Info.plist'
    if not manifest.is_file():
        raise ValueError('Flutter iOS artifacts are missing. Run flutter precache --ios with Flutter 3.16.0.')
    libraries = plistlib.loads(manifest.read_bytes()).get('AvailableLibraries', [])
    matches = [entry for entry in libraries
               if entry.get('SupportedPlatform') == 'ios'
               and entry.get('SupportedPlatformVariant') == 'simulator'
               and architectures <= set(entry.get('SupportedArchitectures', []))]
    if len(matches) != 1:
        raise ValueError('Cannot identify one compatible Flutter simulator framework slice.')
    entry = matches[0]
    candidate = (xcframework / entry['LibraryIdentifier'] / entry['LibraryPath']).resolve()
    if not candidate.is_relative_to(xcframework.resolve()) or candidate.name != 'Flutter.framework':
        raise ValueError('Invalid Flutter framework path in XCFramework metadata.')
    for relative in ['Flutter', 'Info.plist', 'Headers/Flutter.h', 'Modules/module.modulemap']:
        if not (candidate / relative).is_file():
            raise ValueError(f'The Flutter simulator framework is incomplete: {relative}')
    minimum = plistlib.loads((candidate / 'Info.plist').read_bytes()).get('MinimumOSVersion')
    try:
        parts = tuple(int(part) for part in str(minimum).split('.'))
    except ValueError as exc:
        raise ValueError('Flutter framework minimum OS metadata is missing or invalid.') from exc
    if not 1 <= len(parts) <= 3 or parts + (0,) * (3 - len(parts)) > (12, 0, 0):
        raise ValueError('The Flutter framework exceeds the iOS 12 deployment target.')
    return candidate


def copy_framework(source: Path, products: Path) -> Path:
    products = products.resolve()
    destination = products / 'UploadValidationFlutter/Flutter.framework'
    if not destination.resolve().is_relative_to(products):
        raise ValueError('The validation framework destination escapes the build products directory.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = destination.parent / ('.Flutter-' + uuid.uuid4().hex + '.framework')
    if not staging.resolve().is_relative_to(products):
        raise ValueError('Invalid validation framework staging directory.')
    try:
        shutil.copytree(source, staging, symlinks=True)
        if destination.exists():
            # This exact generated framework was resolved and checked above.
            shutil.rmtree(destination)
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return destination


def main() -> int:
    if sys.platform != 'darwin' or os.environ.get('PLATFORM_NAME') != 'iphonesimulator':
        raise ValueError('UploadValidation builds are supported only on a macOS iOS Simulator destination.')
    if os.environ.get('PRODUCT_BUNDLE_IDENTIFIER') != 'com.oviewer.oviewer.uploadvalidation':
        raise ValueError('Refusing to prepare a framework for a non-validation application.')
    root = os.environ.get('FLUTTER_ROOT')
    products = os.environ.get('BUILT_PRODUCTS_DIR')
    architectures = set(os.environ.get('ARCHS', '').split())
    if not root or not products or not architectures:
        raise ValueError('Xcode did not supply FLUTTER_ROOT, BUILT_PRODUCTS_DIR, and ARCHS.')
    source = select_framework(Path(root), architectures)
    copy_framework(source, Path(products))
    print('Prepared Flutter 3.16.0 simulator framework for UploadValidationHost.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f'error: {error}', file=sys.stderr)
        raise SystemExit(1)
