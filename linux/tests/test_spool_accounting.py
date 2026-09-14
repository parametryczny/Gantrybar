"""Spool accounting: which print a finish belongs to, which slot it came from, and which roll pays for it
(audit 2026-09-14: A03, A04, A05)."""
import json
import unittest
from types import SimpleNamespace
from unittest import mock

from gantry import consumption
from gantry.consumption import _SESSIONS_KEY, bambu_charges, loaded_slot, observe_session, on_finish
from gantry.core import FilamentGroup, FilamentSlot, Printer, PrinterKind, PrinterState, Telemetry

IDLE, PRINTING, PAUSED = PrinterState.IDLE, PrinterState.PRINTING, PrinterState.PAUSED
FINISHED, OFFLINE = PrinterState.FINISHED, PrinterState.OFFLINE
T0 = 1_800_000_000


def _slot(label, material="PLA", color="FFFFFF", active=False):
    return FilamentSlot(slot_id=label, label=label, material=material, color=color, active=active)


def _group(slots):
    return FilamentGroup(group_id="ams", source_type="ams", display_name="AMS", declared_capacity=len(slots),
                         external=False, slots=slots)


class PrintSessionTests(unittest.TestCase):
    def test_two_prints_of_one_file_within_an_hour_are_two_jobs(self):
        sessions = {}
        observe_session(sessions, "X1", IDLE, PRINTING, "cube", T0)
        first, _ = observe_session(sessions, "X1", PRINTING, FINISHED, "cube", T0 + 600)
        observe_session(sessions, "X1", FINISHED, PRINTING, "cube", T0 + 900)
        second, _ = observe_session(sessions, "X1", PRINTING, FINISHED, "cube", T0 + 1500)
        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        self.assertNotEqual(first, second)

    def test_a_finish_seen_again_after_a_restart_days_later_keeps_its_id(self):
        sessions = {}
        observe_session(sessions, "X1", IDLE, PRINTING, "cube", T0)
        first, _ = observe_session(sessions, "X1", PRINTING, FINISHED, "cube", T0 + 600)
        restored = json.loads(json.dumps(sessions))
        again, changed = observe_session(restored, "X1", OFFLINE, FINISHED, "cube", T0 + 3 * 86400)
        self.assertEqual(again, first)
        self.assertFalse(changed)

    def test_pauses_reconnects_and_repeated_packets_keep_one_session(self):
        sessions = {}
        observe_session(sessions, "X1", IDLE, PRINTING, "cube", T0)
        observe_session(sessions, "X1", PRINTING, PAUSED, "cube", T0 + 300)
        observe_session(sessions, "X1", PAUSED, OFFLINE, "cube", T0 + 360)
        observe_session(sessions, "X1", OFFLINE, PRINTING, "cube", T0 + 420)
        job, _ = observe_session(sessions, "X1", PRINTING, FINISHED, "cube", T0 + 1800)
        self.assertEqual(job, f"X1|cube|{T0}")
        self.assertEqual(observe_session(sessions, "X1", FINISHED, FINISHED, "cube", T0 + 1860), (None, False))


class SlotChoiceTests(unittest.TestCase):
    def test_the_active_slot_wins_even_in_a_second_unit(self):
        groups = [_group([_slot("A1")]), _group([_slot("B1", active=True)])]
        location, _ = loaded_slot("K1", groups, lambda loc: True)
        self.assertEqual((location["amsIndex"], location["slot"]), (1, 0))

    def test_two_loaded_rolls_with_nothing_active_are_not_guessed(self):
        self.assertIsNone(loaded_slot("K1", [_group([_slot("A1"), _slot("A2")])], lambda loc: True))

    def test_a_lone_loaded_roll_is_used(self):
        location, _ = loaded_slot("K1", [_group([_slot("A1"), _slot("A2", material=None)])], lambda loc: True)
        self.assertEqual(location["slot"], 0)


class BambuRollSnapshotTests(unittest.TestCase):
    def test_charges_the_roll_assigned_when_the_print_finished(self):
        groups = [_group([_slot("A1", color="E89CC6FF"), _slot("A2", color="111111FF")])]
        charges = bambu_charges("X1", groups, [{"id": 1, "used_g": 9.8, "color": "E89CC6"}], {(0, 0): "SP-OLD"})
        self.assertEqual(charges, [("SP-OLD", 9.8, 1)])

    def test_switching_spoolbase_off_during_the_download_accounts_nothing(self):
        store = mock.Mock()
        telemetry = Telemetry(state=FINISHED, job_name="cube")
        telemetry.gcode_file = "cube.gcode.3mf"
        telemetry.filament_groups = [_group([_slot("A1", color="E89CC6")])]
        with mock.patch.object(consumption, "fetch_bambu_3mf", return_value=b"zip"), \
                mock.patch.object(consumption, "parse_3mf_filaments",
                                  return_value=[{"id": 1, "used_g": 5.0, "color": "E89CC6"}]):
            consumption._consume_bambu(store, "X1", "host", "code", telemetry, "job", {(0, 0): "SP-1"},
                                       still_enabled=lambda: False)
            store.consume.assert_not_called()
            consumption._consume_bambu(store, "X1", "host", "code", telemetry, "job", {(0, 0): "SP-1"},
                                       still_enabled=lambda: True)
        store.consume.assert_called_once_with("SP-1", 5.0, "X1", "job#1")


class OnFinishTests(unittest.TestCase):
    @staticmethod
    def _app(spoolbase=True):
        saves = []
        app = SimpleNamespace(printers=[Printer("K1", "Voron", "10.0.0.7", kind=PrinterKind.KLIPPER)],
                              config=SimpleNamespace(data={}, save=lambda: saves.append(1)),
                              _spoolbase_active=lambda: spoolbase, physical_spools=object())
        return app, saves

    def test_sessions_are_followed_and_saved_with_spoolbase_off(self):
        app, saves = self._app(spoolbase=False)
        with mock.patch.object(consumption, "_consume_klipper") as consume:
            on_finish(app, "K1", Telemetry(state=IDLE), Telemetry(state=PRINTING, job_name="cube"))
            on_finish(app, "K1", Telemetry(state=PRINTING, job_name="cube"), Telemetry(state=FINISHED, job_name="cube"))
        consume.assert_not_called()
        self.assertTrue(app.config.data[_SESSIONS_KEY]["K1"]["finished"])
        self.assertTrue(saves)

    def test_a_klipper_finish_is_charged_once_with_its_session_id(self):
        app, _ = self._app()
        with mock.patch.object(consumption, "_consume_klipper") as consume:
            on_finish(app, "K1", Telemetry(state=IDLE), Telemetry(state=PRINTING, job_name="cube"))
            on_finish(app, "K1", Telemetry(state=PRINTING, job_name="cube"), Telemetry(state=FINISHED, job_name="cube"))
            on_finish(app, "K1", Telemetry(state=FINISHED, job_name="cube"), Telemetry(state=FINISHED, job_name="cube"))
        consume.assert_called_once()
        self.assertEqual(consume.call_args.args[3], app.config.data[_SESSIONS_KEY]["K1"]["id"])


if __name__ == "__main__":
    unittest.main()
