import io
import unittest
import urllib.request
from unittest.mock import Mock

from scripts.versioning.github import GitHub, SafeRedirect
from scripts.versioning.rules import VersionError


class DownloadTests(unittest.TestCase):
    def test_artifact_download_negotiates_json_but_returns_raw_bytes(self):
        api = GitHub("owner/repo", "test-token")
        api.opener = Mock()
        api.opener.open.return_value = io.BytesIO(b"raw-artifact")
        self.assertEqual(api.request("/actions/artifacts/123/zip", binary=True), b"raw-artifact")
        request = api.opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Accept"), "application/vnd.github+json")

    def test_release_asset_requires_octet_stream(self):
        api = GitHub("owner/repo", "test-token")
        api.opener = Mock()
        api.opener.open.return_value = io.BytesIO(b"raw-asset")
        self.assertEqual(api.request("/releases/assets/123", binary=True), b"raw-asset")
        self.assertEqual(api.opener.open.call_args.args[0].get_header("Accept"), "application/octet-stream")

    def test_storage_redirect_never_receives_github_credential(self):
        request = urllib.request.Request("https://api.github.com/download", headers={"Authorization": "Bearer test-token"})
        redirected = SafeRedirect().redirect_request(request, None, 302, "Found", {}, "https://storage.example.invalid/file")
        self.assertFalse(redirected.has_header("Authorization"))
        with self.assertRaises(VersionError):
            SafeRedirect().redirect_request(request, None, 302, "Found", {}, "http://storage.example.invalid/file")


if __name__ == "__main__":
    unittest.main()
