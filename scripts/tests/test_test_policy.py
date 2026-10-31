import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

from scripts.versioning.dispatch import dispatch
from scripts.versioning.rules import Commit, Git, VersionError
from scripts.versioning.test_policy import (
    baseline, candidate_run, declaration, input_scope, main, pr_scope,
    range_commits, run_title, select, validate_scope, verified_run,
)
from scripts.versioning.build import metadata
from scripts.versioning.release import read_build, release_notes, validate_pair

BASE, HEAD, BUILD = 'a' * 40, 'b' * 40, 'c' * 40


def commit(mode=None, reason='Reviewed affected behavior', paths=('lib/widgets/reader_menu.dart',), sha=HEAD):
    message = 'fix: adjust existing behavior'
    if mode is not None:
        message += f'\n\nSlow-Tests: {mode}\nSlow-Tests-Reason: {reason}\n'
    return Commit(sha, message, paths)


def scope(mode='skip'):
    return select([commit(mode)], BASE, HEAD)


def candidate(number=2):
    return {'candidate_id': f'1.0.1+{number}', 'source_sha': HEAD, 'build_sha': BUILD,
            'stage': 'ready', 'build_number': number, 'base_tag': 'v1.0.0', 'version': '1.0.1'}


def run(platform='ios', mode='skip', status='completed', conclusion='success', sha=BUILD):
    return {'id': 42, 'run_attempt': 1, 'event': 'workflow_dispatch', 'head_branch': 'dev',
            'head_sha': sha, 'display_title': run_title(platform, '1.0.1+2', mode),
            'status': status, 'conclusion': conclusion, 'workflow_id': 3,
            'repository': {'full_name': 'owner/repo'}, 'head_repository': {'full_name': 'owner/repo'}}


class PolicyTests(unittest.TestCase):
    def test_semantic_review_not_path_guessing(self):
        self.assertEqual(select([commit('skip', 'Only menu padding')], BASE, HEAD)['mode'], 'skip')
        self.assertEqual(select([commit('run', 'Changes request cancellation')], BASE, HEAD)['mode'], 'run')

    def test_non_reader_ci_change_can_skip(self):
        self.assertEqual(select([commit('skip', paths=('.github/workflows/build_ios.yml',))], BASE, HEAD)['mode'], 'skip')

    def test_missing_defaults_to_run(self):
        self.assertEqual(select([commit()], BASE, HEAD)['mode'], 'run')

    def test_docs_do_not_require_declaration(self):
        self.assertEqual(select([commit(paths=('AGENTS.md', 'docs/policy.json'))], BASE, HEAD)['mode'], 'skip')

    def test_invalid_empty_or_duplicate_declarations_fail(self):
        for message in ('Slow-Tests: unknown\nSlow-Tests-Reason: x', 'Slow-Tests: skip',
                        'Slow-Tests-Reason: x', 'Slow-Tests: skip\nSlow-Tests-Reason: ',
                        'Slow-Tests: run\nSlow-Tests: skip\nSlow-Tests-Reason: x',
                        'Slow-Tests: skip\nSlow-Tests-Reason: x\nSlow-Tests-Reason: y'):
            with self.subTest(message=message), self.assertRaises(VersionError):
                declaration(message)

    def test_multiple_commits_run_wins_and_missing_cannot_be_masked(self):
        for first in (commit('run', sha=BASE), commit(sha=BASE)):
            self.assertEqual(select([first, commit('skip')], BASE, HEAD)['mode'], 'run')

    def test_explicit_overrides_are_recorded(self):
        for mode in ('run', 'skip'):
            result = select([commit('run' if mode == 'skip' else 'skip')], BASE, HEAD, override=mode)
            self.assertEqual((result['mode'], result['source']), (mode, 'cli'))
            self.assertIn('Explicit', result['reason'])

    def test_manual_default_and_checkbox(self):
        for skip in (False, True):
            result = input_scope(Mock(), HEAD, skip)
            self.assertEqual((result['mode'], result['source']), ('skip' if skip else 'run', 'manual'))

    def test_frozen_dispatch_scope_is_validated(self):
        git = Mock(); git.ancestor.return_value = True
        self.assertEqual(input_scope(git, HEAD, True, json.dumps(scope())), scope())
        for head, skip in ((BASE, True), (HEAD, False)):
            with self.assertRaises(VersionError):
                input_scope(git, head, skip, json.dumps(scope()))
        git.ancestor.return_value = False
        with self.assertRaises(VersionError):
            input_scope(git, HEAD, True, json.dumps(scope()))

    def test_malformed_scope_and_json(self):
        for value in (None, [], {}, {**scope(), 'mode': 'all'}, {**scope(), 'source': 'other'},
                      {**scope(), 'head_sha': 'HEAD'}, {**scope(), 'base_sha': 'main'}, {**scope(), 'reason': ''},
                      {**scope(), 'schema': True}, {**scope(), 'mode': []}, {**scope(), 'source': {}}):
            with self.subTest(value=value), self.assertRaises(VersionError):
                validate_scope(value)
        with self.assertRaises(VersionError):
            input_scope(Mock(), HEAD, True, 'not-json')

    def test_baseline_requires_both_success_and_ancestry(self):
        records = [{**candidate(n), 'build_sha': str(n) * 40} for n in (1, 2, 3)]
        current = candidate(4)
        runs = {p: [{**run(p), 'display_title': run_title(p, c['candidate_id']),
                     'head_sha': c['build_sha']} for c in records] for p in ('android', 'ios')}
        runs['ios'][-1]['conclusion'] = 'failure'
        git = Mock(); git.ancestor.return_value = True
        self.assertEqual(baseline(git, current, records, runs), '2' * 40)
        git.ancestor.side_effect = lambda older, newer: older == '1' * 40
        self.assertEqual(baseline(git, current, records, runs), '1' * 40)
        git.ancestor.side_effect = lambda *_: False
        git.text.return_value = BASE
        self.assertEqual(baseline(git, current, records, runs), BASE)

    def test_source_and_event_must_match_for_run_identity(self):
        self.assertTrue(candidate_run(run(), candidate(), 'ios'))
        for update in ({'head_sha': BASE}, {'event': 'pull_request'}, {'head_branch': 'untrusted'}):
            self.assertFalse(candidate_run({**run(), **update}, candidate(), 'ios'))


class GitRangeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git = Git(self.root)
        self.git.run('init', '-b', 'main')
        self.git.run('config', 'user.name', 'Policy Test')
        self.git.run('config', 'user.email', 'policy@example.test')
        self.git.run('config', 'commit.gpgsign', 'false')
        self.git.run('config', 'core.hooksPath', str(self.root / 'no-hooks'))
        self.base = self.add('pubspec.yaml', 'version: 1.0.0+1\n', 'chore: initial')

    def add(self, path, content, message):
        target = self.root / path; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding='utf-8')
        self.git.run('add', '--', path)
        self.git.run('commit', '-m', message)
        return self.git.text('rev-parse', 'HEAD')

    def test_pr_covers_all_commits_and_uses_merge_base(self):
        self.git.run('checkout', '-b', 'feature')
        first = self.add('lib/queue.dart', 'request cancellation', commit('run').message)
        head = self.add('docs/note.md', 'documentation', 'docs: explain')
        self.git.run('checkout', 'main')
        base_head = self.add('README.md', 'base branch advanced', 'docs: base')
        decision = pr_scope(self.git, base_head, head)
        self.assertEqual(decision['base_sha'], self.base)
        self.assertEqual(decision['mode'], 'run')
        self.assertIn(first[:8], decision['reason'])

    def test_auto_version_is_ignored_but_dependency_change_is_not(self):
        source = self.add('ci.txt', 'config', commit('skip').message)
        (self.root / '.release').mkdir()
        (self.root / '.release/candidate.json').write_text(json.dumps({'source_sha': source}))
        self.git.run('add', '.release/candidate.json')
        auto = self.add('pubspec.yaml', 'version: 1.0.1+2\n', 'chore(release): prepare 1.0.1+2')
        self.assertEqual([c.sha for c in range_commits(self.git, self.base, auto)], [source])
        (self.root / '.release/candidate.json').write_text(json.dumps({'source_sha': auto}))
        self.git.run('add', '.release/candidate.json')
        head = self.add('pubspec.yaml', 'version: 1.0.1+3\ndependencies: changed\n', 'chore(release): prepare 1.0.1+3')
        self.assertEqual(select(range_commits(self.git, auto, head), auto, head)['mode'], 'run')

    def test_merge_resolution_cannot_hide_undeclared_change(self):
        base = self.add('lib/shared.dart', 'original\n', commit('skip').message)
        self.git.run('checkout', '-b', 'feature')
        self.add('lib/shared.dart', 'feature\n', commit('skip').message)
        self.git.run('checkout', 'main')
        self.add('lib/shared.dart', 'main\n', commit('skip').message)
        with self.assertRaises(VersionError):
            self.git.run('merge', '--no-ff', 'feature')
        head = self.add('lib/shared.dart', 'custom resolution\n', 'Merge with behavioral resolution')
        commits = range_commits(self.git, base, head)
        self.assertTrue(any(c.merge and 'lib/shared.dart' in c.paths for c in commits))
        self.assertEqual(select(commits, base, head)['mode'], 'run')

    def test_pr_workflow_needs_no_github_api(self):
        head = self.add('lib/reader.dart', 'only text', commit('skip').message)
        output = self.root / 'output'; summary = self.root / 'summary'
        env = {'GITHUB_EVENT_NAME': 'pull_request', 'PR_BASE_SHA': self.base, 'PR_HEAD_SHA': head,
               'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary),
               'SKIP_READER_PREFETCH_TESTS': 'false'}
        with patch.dict(os.environ, {**env, 'GH_TOKEN': '', 'GITHUB_TOKEN': ''}), patch('sys.argv', ['policy', 'workflow']), \
                patch('scripts.versioning.test_policy.Git', return_value=self.git), \
                patch('scripts.versioning.test_policy.SCOPE_PATH', self.root / 'scope.json'), \
                patch('scripts.versioning.test_policy.GitHub', side_effect=AssertionError('No API in PR')):
            main()
        self.assertEqual(output.read_text(), 'skip_slow=true\n')
        self.assertIn('pull_request', summary.read_text())


