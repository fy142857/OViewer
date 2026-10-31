"""Install/run only the isolated preload benchmark APK and collect its evidence."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import time

PACKAGE = 'com.oviewer.oviewer.preload_bench'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', required=True)
    parser.add_argument('--aapt', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', required=True)
    parser.add_argument('--lead', required=True, type=int)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--results', required=True)
    parser.add_argument('--log', required=True)
    args = parser.parse_args()
    adb = [args.adb, '-s', args.serial]
    flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0)

    def run(*command):
        return subprocess.check_output(command, text=True, encoding='utf-8', errors='replace', creationflags=flags).strip()

    badging = run(args.aapt, 'dump', 'badging', args.apk)
    if f"package: name='{PACKAGE}'" not in badging:
        raise RuntimeError('Refusing to install an APK with a non-benchmark package ID')
    result_file = Path(args.results)

    def results():
        if not result_file.exists():
            return []
        lines = result_file.read_text(encoding='utf-8').splitlines()
        return [json.loads(line) for line in lines if line.strip()]

    before = len(results())
    expected = len(json.loads(Path(args.plan).read_text(encoding='utf-8-sig')))
    run(*adb, 'shell', 'am', 'force-stop', PACKAGE)
    print(run(*adb, 'install', '-r', args.apk), flush=True)
    run(*adb, 'shell', 'am', 'start', '-n', f'{PACKAGE}/com.oviewer.oviewer.MainActivity')
    time.sleep(1)
    pid = run(*adb, 'shell', 'pidof', PACKAGE)
    if not pid.isdigit():
        raise RuntimeError('Benchmark process did not start')
    log = Path(args.log)
    with log.open('w', encoding='utf-8') as output:
        logger = subprocess.Popen([*adb, 'logcat', f'--pid={pid}', '-v', 'raw'],
                                  stdout=output, stderr=subprocess.STDOUT, creationflags=flags)
        started = time.monotonic()
        last = -1
        try:
            while time.monotonic() - started < 2400:
                current = results()[before:]
                if len(current) != last:
                    last = len(current)
                    print(f'lead={args.lead}: {last}/{expected} cases', flush=True)
                if any(r['lead'] != args.lead for r in current):
                    raise RuntimeError('APK lead does not match requested comparison')
                if '[preload-bench] FAILED' in log.read_text(encoding='utf-8', errors='replace'):
                    raise RuntimeError(f'Benchmark failed; see {log}')
                if len(current) == expected:
                    if any(s['timeout'] for r in current for s in r['samples']):
                        raise RuntimeError('A measured turn timed out; retain it in analysis')
                    time.sleep(2)
                    print(f'lead={args.lead}: complete, {sum(len(r["samples"]) for r in current)} turns', flush=True)
                    return
                if logger.poll() is not None:
                    # A logcat EOF is not proof that the benchmark ended. Keep
                    # the same live app and reconnect its observation channel.
                    if run(*adb, 'shell', 'pidof', PACKAGE) != pid:
                        raise RuntimeError('Benchmark process ended')
                    logger = subprocess.Popen([*adb, 'logcat', f'--pid={pid}', '-v', 'raw'],
                                              stdout=output, stderr=subprocess.STDOUT, creationflags=flags)
                power = run(*adb, 'shell', 'dumpsys', 'power')
                if 'mWakefulness=Awake' not in power:
                    raise RuntimeError('Device slept; incomplete case must be rerun, not included')
                policy = run(*adb, 'shell', 'dumpsys', 'window', 'policy')
                if re.search(r'^\s+showing=true\s*$', policy, re.MULTILINE):
                    raise RuntimeError('Device locked; unlock before resuming incomplete cases')
                time.sleep(5)
            raise TimeoutError('Benchmark did not complete; do not treat partial cases as success')
        finally:
            logger.terminate()
            logger.wait(timeout=10)


if __name__ == '__main__':
    main()
