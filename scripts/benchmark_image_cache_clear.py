"""Compare issue #84 against an immutable Git baseline using real temp files.

Run with Flutter 3.16 after pub get. Generated baseline sources/results stay in
build/; no checkout, production data, package lock, or dependency is modified.
"""
import argparse
import pathlib
import posixpath
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--baseline', default='1fd4768275828a3ca7133a34b74ab37ee39a07b2')
    parser.add_argument('--generate-only', action='store_true')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    output = root / 'build' / 'cache_clear_benchmark'
    output.mkdir(parents=True, exist_ok=True)
    files = ['eh_image_cache_manager.dart', 'image_cache_quota.dart']
    for name in files:
        source_path = 'lib/core/network/' + name
        source = subprocess.check_output(['git', 'show', f'{args.baseline}:{source_path}'], cwd=root).decode('utf-8')

        def resolve(match):
            path = match.group(1)
            if ':' in path or path in files:
                return match.group(0)
            absolute = posixpath.normpath(posixpath.join('core/network', path))
            return f"import 'package:oviewer/{absolute}';"

        source = re.sub(r"import '([^']+)';", resolve, source)
        (output / name).write_text(source, encoding='utf-8')
    (output / 'baseline.txt').write_text(args.baseline + '\n', encoding='utf-8')
    template = root / 'benchmark' / 'image_cache_clear.dart.template'
    (output / 'benchmark_test.dart').write_text(template.read_text(encoding='utf-8'), encoding='utf-8')
    if args.generate_only:
        return 0
    return subprocess.call([args.flutter, 'test', '--no-pub', '--reporter', 'expanded',
                            '--concurrency=1', 'build/cache_clear_benchmark/benchmark_test.dart'], cwd=root)


if __name__ == '__main__':
    raise SystemExit(main())
