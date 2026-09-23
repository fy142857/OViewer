import copy
import hashlib
import io
import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts.versioning.analyze import diagnostics, new_diagnostics
from scripts.versioning.build import inspect_package, metadata
from scripts.versioning.release import artifact, check_assets, publish, read_build, validate_pair, validate_run, validate_tag
from scripts.versioning.rules import VersionError


class PackageTests(unittest.TestCase):
    def test_reads_actual_ipa_version_and_rejects_other_app(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "OViewer.ipa"
            for bundle in ("com.oviewer.oviewer", "other.app"):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": bundle, "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.3"}, fmt=plistlib.FMT_BINARY))
                if bundle.startswith("com.oviewer"):
                    self.assertEqual(inspect_package(path, "ios"), {"version": "1.2.3", "build_number": 42})
                else:
                    with self.assertRaisesRegex(VersionError, "identifier"):
                        inspect_package(path, "ios")

    @patch("scripts.versioning.build.android_tool", side_effect=lambda name: name)
    @patch("scripts.versioning.build.command")
    def test_apk_signature_and_version(self, command, _):
        badging = "package: name='com.oviewer.oviewer' versionCode='3' versionName='1.0.1'\n"
        signer = "Signer #1 certificate SHA-256 digest: " + "ab" * 32 + "\n"
        command.side_effect = [badging, signer]
        self.assertEqual(inspect_package(Path("app.apk"), "android", "AB:" * 31 + "AB")["build_number"], 3)
        for output, cert in [(signer, "cd" * 32), (signer + "Signer #1 certificate DN: CN=Android Debug", "ab" * 32), (signer, None), (signer + signer.replace("#1", "#2"), "ab" * 32)]:
            command.side_effect = [badging, output]
            with self.assertRaises(VersionError):
                inspect_package(Path("app.apk"), "android", cert)

    @patch("scripts.versioning.build.inspect_package", return_value={"version": "1.0.0", "build_number": 1})
    def test_metadata_rejects_package_version_mismatch(self, _):
        with self.assertRaisesRegex(VersionError, "version"):
            metadata({"version": "1.0.1", "build_number": 2}, Path("none"), "ios", 42, 1)


class ReleaseGuards(unittest.TestCase):
    def setUp(self):
        self.run = {"id": 42, "run_attempt": 2, "workflow_id": 3, "repository": {"full_name": "owner/repo"}, "head_repository": {"full_name": "owner/repo"}, "status": "completed", "conclusion": "success", "event": "workflow_dispatch", "pull_requests": []}

    def test_wrong_workflow_repository_failure_or_pr_rejected(self):
        validate_run(self.run, {"id": 3}, "owner/repo")
        for updates in ({"workflow_id": 4}, {"conclusion": "failure"}, {"conclusion": "cancelled"}, {"status": "in_progress"}, {"event": "pull_request"}, {"event": "push"}, {"head_repository": {"full_name": "fork/repo"}}, {"repository": {"full_name": "elsewhere/repo"}}, {"pull_requests": [{"id": 1}]}):
            with self.subTest(updates=updates), self.assertRaises(VersionError):
                validate_run({**self.run, **updates}, {"id": 3}, "owner/repo")

    def test_pair_rejects_each_identity_mismatch(self):
        candidate = {"candidate_id": "1.0.1+2", "build_sha": "a" * 40, "source_sha": "b" * 40, "version": "1.0.1", "build_number": 2}
        validate_pair(candidate, candidate, candidate, "v1.0.1")
        for key in candidate:
            with self.subTest(key=key), self.assertRaises(VersionError):
                validate_pair(candidate, {**candidate, key: "wrong"}, candidate, "v1.0.1")
        with self.assertRaises(VersionError):
            validate_pair(candidate, candidate, candidate, "v1.0.2")

    def test_missing_duplicate_and_expired_artifacts(self):
        for artifacts in ([], [{"name": "OViewer.ipa", "expired": True}], [{"name": "OViewer.ipa"}, {"name": "OViewer.ipa"}]):
            with self.assertRaises(VersionError):
                artifact(None, artifacts, "OViewer.ipa")

    def test_stale_attempt_tampered_download_and_package_version_are_rejected(self):
        from unittest.mock import Mock
        candidate = {"schema": 1, "platform": "ios", "candidate_id": "1.0.1+2", "run_id": 42,
                     "run_attempt": 2, "filename": "OViewer.ipa", "size": 3,
                     "sha256": hashlib.sha256(b"ipa").hexdigest(), "version": "1.0.1", "build_number": 2}
        api = Mock(repository="owner/repo")
        api.request.side_effect = lambda path: {"id": 3} if "/workflows/" in path else {**self.run, "display_title": "ios / 1.0.1+2"}
        api.pages.return_value = []
        cases = [("run_attempt", 1, "earlier run attempt"), ("sha256", "wrong", "sha256 mismatch"),
                 ("version", "1.0.2", "package version")]
        for key, value, reason in cases:
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w") as archive:
                archive.writestr("build-metadata.json", json.dumps({**candidate, key: value}))
            with tempfile.TemporaryDirectory() as directory, \
                    patch("scripts.versioning.release.artifact", side_effect=[stream.getvalue(), b"ipa"]), \
                    patch("scripts.versioning.release.inspect_package", return_value={"version": "1.0.1", "build_number": 2}), \
                    self.subTest(key=key), self.assertRaisesRegex(VersionError, reason):
                read_build(api, "ios", 42, Path(directory))


class FakeReleaseAPI:
    def __init__(self):
        self.releases = []
        self.assets = []
        self.payloads = {}
        self.writes = []
        self.tag = None
        self.interrupt_upload = None

    def pages(self, path):
        return copy.deepcopy(self.releases if path == "/releases" else self.assets)

    def optional(self, path):
        return self.tag

    def request(self, path, data=None, method=None, binary=False):
        if binary:
            return self.payloads[int(path.rsplit("/", 1)[-1])]
        if data is None:
            if path.startswith("/releases/"):
                return copy.deepcopy(self.releases[0])
            raise AssertionError(path)
        self.writes.append((path, method))
        if path == "/releases":
            self.releases.append({**data, "id": 1, "html_url": "https://example.invalid/draft", "upload_url": "https://uploads.github.com/x/assets{?name}"})
            return copy.deepcopy(self.releases[0])
        if path.startswith("https://uploads.github.com/"):
            name = path.split("name=", 1)[1]
            if self.interrupt_upload == name:
                self.interrupt_upload = None
                raise RuntimeError("interrupted upload")
            identity = len(self.assets) + 1
            self.assets.append({"id": identity, "name": name, "state": "uploaded", "size": len(data)})
            self.payloads[identity] = data
            return self.assets[-1]
        if path == "/git/refs":
            self.tag = {"object": {"type": "commit", "sha": data["sha"]}}
            return self.tag
        if path == "/releases/1" and method == "PATCH":
            self.releases[0].update(data)
            return copy.deepcopy(self.releases[0])
        raise AssertionError(path)


class DraftTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.files = [Path(self.temp.name) / name for name in ("app-release.apk", "OViewer.ipa", "release-manifest.json", "SHA256SUMS.txt")]
        for path in self.files:
            path.write_bytes(path.name.encode())
        self.api = FakeReleaseAPI()
        self.candidate = {"build_sha": "a" * 40}

    def publish(self, check_only=False):
        publish(self.api, "v1.0.1", self.candidate, self.files, "notes", check_only)

    def test_check_only_writes_nothing(self):
        self.publish(True)
        self.assertEqual(self.api.writes, [])

    def test_upload_interruption_preserves_draft_and_retry_only_adds_missing(self):
        self.api.interrupt_upload = "OViewer.ipa"
        with self.assertRaises(RuntimeError):
            self.publish()
        self.assertTrue(self.api.releases[0]["draft"])
        self.assertIsNone(self.api.tag)
        self.assertEqual([a["name"] for a in self.api.assets], ["app-release.apk"])
        self.publish()
        self.assertFalse(self.api.releases[0]["draft"])
        self.assertEqual(len(self.api.assets), 4)
        apk_uploads = [path for path, _ in self.api.writes if "name=app-release.apk" in path]
        self.assertEqual(len(apk_uploads), 1)

    def test_duplicate_published_release_is_never_changed(self):
        self.publish()
        previous = len(self.api.writes)
        with self.assertRaisesRegex(VersionError, "published"):
            self.publish()
        self.assertEqual(len(self.api.writes), previous)

    def test_wrong_tag_or_attachment_stops_without_overwrite(self):
        self.api.tag = {"object": {"type": "commit", "sha": "wrong"}}
        with self.assertRaisesRegex(VersionError, "tag"):
            self.publish()
        self.assertEqual(self.api.writes, [])
        self.api.tag = None
        self.api.interrupt_upload = "OViewer.ipa"
        with self.assertRaises(RuntimeError):
            self.publish()
        self.api.payloads[1] = b"tampered"
        previous = len(self.api.writes)
        with self.assertRaisesRegex(VersionError, "SHA-256"):
            self.publish()
        self.assertEqual(len(self.api.writes), previous)

    def test_partial_uploaded_asset_is_not_deleted(self):
        self.api.interrupt_upload = "OViewer.ipa"
        with self.assertRaises(RuntimeError):
            self.publish()
        self.api.assets[0]["state"] = "starter"
        with self.assertRaisesRegex(VersionError, "incomplete"):
            self.publish()


class AnalyzerTests(unittest.TestCase):
    def test_new_warning_and_duplicate_warning_blocked(self):
        item = {"severity": "WARNING", "code": "RULE", "path": "lib/a.dart", "message": "message"}
        self.assertEqual(new_diagnostics([item], [item]), [])
        self.assertEqual(new_diagnostics([item, item], [item]), [item])
        self.assertEqual(new_diagnostics([item], []), [item])
        self.assertEqual(new_diagnostics([{**item, "severity": "INFO"}], []), [])

    def test_line_drift_ignored_and_crash_output_rejected(self):
        root = Path.cwd()
        def parse(line):
            return diagnostics(f"WARNING|STATIC_WARNING|RULE|{root.as_posix()}/lib/a.dart|{line}|1|3|message", root)
        self.assertEqual(parse(1), parse(30))
        with self.assertRaises(VersionError):
            diagnostics("analyzer crashed", root)


if __name__ == "__main__":
    unittest.main()
