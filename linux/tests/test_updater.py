import unittest
from unittest.mock import patch

from gantry.updater import Release, download_deb, is_newer, latest_release, select_package_format, version_tuple


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

    def test_explicit_linux_package_selection(self):
        release = Release("1.0", "https://example.test", "d.deb", None,
                          "r.rpm", None, "a.AppImage", None)
        self.assertEqual(select_package_format(release, "deb"), "deb")
        self.assertEqual(select_package_format(release, "rpm"), "rpm")
        self.assertEqual(select_package_format(release, "appimage"), "appimage")

    def test_missing_requested_format_falls_back_to_available_package(self):
        release = Release("1.0", "https://example.test", rpm_url="r.rpm")
        self.assertEqual(select_package_format(release, "deb"), "rpm")

    def test_release_discovers_all_linux_artifacts(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *_args): return None
            def read(self):
                return b'{"tag_name":"v1.2.3","html_url":"https://example.test/release","assets":[' \
                       b'{"name":"Gantry.deb","browser_download_url":"https://example.test/g.deb","digest":"sha256:aa"},' \
                       b'{"name":"Gantry.rpm","browser_download_url":"https://example.test/g.rpm","digest":"sha256:bb"},' \
                       b'{"name":"Gantry-x86_64.AppImage","browser_download_url":"https://example.test/g.AppImage","digest":"sha256:cc"}]}'
        with patch("gantry.updater.urllib.request.urlopen", return_value=Response()):
            release = latest_release()
        self.assertEqual(release.deb_sha256, "aa")
        self.assertEqual(release.rpm_sha256, "bb")
        self.assertEqual(release.appimage_sha256, "cc")


if __name__ == "__main__":
    unittest.main()
