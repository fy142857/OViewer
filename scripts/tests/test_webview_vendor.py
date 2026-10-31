from pathlib import Path
import shutil
import tempfile
import unittest

from scripts.verify_webview_vendor import VENDOR, digest, verify, verify_resolution


class VendorTests(unittest.TestCase):
    def test_repository_files(self):
        self.assertEqual(verify(), 270)

    def test_text_line_endings_and_binary(self):
        self.assertEqual(digest(b'text\r\n'), digest(b'text\n'))
        self.assertNotEqual(digest(b'\0\r\n'), digest(b'\0\n'))

    def test_detect_modified_dart_android_and_missing_assets(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'plugin'
            shutil.copytree(VENDOR, root)
            for relative in ('lib/flutter_inappwebview.dart', 'android/build.gradle', 'lib/assets/t_rex_runner/t-rex.html'):
                path = root / relative
                original = path.read_bytes()
                path.write_bytes(original + b'\n// unauthorized change\n')
                with self.assertRaisesRegex(ValueError, 'content mismatch'):
                    verify(root)
                path.unlink()
                with self.assertRaisesRegex(ValueError, 'inventory mismatch'):
                    verify(root)
                path.write_bytes(original)

    def test_resolution_rejects_pub_cache(self):
        import json
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / '.dart_tool/package_config.json'
            config.parent.mkdir()
            for location, valid in (('../third_party/flutter_inappwebview', True), ('file:///pub/cache/plugin', False)):
                config.write_text(json.dumps({'packages': [{'name': 'flutter_inappwebview', 'rootUri': location}]}))
                if valid:
                    verify_resolution(root)
                else:
                    with self.assertRaises(ValueError):
                        verify_resolution(root)


if __name__ == '__main__':
    unittest.main()
