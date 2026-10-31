"""Experimental macOS test runner; never used by candidate builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import time

SOURCE = 'dbf940b36996169f0817a3b45480d0f50cc3ec6e'


def command(*args):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return {'exit_code': p.returncode, 'output': p.stdout.strip()}


def summarize(events, root):
    suites, tests, completed = {}, {}, []
    done = None
    for event in events:
        kind = event['type']
        if kind == 'suite':
            suite = event['suite']
            suites[suite['id']] = Path(suite['path']).relative_to(root).as_posix()
        elif kind == 'testStart':
            tests[event['test']['id']] = event['test']
        elif kind == 'testDone' and not event.get('hidden', False):
            test = tests[event['testID']]
            completed.append({'file': suites[test['suiteID']], 'name': test['name'],
                'result': event['result'], 'skipped': event.get('skipped', False)})
        elif kind == 'done':
            done = event
    completed.sort(key=lambda t: (t['file'], t['name']))
    identities = [(t['file'], t['name']) for t in completed if not t['skipped']]
    return {'done': done, 'count': len(identities),
        'passed': sum(t['result'] == 'success' and not t['skipped'] for t in completed),
        'failed': [t for t in completed if t['result'] != 'success' and not t['skipped']],
        'skipped': sum(t['skipped'] for t in completed),
        'test_set_sha256': hashlib.sha256(json.dumps(identities, ensure_ascii=False).encode()).hexdigest(),
        'tests': completed}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--concurrency', type=int, choices=[1, 2, 3], required=True)
    parser.add_argument('--round', type=int, choices=[1, 2, 3], required=True)
    args = parser.parse_args()
    root = Path.cwd().resolve()
    reports = root / 'reports'
    reports.mkdir(exist_ok=True)
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    assert sha == SOURCE
    assert platform.system() == 'Darwin'
    assert not (root / 'build/test_cache').exists(), 'Unexpected warm test cache'
    environment = {
        'source_sha': sha, 'concurrency': args.concurrency, 'round': args.round,
        'run_id': os.environ.get('GITHUB_RUN_ID'), 'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
        'image_os': os.environ.get('ImageOS'), 'image_version': os.environ.get('ImageVersion'),
        'runner_arch': os.environ.get('RUNNER_ARCH'), 'machine': platform.machine(),
        'os': command('sw_vers'), 'hardware': command('sysctl', 'hw.ncpu', 'hw.memsize', 'machdep.cpu.brand_string'),
        'xcode': command('xcodebuild', '-version'), 'flutter': command('flutter', '--version', '--machine'),
        'pubspec_lock_sha256': hashlib.sha256((root / 'pubspec.lock').read_bytes()).hexdigest(),
        'generated_database_sha256': hashlib.sha256((root / 'lib/core/storage/database.g.dart').read_bytes()).hexdigest(),
        'cache': {k: os.environ.get(k) for k in ['FLUTTER_CACHE_HIT', 'PUB_CACHE_HIT']},
        'vm_before': command('vm_stat')}
    (reports / 'environment.json').write_text(json.dumps(environment, indent=2))
    argv = ['flutter', 'test', '--no-pub', '--reporter', 'expanded',
        '--file-reporter=json:reports/tests.json', '--exclude-tags', 'reader_prefetch_slow',
        f'--concurrency={args.concurrency}', '--verbose']
    timed_out = False
    start = time.perf_counter()
    with (reports / 'flutter.log').open('w') as log, (reports / 'resources.txt').open('w') as resources:
        process = subprocess.Popen(['/usr/bin/time', '-l', *argv], stdout=log,
            stderr=resources, start_new_session=True)
        try:
            code = process.wait(timeout=1200)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
    elapsed = time.perf_counter() - start
    result = {'command': argv, 'wall_seconds': elapsed, 'exit_code': code,
        'timed_out': timed_out, 'vm_after': command('vm_stat')}
    (reports / 'timing.json').write_text(json.dumps(result, indent=2))
    # Keep raw results even if the reporter was truncated by a crash/timeout.
    try:
        events = [json.loads(line) for line in (reports / 'tests.json').read_text().splitlines() if line.strip()]
        result['test_results'] = summarize(events, root)
    except Exception as error:
        result['parse_error'] = str(error)
    result['phases'] = re.findall(r'Runtime for phase [^\n]+', (reports / 'flutter.log').read_text())
    (reports / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    totals = result.get('test_results', {})
    valid = (code == 0 and totals.get('count') == 1083 and totals.get('passed') == 1083
        and totals.get('done', {}).get('success') is True)
    print(json.dumps({'round': args.round, 'concurrency': args.concurrency,
        'wall_seconds': elapsed, 'exit_code': code, 'count': totals.get('count'),
        'passed': totals.get('passed'), 'valid': valid}), flush=True)
    raise SystemExit(0 if valid else 1)


if __name__ == '__main__':
    main()
