"""Resolve reviewed slow-test decisions without guessing behavior from paths."""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import re
import zipfile

from .github import APIError, GitHub, json_text
from .prepare import Ledger
from .rules import CANDIDATE_PATH, Commit, Git, VersionError, ignored_path, with_version

TAG = 'reader_prefetch_slow'
SHA = re.compile(r'[0-9a-f]{40}')
MODES = {'run', 'skip'}
SOURCES = {'commits', 'cli', 'manual', 'pull_request'}
SCOPE_PATH = Path('test-scope.json')


def run_title(platform: str, candidate_id: str, mode: str | None = None) -> str:
    title = f'{platform} / {candidate_id}'
    return title if mode is None else f'{title} / slow:{mode}'


def declaration(message: str) -> tuple[str, str] | None:
    fields = [re.findall(rf'(?im)^{name}:[ \t]*([^\r\n]*)', message)
              for name in ('Slow-Tests', 'Slow-Tests-Reason')]
    if not any(fields):
        return None
    if any(len(values) != 1 for values in fields):
        raise VersionError('Provide exactly one Slow-Tests and Slow-Tests-Reason')
    mode, reason = (values[0].strip() for values in fields)
    if mode not in MODES or not reason:
        raise VersionError('Slow-Tests must be run or skip, with a nonempty reason')
    return mode, reason


def select(commits: list[Commit], base: str, head: str, *, source='commits', override='auto') -> dict:
    decisions = []
    for commit in commits:
        if not any(not ignored_path(path) for path in commit.paths):
            continue
        choice = declaration(commit.message)
        mode, reason = choice or ('run', 'Missing Slow-Tests declaration; retain full suite')
        decisions.append((commit.sha, mode, reason))
    mode = 'run' if any(item[1] == 'run' for item in decisions) else 'skip'
    reason = '; '.join(f'{sha[:8]} {choice}: {why}' for sha, choice, why in decisions)
    reason = reason or 'No effective changes in the reviewed range'
    if override != 'auto':
        if override not in MODES:
            raise VersionError('Unknown slow-test override')
        mode, source = override, 'cli'
        reason = f'Explicit --slow-tests {override}; reviewed decision: {reason}'
    return validate_scope({'schema': 1, 'mode': mode, 'source': source,
                           'reason': reason[:4000], 'base_sha': base, 'head_sha': head})


def validate_scope(scope: dict) -> dict:
    if (not isinstance(scope, dict) or type(scope.get('schema')) is not int or scope['schema'] != 1
            or not isinstance(scope.get('mode'), str) or scope['mode'] not in MODES
            or not isinstance(scope.get('source'), str) or scope['source'] not in SOURCES
            or not isinstance(scope.get('reason'), str) or not scope['reason'].strip()
            or not isinstance(scope.get('head_sha'), str) or not SHA.fullmatch(scope['head_sha'])
            or (scope.get('base_sha') is not None and
                (not isinstance(scope['base_sha'], str) or not SHA.fullmatch(scope['base_sha'])))):
        raise VersionError('Invalid test scope record')
    return scope


def automatic_version_commit(git: Git, sha: str, parents: list[str], paths: tuple[str, ...]) -> bool:
    # PRs need no privileged API/ledger access. Do not trust a commit subject alone.
    if len(parents) != 1 or set(paths) != {CANDIDATE_PATH, 'pubspec.yaml'}:
        return False
    lines = git.file_message(sha).splitlines()
    if not lines or not re.fullmatch(r'chore\(release\): prepare \d+\.\d+\.\d+\+\d+', lines[0]):
        return False
    try:
        record = json.loads(git.file(sha, CANDIDATE_PATH))
        return (record.get('source_sha') == parents[0]
                and with_version(git.file(sha, 'pubspec.yaml'), '0.0.0', 1)
                == with_version(git.file(parents[0], 'pubspec.yaml'), '0.0.0', 1))
    except (ValueError, VersionError):
        return False


