"""Regression cases from the follow-up audit; all files and faults are isolated."""
import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from gantry import physicalspool as ps, consumption as c
from gantry.core import Printer, PrinterKind, PrinterState as S, Telemetry, FilamentGroup, FilamentSlot

class SpoolTransactionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.reopen()
        self.a, self.b = self.store.create_rolls("PLA", 2, 1000)
    def reopen(self):
        return ps.PhysicalSpoolStore(self.root / "spools.json", self.root / "usage.json")
    def test_replay_after_swap_does_not_charge_another_roll(self):
        loc = ps.location_for("K", False, 0, 0)
        self.store.assign(self.a["id"], loc)
        group = FilamentGroup("ams", "ams", "AMS", 1, slots=[FilamentSlot("0", "A1", "PLA", "000000", active=True)])
        app = SimpleNamespace(printers=[Printer("K", "K", "localhost", kind=PrinterKind.KLIPPER)],
            physical_spools=self.store, config=SimpleNamespace(data={}, save=lambda: None), _spoolbase_active=lambda: True)
        running = Telemetry(state=S.PRINTING, job_name="cube")
        done = Telemetry(state=S.FINISHED, job_name="cube", filament_used_mm=1000, filament_groups=[group])
        c.on_finish(app, "K", Telemetry(state=S.IDLE), running)
        c.on_finish(app, "K", running, done)
        self.store.assign(self.b["id"], loc)
        app.physical_spools = self.reopen()
        c.on_finish(app, "K", Telemetry(state=S.OFFLINE), done)
        self.assertEqual(app.physical_spools.spool(self.b["id"])["remainingWeightGrams"], 1000)
        self.assertEqual(len(app.physical_spools.usage), 1)
    def test_failed_commit_rolls_back_memory_disk_and_allows_one_retry(self):
        with patch.object(ps, "write_text_atomic", side_effect=OSError("simulated disk full")):
            self.assertFalse(self.store.consume(self.a["id"], 10, "K", "job"))
        self.assertIsNotNone(self.store.last_error)
        self.assertEqual(self.store.spool(self.a["id"])["remainingWeightGrams"], 1000)
        restored = self.reopen()
        self.assertEqual(restored.usage, [])
        self.assertTrue(restored.consume(self.a["id"], 10, "K", "job"))
        self.assertFalse(restored.consume(self.b["id"], 10, "K", "job"))
        self.assertEqual(self.reopen().spool(self.a["id"])["remainingWeightGrams"], 990)
    def test_legacy_files_migrate_together_without_being_overwritten(self):
        root = self.root / "legacy"; root.mkdir()
        spools = root / "spools.json"; usage = root / "usage.json"
        spools.write_text(json.dumps([self.a])); usage.write_text("[]")
        before = spools.read_bytes()
        store = ps.PhysicalSpoolStore(spools, usage)
        self.assertTrue(store.consume(self.a["id"], 10, "K", "job"))
        self.assertEqual(spools.read_bytes(), before)
        reopened = ps.PhysicalSpoolStore(spools, usage)
        self.assertEqual(reopened.spool(self.a["id"])["remainingWeightGrams"], 990)
        self.assertEqual(len(reopened.usage), 1)
    def test_warnings_survive_restart_and_can_be_reviewed(self):
        self.store.warn_accounting("K|job", "cube")
        reopened = self.reopen(); self.assertEqual(reopened.warnings, {"K|job": "cube"})
        reopened.clear_accounting_warnings(); self.assertEqual(self.reopen().warnings, {})
        self.assertFalse(self.reopen().consume(self.a["id"], 10, "K", "K|job#1"))
        self.reopen().warn_accounting("K|job", "cube")
        self.assertEqual(self.reopen().warnings, {})
    def test_two_transfer_callbacks_cannot_charge_same_operation_twice(self):
        threads = [threading.Thread(target=self.store.consume, args=(self.a["id"], 10, "K", "job")) for _ in range(2)]
        for t in threads: t.start()
        for t in threads: t.join()
        self.assertEqual(self.reopen().spool(self.a["id"])["remainingWeightGrams"], 990)
    def test_finish_while_disabled_remains_skipped_after_restart(self):
        sessions = {}
        c.observe_session(sessions, "K", S.IDLE, S.PRINTING, "cube", 100)
        self.assertIsNone(c.observe_session(sessions, "K", S.PRINTING, S.FINISHED, "cube", 200, False)[0])
        restored = json.loads(json.dumps(sessions))
        self.assertIsNone(c.observe_session(restored, "K", S.OFFLINE, S.FINISHED, "cube", 900, True)[0])
    def test_corrupt_v2_does_not_resurrect_obsolete_legacy_data(self):
        self.store._state_path.write_text("broken")
        self.store._state_path.with_name(self.store._state_path.name + ".bak").write_text("broken")
        reopened = self.reopen()
        self.assertIsNotNone(reopened.last_error)
        self.assertFalse(reopened._save())
        self.assertEqual(reopened._state_path.read_text(), "broken")
