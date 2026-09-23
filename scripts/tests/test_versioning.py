import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.versioning.github import GitHub
from scripts.versioning.prepare import Ledger, prepare
from scripts.versioning.rules import Commit, Git, VersionError, next_version, package_version, reusable_candidate, with_version


class RulesTests(unittest.TestCase):
    def calculate(self, *messages):
        return next_version("1.2.3", [Commit(str(i), m, ("lib/a.dart",)) for i, m in enumerate(messages)], set())[0]

    def test_highest_level_wins(self):
        self.assertEqual(self.calculate("fix: a", "feat(reader): b", "perf: c"), "1.3.0")

    def test_breaking_forms(self):
        for message in ("fix!: a", "feat(reader)!: b", "chore: c\n\nBREAKING CHANGE: data migration", "fix: d\n\nBREAKING-CHANGE: remove format"):
            with self.subTest(message=message):
                self.assertEqual(self.calculate(message), "2.0.0")

    def test_patch_types(self):
        for kind in ("fix", "perf", "build", "ci", "test", "chore", "refactor", "revert", "style", "docs"):
            self.assertEqual(self.calculate(f"{kind}: effective change"), "1.2.4")

    def test_multiple_fixes_do_not_accumulate(self):
        self.assertEqual(self.calculate("fix: one", "fix: two"), "1.2.4")

    def test_invalid_commit_identified_even_if_documentation_only(self):
        for message in ("Fix bug", "unknown: x", "feat:", "fix: "):
            with self.assertRaisesRegex(VersionError, "bad-sha"):
                next_version("1.0.0", [Commit("bad-sha", message, ("README.md",))], set())

    def test_registered_automation_and_merges_are_ignored(self):
        commits = [Commit("auto", "unusual registered version commit", ("pubspec.yaml",)), Commit("merge", "Merge branch dev", (), True), Commit("docs", "feat!: documentation", ("docs/README.md", "LICENSE"))]
        version, summary = next_version("1.0.0", commits, {"auto"})
        self.assertEqual(summary, [])
        self.assertEqual(version, "1.0.1")  # Caller decides whether content changed.

    def test_pubspec_strict_and_preserves_blank_lines(self):
        original = "name: app\nversion: 1.0.0+1\n\nenvironment:\n  sdk: any\n"
        updated = with_version(original, "1.0.1", 2)
        self.assertEqual(updated, original.replace("1.0.0+1", "1.0.1+2"))
        self.assertEqual(package_version(updated), ("1.0.1", 2))
        for text in ("version: 1.0.0", "version: 1.0.0+0", "version: 01.0.0+1", original + "version: 2.0.0+2\n"):
            with self.assertRaises(VersionError):
                package_version(text)
        with self.assertRaises(VersionError):
            with_version(original, "1.0.1", 2100000001)


class GitIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git = Git(self.root)
        self.git.run("init", "-b", "dev")
        self.git.run("config", "user.email", "test@example.invalid")
        self.git.run("config", "user.name", "Test")
        self.write("pubspec.yaml", "version: 1.0.0+1\n")
        self.write("lib/app.dart", "original\n")
        self.base = self.commit("feat: baseline")

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")

    def commit(self, message):
        self.git.run("add", ".")
        self.git.run("commit", "-m", message)
        return self.git.text("rev-parse", "HEAD")

    def test_docs_and_generated_version_do_not_change_fingerprint(self):
        fingerprint = self.git.fingerprint(self.base)
        self.write("docs/example.txt", "docs")
        self.write("README.md", "docs")
        self.write("LICENSE", "license")
        self.write("pubspec.yaml", "version: 2.3.4+200\n")
        self.write(".release/candidate.json", "{}")
        candidate = self.commit("chore: bump")
        self.assertEqual(self.git.fingerprint(candidate), fingerprint)
        self.write("pubspec.yaml", "version: 2.3.4+200\ndependencies: {}\n")
        self.assertNotEqual(self.git.fingerprint(self.commit("build: dependency")), fingerprint)

    def test_promote_and_merge_resolution(self):
        self.write("lib/app.dart", "fix")
        candidate = self.commit("fix: bug")
        fingerprint = self.git.fingerprint(candidate)
        record = {"build_number": 2, "build_sha": candidate, "base_tag": "v1.0.0", "fingerprint": fingerprint, "stage": "ready"}
        self.git.run("checkout", "-b", "main", self.base)
        self.git.run("merge", "--no-ff", "dev", "-m", "Merge dev")
        source = self.git.text("rev-parse", "HEAD")
        self.assertEqual(reusable_candidate([record], self.git.fingerprint(source), source, "v1.0.0", self.git), record)
        self.write("lib/app.dart", "resolution changed code")
        source = self.commit("fix: resolution")
        self.assertIsNone(reusable_candidate([record], self.git.fingerprint(source), source, "v1.0.0", self.git))

    def test_squash_requires_new_candidate(self):
        self.write("lib/app.dart", "fix")
        candidate = self.commit("fix: bug")
        fingerprint = self.git.fingerprint(candidate)
        record = {"build_number": 2, "build_sha": candidate, "base_tag": "v1.0.0", "fingerprint": fingerprint, "stage": "ready"}
        self.git.run("checkout", "-b", "main", self.base)
        self.git.run("merge", "--squash", "dev")
        source = self.commit("fix: squash")
        self.assertIsNone(reusable_candidate([record], fingerprint, source, "v1.0.0", self.git))

    def test_branch_missing_stable_is_rejected(self):
        self.write("lib/app.dart", "new stable")
        stable = self.commit("fix: stable")
        with self.assertRaisesRegex(VersionError, "latest stable"):
            self.git.commits(stable, self.base)