class DispatchTests(unittest.TestCase):
    def exercise(self, mode, existing):
        api = Mock(); api.pages.return_value = []
        runs = {p: [run(p, **item) for item in existing] for p in ('android', 'ios')}
        with patch('scripts.versioning.dispatch.candidate_by_id', return_value=candidate()), \
                patch('scripts.versioning.dispatch.workflow_runs', return_value=runs), \
                patch('scripts.versioning.dispatch.candidate_scope', return_value=scope(mode)) as resolver:
            dispatch(api, '1.0.1+2', 'dev', mode, git=Mock())
        self.assertEqual(resolver.call_args.args[-1], mode)
        return api

    def test_automatic_decision_passes_bool_and_record_to_both_platforms(self):
        for mode in ('skip', 'run'):
            api = self.exercise(mode, [])
            self.assertEqual(api.request.call_count, 2)
            for call in api.request.call_args_list:
                inputs = call.args[1]['inputs']
                self.assertEqual(inputs['skip_reader_prefetch_tests'], mode == 'skip')
                self.assertEqual(json.loads(inputs['test_scope']), scope(mode))

    def test_matching_scope_reuses_running_or_successful_runs(self):
        for status, conclusion in (('in_progress', None), ('completed', 'success')):
            self.exercise('skip', [{'mode': 'skip', 'status': status, 'conclusion': conclusion}]).request.assert_not_called()

    def test_different_unknown_failed_or_wrong_source_runs_are_not_reused(self):
        for existing in ({'mode': 'skip'}, {'mode': None}, {'mode': 'run', 'conclusion': 'failure'},
                         {'mode': 'run', 'conclusion': 'cancelled'}, {'mode': 'run', 'sha': BASE}):
            self.assertEqual(self.exercise('run', [existing]).request.call_count, 2)

    def test_uncertain_post_is_not_retried(self):
        api = Mock(); api.request.side_effect = TimeoutError('uncertain response')
        with patch('scripts.versioning.dispatch.candidate_by_id', return_value=candidate()), \
                patch('scripts.versioning.dispatch.workflow_runs', return_value={'ios': [], 'android': []}), \
                patch('scripts.versioning.dispatch.candidate_scope', return_value=scope()), \
                self.assertRaises(TimeoutError):
            dispatch(api, '1.0.1+2', 'dev', git=Mock())
        self.assertEqual(api.request.call_count, 1)


