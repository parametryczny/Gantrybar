import unittest
from datetime import timedelta

from gantry.core import PrinterState, Telemetry
from gantry.insights import PrinterInsights


class _Config:
    def __init__(self): self.data = {}
    def save(self): pass


class _Spools:
    usage = [{"printerSerial": "A", "consumedGrams": 12.5}]


class _App:
    def __init__(self):
        self.config = _Config()
        self.physical_spools = _Spools()


class InsightsTests(unittest.TestCase):
    def test_records_terminal_transition_and_statistics(self):
        store = PrinterInsights(_App())
        idle = Telemetry(state=PrinterState.IDLE)
        printing = Telemetry(state=PrinterState.PRINTING, job_name="cube.3mf", progress=10)
        store.observe("A", idle, printing)
        store._last_seen["A"] = store._now() - timedelta(seconds=30)
        progressed = Telemetry(state=PrinterState.PRINTING, job_name="cube.3mf", progress=80)
        store.observe("A", printing, progressed)
        finished = Telemetry(state=PrinterState.FINISHED, job_name="cube.3mf", progress=100)
        store.observe("A", progressed, finished)
        snapshot = store.snapshot("A", True)
        self.assertEqual(snapshot["completed"], 1)
        self.assertEqual(snapshot["success"], 100)
        self.assertGreater(snapshot["total_hours"], 0)
        self.assertEqual(snapshot["consumed_grams"], 12.5)

    def test_due_snooze_and_complete(self):
        store = PrinterInsights(_App())
        store.records["A"] = {"totalPrintSeconds": 101 * 3600, "history": [], "tasks": {}}
        self.assertEqual(store.signal("A", [])[0], "due")
        store.snooze("A", "clean-rods")
        self.assertEqual(store.signal("A", [])[0], "none")
        store.complete("A", "clean-rods")
        self.assertEqual(store.signal("A", [])[0], "none")
        self.assertEqual(store.signal("A", ["HMS"])[0], "urgent")

    def test_initial_stale_finished_state_is_not_a_new_history_entry(self):
        store = PrinterInsights(_App())
        store.observe("A", Telemetry(state=PrinterState.OFFLINE),
                      Telemetry(state=PrinterState.FINISHED, job_name="old.3mf", progress=100))
        self.assertEqual(store.snapshot("A", True)["history"], [])


if __name__ == "__main__":
    unittest.main()