class FakeGit:
    def run(self, *args):
        return b""

    def commits(self, base, source):
        return [Commit(source, "fix: something", ("lib/app.dart",))]

    def fingerprint(self, ref):
        return "base" if ref.startswith("v") else "changed"

    def file(self, ref, path):
        if path == "CHANGELOG.md":
            return "## [Unreleased]\n\n### 修复\n- 用户说明\n\n## [1.0.0]\ninitial\n"
        return "version: 1.0.0+1\n"

    def ancestor(self, a, b):
        return a == b


class FakeAPI:
    def __init__(self):
        self.source = "a" * 40
        self.refs = {"dev": self.source}
        self.objects = {}
        self.counter = 0
        self.fail_branch_once = False
        self.fail_ready_once = False

    def ref(self, branch):
        return self.refs.get(branch)

    def file(self, ref, path):
        return self.objects[ref]["files"][path]

    def pages(self, path):
        return [{"draft": False, "prerelease": False, "tag_name": "v1.0.0"}]

    def commit(self, parent, files, message):
        self.counter += 1
        sha = f"{self.counter:040x}"
        self.objects[sha] = {"parents": [{"sha": parent}] if parent else [], "files": copy.deepcopy(files)}
        return sha

    def compare_and_swap(self, branch, expected, commit):
        if branch == "dev" and self.fail_branch_once:
            self.fail_branch_once = False
            raise RuntimeError("interruption before branch update")
        if branch == "version-state" and self.fail_ready_once and '"stage": "ready"' in self.objects[commit]["files"]["ledger.json"]:
            self.fail_ready_once = False
            raise RuntimeError("interruption after branch update")
        if self.refs.get(branch) != expected:
            raise VersionError("Branch advanced")
        self.refs[branch] = commit

    def request(self, path, *args):
        if path.startswith("/git/commits/"):
            return self.objects[path.rsplit("/", 1)[-1]]
        raise AssertionError(path)


class TransactionTests(unittest.TestCase):
    def test_new_candidate_records_source_notes_and_common_version(self):
        api = FakeAPI()
        candidate = prepare(api, FakeGit(), "dev", api.source)
        self.assertEqual(candidate["candidate_id"], "1.0.1+2")
        self.assertEqual(candidate["stage"], "ready")
        self.assertIn("用户说明", candidate["notes"])
        self.assertNotIn("initial", candidate["notes"])
        self.assertEqual(api.ref("dev"), candidate["build_sha"])
        self.assertEqual(package_version(api.file(candidate["build_sha"], "pubspec.yaml")), ("1.0.1", 2))

    def test_retry_after_reservation_and_after_branch_write(self):
        for failure in ("fail_branch_once", "fail_ready_once"):
            api = FakeAPI()
            setattr(api, failure, True)
            with self.assertRaises(RuntimeError):
                prepare(api, FakeGit(), "dev", api.source)
            reserved = Ledger(api).data["candidates"][0]
            restored = prepare(api, FakeGit(), "dev", api.source)
            self.assertEqual(restored["build_sha"], reserved["build_sha"])
            self.assertEqual(Ledger(api).data["last_build_number"], 2)
            self.assertEqual(len(Ledger(api).data["candidates"]), 1)
            self.assertEqual(prepare(api, FakeGit(), "dev", api.source), restored)

    def test_stale_source_does_not_allocate(self):
        api = FakeAPI()
        api.refs["dev"] = "b" * 40
        with self.assertRaisesRegex(VersionError, "advanced"):
            prepare(api, FakeGit(), "dev", api.source)
        self.assertIsNone(api.ref("version-state"))

    def test_concurrent_ledger_writers_cannot_reuse_number(self):
        api = FakeAPI()
        first, second = Ledger(api), Ledger(api)
        first.data["last_build_number"] = 2
        first.save()
        with self.assertRaisesRegex(VersionError, "advanced"):
            second.save()
        self.assertEqual(Ledger(api).data["last_build_number"], 2)

    def test_docs_only_does_not_allocate(self):
        api, git = FakeAPI(), FakeGit()
        git.fingerprint = lambda ref: "same"
        self.assertIsNone(prepare(api, git, "dev", api.source))
        self.assertIsNone(api.ref("version-state"))

    def test_compare_and_swap_refuses_wrong_parent(self):
        api = FakeAPI()
        candidate = api.commit("b" * 40, {}, "chore: bad parent")
        with self.assertRaisesRegex(VersionError, "parents"):
            GitHub.compare_and_swap(api, "dev", api.source, candidate)


if __name__ == "__main__":
    unittest.main()
