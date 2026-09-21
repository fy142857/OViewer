import hashlib
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.request
import zipfile

import ios_install as cli
import sideloadly_windows as windows


def ipa_bytes():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "org.test.viewer"}))
        archive.writestr("Payload/Runner.app/Runner", b"test executable")
    return stream.getvalue()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_raw_ipa_is_not_treated_as_outer_zip(self):
        source, target = self.root / "artifact.bin", self.root / "app.ipa"
        source.write_bytes(ipa_bytes())
        info = cli.unpack_artifact(source, target)
        self.assertEqual(info["CFBundleIdentifier"], "org.test.viewer")
        self.assertEqual(source.read_bytes(), target.read_bytes())

    def test_legacy_zip_does_not_extract_supplied_paths(self):
        source, target = self.root / "archive.zip", self.root / "app.ipa"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("../../outside.ipa", ipa_bytes())
        cli.unpack_artifact(source, target)
        self.assertEqual(target.read_bytes(), ipa_bytes())
        self.assertEqual({p.name for p in self.root.iterdir()}, {"archive.zip", "app.ipa"})

    def test_ambiguous_legacy_archive_rejected(self):
        source = self.root / "archive.zip"
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("a.ipa", ipa_bytes())
            archive.writestr("b.ipa", ipa_bytes())
        with self.assertRaises(cli.InstallerError):
            cli.unpack_artifact(source, self.root / "app.ipa")

    def test_invalid_ipa_rejected(self):
        path = self.root / "bad.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("not-an-app", b"test")
        with self.assertRaises(cli.InstallerError):
            cli.ipa_info(path)

    def test_redirect_strips_token(self):
        request = urllib.request.Request("https://api.github.com/artifact", headers={"Authorization": "Bearer secret"})
        redirected = cli.SafeRedirect().redirect_request(request, None, 302, "Found", {}, "https://storage.example/file")
        self.assertFalse(redirected.has_header("Authorization"))
        with self.assertRaises(cli.InstallerError):
            cli.SafeRedirect().redirect_request(request, None, 302, "Found", {}, "http://storage.example/file")

    def fake_download(self, digest=None, expired=False):
        raw = ipa_bytes()
        artifact = {"id": 20, "name": "OViewer.ipa", "expired": expired,
                    "digest": digest or "sha256:" + hashlib.sha256(raw).hexdigest()}
        run = {"id": 10, "run_number": 3, "head_sha": "abcdef12345", "status": "completed",
               "conclusion": "success", "html_url": "https://github.com/test/actions/runs/10"}
        gh = Mock()
        gh.artifacts.return_value = [artifact]
        response = io.BytesIO(raw)
        response.headers = {"Content-Length": str(len(raw))}
        gh.request.return_value = response
        return gh, run

    def test_download_verified_with_provenance(self):
        gh, run = self.fake_download()
        path = cli.download(gh, run, self.root)
        self.assertIn("run10-attempt1-abcdef12", path.name)
        self.assertEqual(json.loads(path.with_suffix(".json").read_text())["run_id"], 10)

    def test_legacy_project_artifact_name(self):
        gh, run = self.fake_download()
        gh.artifacts.return_value[0]["name"] = "OViewer-iOS"
        self.assertIsNotNone(cli.download(gh, run, self.root))

    def test_digest_failure_does_not_leave_ipa(self):
        gh, run = self.fake_download("sha256:incorrect")
        with self.assertRaises(cli.InstallerError):
            cli.download(gh, run, self.root)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_expired_and_failed_builds_rejected(self):
        gh, run = self.fake_download(expired=True)
        with self.assertRaises(cli.InstallerError):
            cli.download(gh, run, self.root)
        run["conclusion"] = "failure"
        with self.assertRaises(cli.InstallerError):
            cli.download(gh, run, self.root)
        gh.request.assert_not_called()

    def test_no_ipad_does_not_launch_sideloadly(self):
        with patch.object(windows, "connected_ipads", return_value=[]), patch.object(windows, "find_sideloadly") as find:
            self.assertEqual(windows.install_ipa(self.root / "app.ipa"), 2)
            find.assert_not_called()

    def test_multiple_ipads_require_exact_target(self):
        devices = [{"udid": "1234567890abcdef1234"}, {"udid": "abcdef12345678901234"}]
        with self.assertRaises(RuntimeError):
            windows.select_device(devices)
        self.assertEqual(windows.select_device(devices, "12345678-90abcdef1234"), devices[0])
        with self.assertRaises(RuntimeError):
            windows.select_device(devices, "not-connected")

    def test_device_combo_rejects_wifi_and_wrong_device(self):
        udid = "1234567890abcdef1234"
        correct = f"Renamed iPad (16.7) {udid} @USB"
        self.assertEqual(windows.device_item([f"iPad {udid} @WiFi", correct], udid), correct)
        with self.assertRaises(RuntimeError):
            windows.device_item([f"iPad {udid} @WiFi"], udid)

    def test_dirty_worktree_never_pushes(self):
        with patch.object(cli, "command", return_value=Mock(stdout=" M file")) as command:
            with self.assertRaises(cli.InstallerError):
                cli.build(Mock(), Mock())
            self.assertEqual(command.call_count, 1)

    def test_auto_binds_push_run_to_head(self):
        args = Mock(remote="origin", timeout=10)
        run = {"id": 2, "head_sha": "abc", "status": "completed", "conclusion": "success"}
        gh = Mock()
        gh.runs.side_effect = [[{"id": 1}], [run]]
        outputs = ["", "dev", "abc", "old refs/heads/dev", ""]
        with patch.object(cli, "command", side_effect=[Mock(stdout=s) for s in outputs]) as command, \
                patch.object(cli, "wait_run", return_value=run):
            self.assertEqual(cli.build(gh, args), run)
            self.assertEqual(command.call_args.args[0], ["git", "push", "origin", "abc:refs/heads/dev"])
            gh.runs.assert_called_with(branch="dev", head_sha="abc", event="push")
            gh.api.assert_not_called()

    def test_failed_run_never_counts_as_success(self):
        run = {"id": 1, "run_number": 1, "html_url": "url", "status": "completed", "conclusion": "failure"}
        with self.assertRaises(cli.InstallerError):
            cli.wait_run(Mock(), run, 1)

    def test_unchanged_head_dispatch_uses_unique_request(self):
        args = Mock(remote="origin", timeout=10)
        run = {"id": 2, "head_sha": "abc", "display_title": "iOS installer request123"}
        gh = Mock()
        gh.runs.side_effect = [[{"id": 1}], [run]]
        outputs = ["", "dev", "abc", "abc refs/heads/dev", ""]
        with patch.object(cli, "command", side_effect=[Mock(stdout=s) for s in outputs]), \
                patch.object(cli.uuid, "uuid4", return_value=Mock(hex="request123")), \
                patch.object(cli, "wait_run", return_value=run):
            self.assertEqual(cli.build(gh, args), run)
        gh.api.assert_called_once_with("/actions/workflows/build_ios.yml/dispatches",
                                       {"ref": "dev", "inputs": {"installer_request_id": "request123"}})

    def test_dispatch_branch_race_does_not_download_other_commit(self):
        args = Mock(remote="origin", timeout=10)
        gh = Mock()
        gh.runs.side_effect = [[], [{"id": 2, "head_sha": "other", "display_title": "iOS installer request123"}]]
        outputs = ["", "dev", "abc", "abc refs/heads/dev", ""]
        with patch.object(cli, "command", side_effect=[Mock(stdout=s) for s in outputs]), \
                patch.object(cli.uuid, "uuid4", return_value=Mock(hex="request123")):
            with self.assertRaisesRegex(cli.InstallerError, "远端分支已变化"):
                cli.build(gh, args)


if __name__ == "__main__":
    unittest.main()
