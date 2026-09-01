import unittest
from unittest.mock import patch

from gantry.updater import Release, download_deb, is_newer, version_tuple


class UpdaterTests(unittest.TestCase):
    def test_version_tuple_accepts_tag_prefix_and_suffix(self):
        self.assertEqual(version_tuple("v0.9.1-beta"), (0, 9, 1))

    def test_newer_version_comparison_zero_pads(self):
        self.assertTrue(is_newer("0.10", "0.9.9"))
        self.assertFalse(is_newer("0.9", "0.9.0"))
        self.assertFalse(is_newer("0.8.9", "0.9.0"))

    def test_download_rejects_non_debian_payload(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *_args): return None
            def read(self, _size):
                value, self.payload = self.payload, b""
                return value
            payload = b"not-a-deb"

        with patch("gantry.updater.urllib.request.urlopen", return_value=Response()):
            with self.assertRaisesRegex(ValueError, "invalid-deb"):
                download_deb(Release("1.0", "https://example.test", "https://example.test/a.deb"))


if __name__ == "__main__":
    unittest.main()
