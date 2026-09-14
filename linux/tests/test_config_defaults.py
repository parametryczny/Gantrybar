"""Each Config owns its nested defaults (audit 2026-09-14: A20)."""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gantry import storage


class ConfigDefaultsTests(unittest.TestCase):
    def test_nested_defaults_are_not_shared_between_configs(self):
        folder = Path(tempfile.mkdtemp())
        with mock.patch.object(storage, "CONFIG_FILE", folder / "config.json"), \
                mock.patch.object(storage, "APP_DIR", folder), \
                mock.patch.object(storage, "_migrate_legacy_config", lambda: None):
            first, second = storage.Config(), storage.Config()
        nested = [key for key, value in storage.DEFAULTS.items() if isinstance(value, (dict, list))]
        self.assertTrue(nested)
        for key in nested:
            with self.subTest(key=key):
                self.assertIsNot(first.data[key], second.data[key])
                self.assertIsNot(first.data[key], storage.DEFAULTS[key])
        first.data["automations"]["X1"] = [{"id": "rule"}]
        self.assertEqual(second.data["automations"], {})
        self.assertEqual(storage.DEFAULTS["automations"], {})


if __name__ == "__main__":
    unittest.main()
