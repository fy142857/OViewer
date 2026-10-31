"""Verify the pinned WebView backport, optionally against the official archive."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'third_party/flutter_inappwebview'
URL = 'https://pub.dev/api/archives/flutter_inappwebview-5.8.0.tar.gz'
ARCHIVE_SHA256 = 'd198297060d116b94048301ee6749cd2e7d03c1f2689783f52d210a6b7aba350'
SWIFT = 'ios/Classes/InAppWebView/InAppWebView.swift'
ROOT_FILES = {'pubspec.yaml', 'LICENSE', 'README.md', 'CHANGELOG.md'}


def normalized(data: bytes) -> bytes:
    # Git on Windows may convert text to CRLF. Binary assets are byte-exact.
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return data
    return data if b'\0' in data else data.replace(b'\r\n', b'\n')


def digest(data: bytes) -> str:
    return hashlib.sha256(normalized(data)).hexdigest()


def patched(name: str, data: bytes) -> bytes:
    data = normalized(data)
    if name == 'pubspec.yaml':
        assert data.count(b'version: 5.8.0\n') == 1
        return data.replace(b'version: 5.8.0\n', b'# Modified by OViewer: repository-local Xcode 16 backport.\nversion: 5.8.0+oviewer.1\n')
    if name == SWIFT:
        start = data.index(b'    public override func evaluateJavaScript(')
        end = data.index(b'\n    }', start) + len(b'\n    }')
        original = data[start:end]
        signature = b'((Any?, Error?) -> Void)?'
        assert original.count(signature) == 1
        modern = original.replace(signature, b'(@MainActor @Sendable (Any?, (any Error)?) -> Void)?')
        return data[:start] + b'    // Modified by OViewer: backport the upstream Xcode 16 callback signature.\n    #if compiler(>=6.0)\n' + modern + b'\n    #else\n' + original + b'\n    #endif' + data[end:]
    return data


def upstream_files(archive: bytes) -> dict[str, bytes]:
    if hashlib.sha256(archive).hexdigest() != ARCHIVE_SHA256:
        raise ValueError('Official archive SHA-256 mismatch')
    files = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as source:
        for member in source.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('Unsafe archive path')
            name = path.as_posix()
            if member.isfile() and (path.parts[0] in {'lib', 'android', 'ios'} or name in ROOT_FILES):
                files[name] = normalized(source.extractfile(member).read())
    return files


def verify(root: Path = VENDOR, archive: bytes | None = None) -> int:
    manifest = json.loads((root / 'UPSTREAM.json').read_text(encoding='utf-8'))
    if manifest['archive_url'] != URL or manifest['archive_sha256'] != ARCHIVE_SHA256:
        raise ValueError('Unexpected upstream identity')
    records = manifest['files']
    actual = {p.relative_to(root).as_posix() for base in ('lib', 'android', 'ios')
              for p in (root / base).rglob('*') if p.is_file()}
    actual |= {name for name in ROOT_FILES if (root / name).is_file()}
    # Generated build directories must live outside this immutable vendor tree.
    if actual != set(records):
        raise ValueError(f'Vendor inventory mismatch: {sorted(actual ^ set(records))}')
    for name, record in records.items():
        if digest((root / name).read_bytes()) != record['patched_sha256']:
            raise ValueError(f'Vendor content mismatch: {name}')
        if name not in {SWIFT, 'pubspec.yaml'} and record['upstream_sha256'] != record['patched_sha256']:
            raise ValueError(f'Unauthorized vendor modification: {name}')
    if archive is not None:
        originals = upstream_files(archive)
        expected = {name: {'upstream_sha256': digest(data), 'patched_sha256': digest(patched(name, data))}
                    for name, data in originals.items()}
        if records != expected:
            raise ValueError('Manifest differs from official archive plus permitted patch')
    return len(records)


def verify_resolution(root: Path = ROOT) -> None:
    config_path = root / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text(encoding='utf-8'))
    package = next(p for p in config['packages'] if p['name'] == 'flutter_inappwebview')
    from urllib.parse import urljoin
    actual = urljoin(config_path.as_uri(), package['rootUri']).rstrip('/')
    expected = (root / 'third_party/flutter_inappwebview').as_uri()
    if actual.lower() != expected.lower():
        raise ValueError(f'WebView resolved outside repository: {actual}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--download-upstream', action='store_true')
    parser.add_argument('--check-resolution', action='store_true')
    args = parser.parse_args()
    archive = args.archive.read_bytes() if args.archive else None
    if args.download_upstream:
        with urllib.request.urlopen(URL, timeout=90) as response:
            archive = response.read()
    count = verify(archive=archive)
    if args.check_resolution:
        verify_resolution()
    print(f'WebView vendor: {count} files verified; upstream archive checked: {archive is not None}')


if __name__ == '__main__':
    main()
