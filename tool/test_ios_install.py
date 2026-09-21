import hashlib
import io
import json
from contextlib import ExitStack, redirect_stderr
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
        self.assertEqual(path.name, "OViewer-Build iOS IPA #3.ipa")
        metadata = json.loads(path.with_suffix(".json").read_text())
        self.assertEqual(metadata["run_id"], 10)
        self.assertEqual(metadata["run_number"], 3)

    def test_reruns_and_multiple_artifacts_keep_distinct_names(self):
        first = cli.ipa_filename({"run_number": 3}, {"id": 20})
        rerun = cli.ipa_filename({"run_number": 3, "run_attempt": 2}, {"id": 21})
        multiple = cli.ipa_filename({"run_number": 3}, {"id": 22}, multiple_artifacts=True)
        self.assertEqual(len({first, rerun, multiple}), 3)
        self.assertIn("#3 (attempt 2)", rerun)
        self.assertIn("#3 (artifact 22)", multiple)

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

    def test_ipa_dialog_found_as_owned_child_without_duplicate(self):
        app, window, dialog = Mock(), Mock(), Mock(handle=123)
        dialog.window_text.return_value = "Choose IPA File"
        dialog.is_visible.return_value = True
        app.windows.return_value = []
        window.descendants.return_value = [dialog]
        self.assertEqual(windows.ipa_dialogs(app, window), [dialog])
        app.windows.return_value = [dialog]
        self.assertEqual(windows.ipa_dialogs(app, window), [dialog])

    def test_long_ipa_label_with_qt_ellipsis(self):
        name = "OViewer-run35649462792-attempt1-13a8f890-artifact10661578081.ipa"
        self.assertTrue(windows.matches_ipa_label("OViewer-run356\u200b49462792-atte…", name))
        self.assertFalse(windows.matches_ipa_label("OViewer-run35536639587-atte…", name))
        self.assertFalse(windows.matches_ipa_label("OViewer…", name))

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

    def run_auto(self, gh, run):
        with ExitStack() as stack:
            stack.enter_context(patch.object(windows, "connected_ipads", return_value=[{"udid": "1234567890abcdef1234"}]))
            stack.enter_context(patch.object(cli.sys, "argv", ["ios_install.py", "auto", "--output", str(self.root)]))
            stack.enter_context(patch.object(cli, "repository", return_value="test/repo"))
            stack.enter_context(patch.object(cli, "token", return_value="test-token"))
            stack.enter_context(patch.object(cli, "GitHub", return_value=gh))
            stack.enter_context(patch.object(cli, "build", return_value=run))
            install = stack.enter_context(patch.object(cli, "install", return_value=0))
            errors = stack.enter_context(redirect_stderr(io.StringIO()))
            return cli.entrypoint(), install, errors

    def test_auto_no_ipad_stops_before_any_git_or_github_access(self):
        for argv in (["auto"], ["auto", "--no-install"], []):
            with self.subTest(argv=argv), ExitStack() as stack:
                stack.enter_context(patch.object(cli.sys, "argv", ["ios_install.py", *argv]))
                stack.enter_context(patch.object(cli, "choose", return_value="auto"))
                stack.enter_context(patch.object(windows, "connected_ipads", return_value=[]))
                forbidden = [stack.enter_context(patch.object(cli, name)) for name in
                             ("command", "repository", "token", "GitHub", "build", "download", "install")]
                self.assertEqual(cli.entrypoint(), 2)
                for action in forbidden:
                    action.assert_not_called()

    def test_auto_device_detection_error_stops_before_github(self):
        with patch.object(cli.sys, "argv", ["ios_install.py", "auto"]), \
                patch.object(windows, "connected_ipads", side_effect=RuntimeError("PnP error")), \
                patch.object(cli, "repository") as repo, redirect_stderr(io.StringIO()):
            self.assertEqual(cli.entrypoint(), 1)
            repo.assert_not_called()

    def test_manual_download_without_ipad_uses_build_number(self):
        gh, run = self.fake_download()
        run.update(created_at="2026-09-22T00:00:00Z", head_branch="dev")
        gh.runs.return_value = [run]
        with ExitStack() as stack:
            stack.enter_context(patch.object(cli.sys, "argv", ["ios_install.py", "manual", "--no-install", "--output", str(self.root)]))
            stack.enter_context(patch.object(cli, "choose", return_value=run))
            stack.enter_context(patch.object(cli, "repository", return_value="test/repo"))
            stack.enter_context(patch.object(cli, "token", return_value="test-token"))
            stack.enter_context(patch.object(cli, "GitHub", return_value=gh))
            detect = stack.enter_context(patch.object(windows, "connected_ipads"))
            install = stack.enter_context(patch.object(cli, "install"))
            self.assertEqual(cli.entrypoint(), 0)
            detect.assert_not_called()
            install.assert_not_called()
            self.assertTrue((self.root / "OViewer-Build iOS IPA #3.ipa").is_file())

    def test_auto_unsuccessful_run_exits_without_download_or_install(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", "neutral", "action_required"):
            with self.subTest(conclusion=conclusion):
                gh, run = self.fake_download()
                run["conclusion"] = conclusion
                code, install, errors = self.run_auto(gh, run)
                self.assertEqual(code, 1)
                self.assertIn("终止进程", errors.getvalue())
                gh.artifacts.assert_not_called()
                gh.request.assert_not_called()
                install.assert_not_called()

    def test_auto_success_downloads_valid_ipa_before_install(self):
        gh, run = self.fake_download()
        code, install, _ = self.run_auto(gh, run)
        self.assertEqual(code, 0)
        install.assert_called_once()
        self.assertEqual(install.call_args.args[0].name, "OViewer-Build iOS IPA #3.ipa")
        self.assertEqual(install.call_args.args[1].udid, "1234567890abcdef1234")
        self.assertEqual(cli.ipa_info(install.call_args.args[0])["CFBundleIdentifier"], "org.test.viewer")

    def test_auto_success_without_ipa_exits_without_install(self):
        gh, run = self.fake_download()
        gh.artifacts.return_value = []
        code, install, _ = self.run_auto(gh, run)
        self.assertEqual(code, 1)
        gh.request.assert_not_called()
        install.assert_not_called()

    def test_auto_corrupt_ipa_exits_without_install(self):
        gh, run = self.fake_download("sha256:incorrect")
        code, install, _ = self.run_auto(gh, run)
        self.assertEqual(code, 1)
        install.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_failed_compile_exits_before_runner_cleanup_finishes(self):
        gh, run = self.fake_download()
        run.update(status="in_progress", conclusion=None)
        gh.api.return_value = {"jobs": [{"name": "build-ios", "conclusion": None,
                                         "steps": [{"name": "Build iOS", "conclusion": "failure"},
                                                   {"name": "Post Checkout", "conclusion": None}]}]}
        with patch.object(cli.time, "sleep") as sleep:
            with self.assertRaisesRegex(cli.InstallerError, "Build iOS"):
                cli.wait_run(gh, run, 60)
            sleep.assert_not_called()

    def test_running_build_continues_until_success(self):
        gh, completed = self.fake_download()
        running = {**completed, "status": "in_progress", "conclusion": None}
        gh.api.side_effect = [{"jobs": [{"name": "build-ios", "conclusion": None, "steps": []}]}, completed]
        with patch.object(cli.time, "sleep"):
            self.assertEqual(cli.wait_run(gh, running, 60), completed)

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
