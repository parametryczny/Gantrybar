"""Gantry Workshop with real printers on the wall (reported 2026-09-18: the kiosk crashed as soon as it
had a printer, and the full-screen picture jumped).

The kiosk starts from the same state as the regular app, updates its tiles in place instead of tearing
the wall down, never writes its dark theme into the shared settings, and a maximised regular window is
no longer resized to fit its cards.
"""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gantry import storage
from gantry.core import Printer, PrinterKind, PrinterState, Telemetry


def _printers(count):
    return [{"serial": f"S{index}", "name": f"Drukarka {index}", "host": "127.0.0.1", "port": 8883,
             "kind": "bambu", "model": "Bambu Lab"} for index in range(count)]


class KioskRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from gantry import kiosk
            from gi.repository import Gtk
        except Exception as error:  # pragma: no cover - GTK bindings missing on this host
            raise unittest.SkipTest(f"gantry.kiosk needs the GTK bindings: {error}")
        if not Gtk.init_check()[0]:  # pragma: no cover - no display
            raise unittest.SkipTest("no display")
        cls.kiosk = kiosk

    def setUp(self):
        folder = Path(tempfile.mkdtemp())
        self.config_file = folder / "config.json"
        self.config_file.write_text(json.dumps({"theme": "light", "printers": _printers(4)}), encoding="utf-8")
        for patch in (mock.patch.object(storage, "CONFIG_FILE", self.config_file),
                      mock.patch.object(storage, "APP_DIR", folder),
                      mock.patch.object(storage, "_migrate_legacy_config", lambda: None),
                      mock.patch.object(self.kiosk.KioskGantry, "reconnect_all", lambda _self: None),
                      mock.patch.object(self.kiosk.WebConfigServer, "start", lambda _self: None)):
            patch.start()
            self.addCleanup(patch.stop)
        self.app = self.kiosk.KioskGantry()
        self.addCleanup(self.app.window.destroy)

    def test_starts_with_printers_and_takes_every_kind_of_report(self):
        self.assertEqual(len(self.app.cards), 4)
        self.app.on_event("S0", "telemetry", Telemetry(state=PrinterState.PRINTING, progress=40))
        self.app.on_event("S1", "disconnected", "timeout")
        self.app.on_event("S2", "telemetry", Telemetry(state=PrinterState.ERROR, error_code=1))
        self.app.on_event("S0", "telemetry", Telemetry(state=PrinterState.FINISHED, progress=100))
        self.assertEqual(self.app.telemetry["S0"].state, PrinterState.FINISHED)

    def test_reports_update_the_tiles_in_place(self):
        before = dict(self.app.cards)
        for serial in ("S0", "S1", "S2", "S3"):
            self.app.on_event(serial, "telemetry", Telemetry(state=PrinterState.IDLE))
        self.app.on_event("S0", "telemetry", Telemetry(state=PrinterState.PRINTING, progress=5))
        self.app.on_event("S1", "telemetry", Telemetry(state=PrinterState.ERROR, error_code=1))
        for serial, card in before.items():
            self.assertIs(self.app.cards[serial], card, serial)

    def test_error_banner_sits_in_the_header_not_above_the_tiles(self):
        self.assertIsNot(self.app.window.alert.get_parent(), self.app.window.grid.get_parent())
        self.assertIs(self.app.window.alert.get_parent(), self.app.window.summary.get_parent())

    def test_dark_kiosk_leaves_the_regular_apps_theme_alone(self):
        self.app.upsert_printer(Printer(serial="S9", name="Nowa", host="127.0.0.2", port=8883,
                                        kind=PrinterKind.BAMBU, model="Bambu Lab"))
        saved = json.loads(self.config_file.read_text(encoding="utf-8"))
        self.assertEqual(saved.get("theme"), "light")


class MaximisedWindowTests(unittest.TestCase):
    def test_a_window_that_fills_the_screen_is_not_fitted_to_its_cards(self):
        try:
            from gantry.dashboard import Dashboard
        except Exception as error:  # pragma: no cover - GTK bindings missing on this host
            raise unittest.SkipTest(f"gantry.dashboard needs the GTK bindings: {error}")
        window = mock.Mock(spec=["_panel_layer", "tray_mode", "fills_screen", "resize", "set_default_size"])
        window._panel_layer, window.tray_mode = None, False
        window.fills_screen.return_value = True
        Dashboard.resize_for_content(window)
        window.resize.assert_not_called()
        window.set_default_size.assert_not_called()


if __name__ == "__main__":
    unittest.main()