def range_commits(git: Git, base: str, head: str) -> list[Commit]:
    if not git.ancestor(base, head):
        raise VersionError('Test scope base must be an ancestor of source')
    commits = []
    for sha in git.text('rev-list', '--reverse', f'{base}..{head}').splitlines():
        parents = git.text('rev-list', '--parents', '-n', '1', sha).split()[1:]
        # Other parents' commits are visited above; combined diff catches a
        # merge's own changes/resolutions instead of ignoring merge commits.
        options = ['--cc'] if len(parents) > 1 else []
        paths = tuple(p.decode('utf-8') for p in git.run(
            'diff-tree', '--no-commit-id', '--name-only', '-r', '--root', '-z', *options, sha).split(b'\0') if p)
        if automatic_version_commit(git, sha, parents, paths):
            continue
        commits.append(Commit(sha, git.file_message(sha), paths, len(parents) > 1))
    return commits


def workflow_runs(api: GitHub) -> dict[str, list[dict]]:
    return {platform: list(api.pages(
        f'/actions/workflows/build_{platform}.yml/runs?event=workflow_dispatch', 'workflow_runs'))
        for platform in ('android', 'ios')}


def candidate_run(run: dict, candidate: dict, platform: str) -> bool:
    return (run.get('event') == 'workflow_dispatch'
            and (run.get('head_sha') == candidate['build_sha']
                 or run.get('_verified_build_sha') == candidate['build_sha'])
            and run.get('head_branch') in {'dev', 'main'}
            and run.get('display_title') in {run_title(platform, candidate['candidate_id'], mode)
                                           for mode in (None, 'run', 'skip')})


def verified_run(api: GitHub, run: dict, candidate: dict, platform: str) -> bool:
    if candidate_run(run, candidate, platform):
        return True
    # Manual rebuilds can start on a later branch head and then check out the
    # registered candidate. Only completed build metadata can establish that.
    if (run.get('status') != 'completed' or run.get('conclusion') != 'success'
            or run.get('event') != 'workflow_dispatch' or run.get('head_branch') not in {'dev', 'main'}
            or run.get('display_title') not in {run_title(platform, candidate['candidate_id'], mode)
                                              for mode in (None, 'run', 'skip')}):
        return False
    cache = run.setdefault('_metadata_cache', {})
    if 'record' not in cache:
        try:
            artifacts = list(api.pages(f"/actions/runs/{run['id']}/artifacts", 'artifacts'))
            matches = [a for a in artifacts if a['name'] == 'build-metadata' and not a['expired']]
            if len(matches) != 1:
                cache['record'] = None
            else:
                raw = api.request(f"/actions/artifacts/{matches[0]['id']}/zip", binary=True)
                with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                    if archive.namelist() != ['build-metadata.json'] or archive.infolist()[0].file_size > 65536:
                        raise ValueError('Unexpected metadata archive')
                    cache['record'] = json.loads(archive.read('build-metadata.json'))
        except APIError as error:
            if error.status not in {404, 410}:
                raise
            cache['record'] = None
        except (ValueError, zipfile.BadZipFile, KeyError):
            cache['record'] = None
    record = cache['record']
    if not isinstance(record, dict):
        return False
    expected = {'schema': 1, 'candidate_id': candidate['candidate_id'], 'build_sha': candidate['build_sha'],
                'source_sha': candidate['source_sha'], 'platform': platform,
                'run_id': run['id'], 'run_attempt': run['run_attempt']}
    if not all(record.get(key) == value for key, value in expected.items()):
        return False
    declared = record.get('test_scope')
    try:
        if declared is not None:
            validate_scope(declared)
            if declared['head_sha'] != candidate['source_sha']:
                return False
        if run['display_title'] != run_title(platform, candidate['candidate_id'], declared['mode'] if declared else None):
            return False
    except VersionError:
        return False
    run['_verified_build_sha'] = candidate['build_sha']
    return True


