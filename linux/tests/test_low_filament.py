"""Which rolls count as running low, and the alerts built on it (reported 2026-09-18: no low-filament
alerts at all with rolls that are not Bambu's tagged ones). Same cases as LowFilamentTests.swift."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gantry import lowfilament, storage
from gantry.core import FilamentGroup, FilamentSlot, PrinterState, Telemetry


def slot(label, material="PLA", percent=None, tag_grams=None, active=False):
    return FilamentSlot(label, label, material, "FFFFFFFF", percent, active, tag_grams)


def group(*slots, external=False):
    return FilamentGroup("0", "external" if external else "ams", "AMS", len(slots), external=external,
                         slots=list(slots))


def roll(grams):
    return {"id": "SP-00007", "remainingWeightGrams": grams}


class LowSlotTests(unittest.TestCase):
    def test_a_tagged_roll_at_fifteen_percent_is_low_and_at_sixteen_is_not(self):
        low = lowfilament.low_slots("X1", [group(slot("A1", percent=15, tag_grams=150),
                                                 slot("A2", percent=16, tag_grams=160))], lambda _l: None)
        self.assertEqual(low, [lowfilament.LowSlot("0-0", "A1", "PLA", "15%")])

    def test_a_chipless_roll_without_spoolbase_is_never_low(self):
        self.assertEqual(lowfilament.low_slots("X1", [group(slot("A1", percent=0))], lambda _l: None), [])

    def test_a_spoolbase_roll_warns_by_its_grams_even_without_a_tag(self):
        low = lowfilament.low_slots("X1", [group(slot("A1", percent=0), slot("A2", percent=0))],
                                    lambda location: roll(85.4) if location["slot"] == 0 else roll(101))
        self.assertEqual(low, [lowfilament.LowSlot("0-0", "A1", "PLA", "85 g")])

    def test_spoolbase_outranks_a_full_looking_tag(self):
        low = lowfilament.low_slots("X1", [group(slot("A1", percent=90, tag_grams=900))], lambda _l: roll(40))
        self.assertEqual([item.amount for item in low], ["40 g"])

    def test_the_slot_that_was_feeding_is_named_even_after_the_pause_cleared_it(self):
        before = [group(slot("A1"), slot("A3", active=True))]
        after = [group(slot("A1"), slot("A3"))]
        self.assertEqual(lowfilament.feeding_slot(before, after).label, "A3")
        self.assertIsNone(lowfilament.feeding_slot(None, after))


class AlertTests(unittest.TestCase):
    """The alerts themselves, through the kiosk, which shares the regular app's telemetry handler."""

    @classmethod
    def setUpClass(cls):
        try:
            from gantry import kiosk
            from gi.repository import Gtk
        except Exception as error:  # pragma: no cover - GTK bindings missing on this host
            raise unittest.SkipTest(f"needs the GTK bindings: {error}")
        if not Gtk.init_check()[0]:  # pragma: no cover - no display
            raise unittest.SkipTest("no display")
        cls.kiosk = kiosk

    def setUp(self):
        folder = Path(tempfile.mkdtemp())
        config = folder / "config.json"
        config.write_text(json.dumps({"printers": [{"serial": "S0", "name": "H2D", "host": "127.0.0.1",
                                                    "port": 8883, "kind": "bambu", "model": "Bambu Lab"}]}),
                          encoding="utf-8")
        for patch in (mock.patch.object(storage, "CONFIG_FILE", config),
                      mock.patch.object(storage, "APP_DIR", folder),
                      mock.patch.object(storage, "_migrate_legacy_config", lambda: None),
                      mock.patch.object(self.kiosk.KioskGantry, "reconnect_all", lambda _self: None),
                      mock.patch.object(self.kiosk.WebConfigServer, "start", lambda _self: None),
                      mock.patch("gantry.telegram.notify")):
            patch.start()
            self.addCleanup(patch.stop)
        self.app = self.kiosk.KioskGantry()
        self.addCleanup(self.app.window.destroy)
        self.app.notify = mock.Mock()
        self.app.physical_spools = None

    def report(self, **fields):
        self.app.on_event("S0", "telemetry", Telemetry(**fields))

    def bodies(self):
        return [call.args[1] for call in self.app.notify.call_args_list]

    def test_a_low_roll_warns_once_and_again_only_after_a_refill(self):
        low = [group(slot("A1", percent=12, tag_grams=120))]
        full = [group(slot("A1", percent=100, tag_grams=1000))]
        self.report(state=PrinterState.PRINTING, filament_groups=low)
        self.report(state=PrinterState.PRINTING, filament_groups=low)
        self.report(state=PrinterState.OFFLINE)
        self.report(state=PrinterState.PRINTING, filament_groups=low)
        self.assertEqual(sum("A1 • PLA • 12%" in body for body in self.bodies()), 1)
        self.report(state=PrinterState.IDLE, filament_groups=full)
        self.report(state=PrinterState.PRINTING, filament_groups=low)
        self.assertEqual(sum("A1 • PLA • 12%" in body for body in self.bodies()), 2)

    def test_a_runout_pause_names_the_roll_instead_of_a_plain_pause(self):
        self.report(state=PrinterState.PRINTING, stage=0, filament_groups=[group(slot("A3", active=True))])
        self.report(state=PrinterState.PAUSED, stage=lowfilament.RUNOUT_STAGE, filament_groups=[group(slot("A3"))])
        bodies = self.bodies()
        self.assertEqual(len(bodies), 1, bodies)
        self.assertIn("A3 • PLA", bodies[0])


if __name__ == "__main__":
    unittest.main()