class MetadataTests(unittest.TestCase):
    def test_rebuild_on_later_head_uses_verified_metadata_not_title_alone(self):
        api = Mock()
        api.pages.return_value = [{'id': 99, 'name': 'build-metadata', 'expired': False}]
        record = {**candidate(), 'schema': 1, 'platform': 'ios', 'run_id': 42, 'run_attempt': 1, 'test_scope': scope()}
        for change, accepted in (({}, True), ({'source_sha': BASE}, False), ({'run_attempt': 2}, False),
                                 ({'test_scope': scope('run')}, False)):
            payload = io.BytesIO()
            with zipfile.ZipFile(payload, 'w') as archive:
                archive.writestr('build-metadata.json', json.dumps({**record, **change}))
            api.request.return_value = payload.getvalue()
            self.assertEqual(verified_run(api, run(sha=BASE), candidate(), 'ios'), accepted)
        api.request.reset_mock()
        self.assertFalse(verified_run(api, run(sha=BASE, status='in_progress', conclusion=None), candidate(), 'ios'))
        api.request.assert_not_called()

    def test_optional_scope_preserves_legacy_and_binds_source(self):
        with patch('scripts.versioning.build.inspect_package', return_value={'version': '1.0.1', 'build_number': 2}), \
                patch('scripts.versioning.build.file_digest', return_value={'sha256': 'hash'}):
            args = (candidate(), Path('unused'), 'ios', 42, 1)
            self.assertNotIn('test_scope', metadata(*args))
            self.assertEqual(metadata(*args, test_scope=scope())['test_scope'], scope())
            with self.assertRaises(VersionError):
                metadata(*args, test_scope={**scope(), 'head_sha': BASE})

    def test_release_reads_skip_scope_without_requiring_full_suite(self):
        import hashlib
        payload = b'ipa'
        record = {'schema': 1, 'platform': 'ios', 'candidate_id': '1.0.1+2', 'source_sha': HEAD,
                  'run_id': 42, 'run_attempt': 1, 'filename': 'OViewer.ipa', 'size': 3,
                  'sha256': hashlib.sha256(payload).hexdigest(), 'version': '1.0.1', 'build_number': 2,
                  'test_scope': scope()}
        api = Mock(repository='owner/repo'); api.pages.return_value = []
        api.request.side_effect = lambda path: {'id': 3} if '/workflows/' in path else run()
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('build-metadata.json', json.dumps(record))
        with tempfile.TemporaryDirectory() as folder, \
                patch('scripts.versioning.release.artifact', side_effect=[archive.getvalue(), payload]), \
                patch('scripts.versioning.release.inspect_package', return_value={'version': '1.0.1', 'build_number': 2}):
            result, _ = read_build(api, 'ios', 42, Path(folder))
        self.assertEqual(result['test_scope']['mode'], 'skip')
        validate_pair({**candidate(), 'test_scope': scope('run')},
                      {**candidate(), 'test_scope': scope()}, candidate(), 'v1.0.1')

    def test_mismatched_new_title_or_scope_is_rejected(self):
        import hashlib
        record = {'schema': 1, 'platform': 'ios', 'candidate_id': '1.0.1+2', 'source_sha': HEAD,
                  'run_id': 42, 'run_attempt': 1, 'filename': 'OViewer.ipa', 'size': 3,
                  'sha256': hashlib.sha256(b'ipa').hexdigest(), 'version': '1.0.1', 'build_number': 2}
        for extra in ({}, {'test_scope': scope('run')}, {'test_scope': {**scope(), 'head_sha': BASE}}):
            api = Mock(repository='owner/repo'); api.pages.return_value = []
            api.request.side_effect = lambda path: {'id': 3} if '/workflows/' in path else run()
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('build-metadata.json', json.dumps({**record, **extra}))
            with tempfile.TemporaryDirectory() as folder, \
                    patch('scripts.versioning.release.artifact', side_effect=[archive.getvalue(), b'ipa']), \
                    self.assertRaises(VersionError):
                read_build(api, 'ios', 42, Path(folder))

    def test_release_notes_disclose_scope_without_requiring_full_suite(self):
        metadata = {'run_id': 42, 'run_attempt': 1, 'sha256': 'hash', 'signing_cert_sha256': 'cert'}
        notes = release_notes({**candidate(), 'summary': [], 'notes': ''},
                              {**metadata, 'test_scope': scope()}, metadata)
        self.assertIn('跳过 reader_prefetch_slow', notes)
        self.assertIn('未记录（历史产物）', notes)


if __name__ == '__main__':
    unittest.main()