def baseline(git: Git, candidate: dict, records: list[dict], runs: dict[str, list[dict]], api=None) -> str:
    for record in sorted(records, key=lambda item: item['build_number'], reverse=True):
        if record['build_number'] >= candidate['build_number'] or record['stage'] != 'ready':
            continue
        if not all(any(run['status'] == 'completed' and run['conclusion'] == 'success'
                       and (verified_run(api, run, record, platform) if api else candidate_run(run, record, platform))
                       for run in runs[platform]) for platform in ('android', 'ios')):
            continue
        # A successful candidate on an unrelated branch may not be in this checkout.
        try:
            ancestor = git.ancestor(record['build_sha'], candidate['source_sha'])
        except VersionError:
            ancestor = False
        if ancestor:
            return record['build_sha']
    return git.text('rev-parse', f"{candidate['base_tag']}^{{commit}}")


def candidate_scope(api: GitHub, git: Git, candidate: dict, runs: dict, override='auto') -> dict:
    records = Ledger(api).data['candidates']
    base = baseline(git, candidate, records, runs, api)
    return select(range_commits(git, base, candidate['source_sha']), base, candidate['source_sha'], override=override)


def pr_scope(git: Git, base: str, head: str) -> dict:
    if not SHA.fullmatch(base) or not SHA.fullmatch(head):
        raise VersionError('PR test selection needs exact base/head SHAs')
    common = git.text('merge-base', base, head)
    return select(range_commits(git, common, head), common, head, source='pull_request')


def input_scope(git: Git, head: str, skip: bool, payload: str = '') -> dict:
    mode = 'skip' if skip else 'run'
    if payload:
        try:
            scope = validate_scope(json.loads(payload))
        except (ValueError, TypeError) as error:
            raise VersionError('Invalid dispatched test scope JSON') from error
        if scope['mode'] != mode or scope['head_sha'] != head:
            raise VersionError('Dispatched test scope disagrees with candidate/input')
        if scope.get('base_sha') and not git.ancestor(scope['base_sha'], head):
            raise VersionError('Dispatched test scope base is not an ancestor')
        return scope
    return validate_scope({'schema': 1, 'mode': mode, 'source': 'manual', 'base_sha': None,
                           'head_sha': head, 'reason': f'Manual workflow selection: slow tests {mode}'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['workflow', 'range'])
    parser.add_argument('--base')
    parser.add_argument('--head')
    parser.add_argument('--slow-tests', choices=['auto', 'run', 'skip'], default='auto')
    args = parser.parse_args()
    git = Git()
    if args.command == 'range':
        if not args.base or not args.head:
            parser.error('range requires --base and --head')
        base, head = (git.text('rev-parse', f'{ref}^{{commit}}') for ref in (args.base, args.head))
        print(json_text(select(range_commits(git, base, head), base, head, override=args.slow_tests)))
        return
    if os.environ['GITHUB_EVENT_NAME'] == 'pull_request':
        scope = pr_scope(git, os.environ['PR_BASE_SHA'], os.environ['PR_HEAD_SHA'])
    else:
        candidate = json.loads(Path(CANDIDATE_PATH).read_text(encoding='utf-8'))
        scope = input_scope(git, candidate['source_sha'], os.environ.get('SKIP_READER_PREFETCH_TESTS') == 'true',
                            os.environ.get('DISPATCHED_TEST_SCOPE', ''))
    SCOPE_PATH.write_text(json_text(scope), encoding='utf-8')
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
        stream.write(f"skip_slow={str(scope['mode'] == 'skip').lower()}\n")
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as stream:
        stream.write('### Test selection\n\n```json\n' + json_text(scope).replace('```', '\\u0060\\u0060\\u0060') + '```\n')
    print(json_text(scope))


if __name__ == '__main__':
    main()
