"""Data files that survive a crash mid-write, editing a printer's address, and a desktop without a tray
(audit 2026-09-14: A07, A16, A17)."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from gantry.atomicfile import backup_path, read_text_with_backup, write_text_atomic
from gantry.physicalspool import PhysicalSpoolStore, location_for


def _is_json(text):
    json.loads(text)
    return True


class AtomicFileTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.path = self.folder / "spools.json"

    def test_the_previous_version_is_kept_and_no_temporary_file_is_left(self):
        write_text_atomic(self.path, '{"a": 1}')
        write_text_atomic(self.path, '{"a": 2}')
        self.assertEqual(self.path.read_text(), '{"a": 2}')
        self.assertEqual(backup_path(self.path).read_text(), '{"a": 1}')
        self.assertEqual([p.name for p in self.folder.iterdir() if p.name.endswith(".tmp")], [])

    def test_an_emptied_file_reads_back_the_last_good_copy_and_never_becomes_the_backup(self):
        write_text_atomic(self.path, '{"a": 1}')
        write_text_atomic(self.path, '{"a": 2}')
        self.path.write_text("")
        self.assertEqual(read_text_with_backup(self.path, _is_json), '{"a": 1}')
        write_text_atomic(self.path, '{"a": 3}', keep_backup_if=_is_json)
        self.assertEqual(backup_path(self.path).read_text(), '{"a": 1}')

    def test_a_file_cut_short_mid_json_never_becomes_the_backup(self):
        write_text_atomic(self.path, '{"a": 1}')
        write_text_atomic(self.path, '{"a": 2}')
        self.path.write_text('{"a": ')
        self.assertEqual(read_text_with_backup(self.path, _is_json), '{"a": 1}')
        write_text_atomic(self.path, '{"a": 3}', keep_backup_if=_is_json)
        self.assertEqual(backup_path(self.path).read_text(), '{"a": 1}')

    def test_a_failed_write_leaves_the_file_as_it_was(self):
        write_text_atomic(self.path, '{"a": 1}')
        with mock.patch("gantry.atomicfile.os.replace", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                write_text_atomic(self.path, '{"a": 2}')
        self.assertEqual(self.path.read_text(), '{"a": 1}')
        self.assertEqual([p.name for p in self.folder.iterdir() if p.name.endswith(".tmp")], [])

    def test_the_spool_store_survives_a_file_cut_short(self):
        store = PhysicalSpoolStore(self.folder / "spools.json", self.folder / "usage.json")
        store.spools.append({"id": "SP-1", "remainingWeightGrams": 1000, "location": location_for("X1", False, 0, 0)})
        store._save()
        store.spools[0]["remainingWeightGrams"] = 900
        store._save()
        (self.folder / "spools.json").write_text("")
        reopened = PhysicalSpoolStore(self.folder / "spools.json", self.folder / "usage.json")
        self.assertEqual([spool["id"] for spool in reopened.spools], ["SP-1"])


try:
    from gantry import app as gantry_app
    from gantry.core import Printer, PrinterKind, Telemetry
    from gantry.startup import StartupState
    from gantry.storage import SecretStoreError
except Exception as error:  # pragma: no cover - GTK bindings missing on this host
    gantry_app = None
    _GTK_MISSING = str(error)


@unittest.skipIf(gantry_app is None, "gantry.app needs the GTK bindings")
class PrinterAddressEditTests(unittest.TestCase):
    OLD, NEW = "prusa-10.0.0.7-80", "prusa-10.0.0.8-80"

    def _app(self, secret_write_fails=False):
        app = gantry_app.Gantry.__new__(gantry_app.Gantry)
        app.printers = [Printer(self.OLD, "MK4", "10.0.0.7", kind=PrinterKind.PRUSA)]
        app.telemetry = {self.OLD: Telemetry()}
        app.connections = {}
        app.startup = StartupState([self.OLD])
        app.deleted = []
        stored = {self.OLD: "api-key"}

        def set_secret(serial, value):
            if secret_write_fails:
                raise SecretStoreError("keyring refused")
            stored[serial] = value

        app.secrets = SimpleNamespace(get=lambda serial: stored.get(serial), set=set_secret,
                                      delete=lambda serial: (app.deleted.append(serial), stored.pop(serial, None)))
        app.stored_secrets = stored
        config = SimpleNamespace(data={"automations": {self.OLD: [{"id": "rule"}]},
                                       "menu_bar_progress_serials": [self.OLD]},
                                 save=lambda: None, printers=None)
        config.prune_progress_pins = lambda serials: config.data.__setitem__(
            "menu_bar_progress_serials", [s for s in config.data["menu_bar_progress_serials"] if s in serials])
        app.config = config
        app.physical_spools = SimpleNamespace(spools=[{"id": "SP-1", "location": location_for(self.OLD, False, 0, 0)}],
                                              _save=lambda: None)
        app.rebuild_cards = lambda: None
        app._refresh_progress_indicators = lambda: None
        return app

    def test_a_keyring_that_refuses_the_new_code_leaves_the_printer_and_its_code(self):
        app = self._app(secret_write_fails=True)
        updated = Printer(self.NEW, "MK4", "10.0.0.8", kind=PrinterKind.PRUSA)
        error = app.save_printer_edit(app.printers[0], updated, "")
        self.assertTrue(error)
        self.assertEqual([p.serial for p in app.printers], [self.OLD])
        self.assertEqual(app.deleted, [])
        self.assertEqual(app.stored_secrets[self.OLD], "api-key")

    def test_a_new_address_carries_the_code_automations_pin_and_rolls_over(self):
        app = self._app()
        updated = Printer(self.NEW, "MK4", "10.0.0.8", kind=PrinterKind.PRUSA)
        self.assertIsNone(app.save_printer_edit(app.printers[0], updated, ""))
        self.assertEqual([p.serial for p in app.printers], [self.NEW])
        self.assertEqual(app.stored_secrets.get(self.NEW), "api-key")
        self.assertEqual(app.config.data["automations"], {self.NEW: [{"id": "rule"}]})
        self.assertEqual(app.config.data["menu_bar_progress_serials"], [self.NEW])
        self.assertEqual(app.physical_spools.spools[0]["location"]["printerSerial"], self.NEW)


@unittest.skipIf(gantry_app is None, "gantry.app needs the GTK bindings")
class StartupWindowTests(unittest.TestCase):
    def test_without_a_tray_icon_the_window_opens_even_from_autostart(self):
        self.assertTrue(gantry_app.show_window_on_start(False, tray_mode=True, background=True))
        self.assertTrue(gantry_app.show_window_on_start(False, tray_mode=False, background=True))

    def test_with_a_tray_icon_autostart_stays_in_the_background(self):
        self.assertFalse(gantry_app.show_window_on_start(True, tray_mode=True, background=True))
        self.assertFalse(gantry_app.show_window_on_start(True, tray_mode=False, background=True))
        self.assertFalse(gantry_app.show_window_on_start(True, tray_mode=True, background=False))
        self.assertTrue(gantry_app.show_window_on_start(True, tray_mode=False, background=False))


if __name__ == "__main__":
    unittest.main()
