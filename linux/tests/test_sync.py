import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gantry.physicalspool import PhysicalSpoolStore, same_slot, location_for
from gantry.sync import make_token, normalize_address
from gantry.webserver import fleet_snapshot
from gantry.core import Printer, PrinterKind, Telemetry, FilamentGroup, FilamentSlot, PrinterState, parse_telemetry


def _store():
    d = Path(tempfile.mkdtemp())
    return PhysicalSpoolStore(d / "spools.json", d / "usage.json")


class PhysicalSpoolMergeTests(unittest.TestCase):
    def test_last_write_wins_and_usage_dedup(self):
        st = _store()
        spool = {"id": "SP-00001", "nominalWeightGrams": 1000, "remainingWeightGrams": 850,
                 "status": "active", "location": {}, "updatedAt": "2026-08-27T10:00:00Z"}
        event = {"id": "e1", "spoolID": "SP-00001", "printJobID": "job#1", "consumedGrams": 50,
                 "timestamp": "2026-08-27T10:00:00Z"}
        self.assertTrue(st.merge_remote([spool], [event]))
        self.assertEqual(st.spool("SP-00001")["remainingWeightGrams"], 850)
        # An older copy is ignored; a newer one wins.
        older = dict(spool, remainingWeightGrams=700, updatedAt="2026-08-26T10:00:00Z")
        self.assertFalse(st.merge_remote([older], []))
        newer = dict(spool, remainingWeightGrams=600, updatedAt="2026-08-28T10:00:00Z")
        self.assertTrue(st.merge_remote([newer], []))
        self.assertEqual(st.spool("SP-00001")["remainingWeightGrams"], 600)
        # The same usage event does not duplicate.
        self.assertFalse(st.merge_remote([], [event]))
        self.assertEqual(len(st.usage), 1)

    def test_create_assign_and_set_remaining(self):
        st = _store()
        loc = location_for("X1", False, 0, 0)
        spool = st.create_spool("def-1", 1000, 1000, loc)
        self.assertEqual(spool["id"], "SP-00001")
        self.assertIs(st.spool_at(loc), spool)
        self.assertEqual(spool["status"], "active")
        # A second roll into the same slot bumps the first back to storage.
        second = st.create_spool(None, 500, 500, loc)
        self.assertIs(st.spool_at(loc), second)
        self.assertEqual(spool["location"], {})
        self.assertEqual(spool["status"], "stored")
        # Manual grams edit clamps to nominal.
        st.set_remaining(second["id"], 9999)
        self.assertEqual(second["remainingWeightGrams"], 500)
        st.set_remaining(second["id"], 0)
        self.assertEqual(second["status"], "empty")

    def test_create_rolls_correct_reset_and_delete(self):
        st = _store()
        changes = []
        st.on_change = lambda: changes.append(True)
        rolls = st.create_rolls("def-1", 2, 1000)
        self.assertEqual([roll["id"] for roll in rolls], ["SP-00001", "SP-00002"])
        self.assertEqual(rolls[0]["status"], "new")
        self.assertEqual(rolls[0]["location"], {})
        st.correct_weight(rolls[0]["id"], 700, 235)
        self.assertEqual(rolls[0]["remainingWeightGrams"], 700)
        self.assertEqual(rolls[0]["tareGrams"], 235)
        st.reset_to_full(rolls[0]["id"])
        self.assertEqual(rolls[0]["remainingWeightGrams"], 1000)
        self.assertEqual(rolls[0]["status"], "new")
        st.delete(rolls[1]["id"])
        self.assertIsNone(st.spool(rolls[1]["id"]))
        self.assertGreaterEqual(len(changes), 4)

    def test_percent_and_slot_match(self):
        st = _store()
        self.assertEqual(st.percent({"nominalWeightGrams": 1000, "remainingWeightGrams": 250}), 25)
        loc = location_for("X1", False, 0, 2)
        self.assertTrue(same_slot(loc, location_for("X1", False, 0, 2)))
        self.assertFalse(same_slot(loc, location_for("X1", False, 0, 3)))
        self.assertFalse(same_slot(loc, {}))


class SyncHelperTests(unittest.TestCase):
    def test_token_and_normalize(self):
        self.assertTrue(make_token().startswith("GANTRY-"))
        self.assertEqual(normalize_address("http://gantry.local/"), "gantry.local:8787")
        self.assertEqual(normalize_address("192.168.1.9"), "192.168.1.9:8787")
        self.assertEqual(normalize_address("host:9000"), "host:9000")
        self.assertEqual(normalize_address(""), "")

    def test_wire_date_strips_fractional(self):
        from gantry.sync import _wire_date
        self.assertEqual(_wire_date("2026-08-29T12:34:56.123456+00:00"), "2026-08-29T12:34:56Z")
        self.assertEqual(_wire_date("2026-08-29T12:34:56Z"), "2026-08-29T12:34:56Z")


try:
    import gi  # noqa: F401
    _HAS_GI = True
except Exception:
    _HAS_GI = False


class CatalogMergeTests(unittest.TestCase):
    def test_last_write_wins_by_id(self):
        from gantry.filamentstore import FilamentStore
        store = FilamentStore(Path(tempfile.mkdtemp()) / "inventory.json")
        base = {"id": "F1", "brand": "Bambu", "name": "Matte", "type": "PLA",
                "colorName": "Pink", "colorHex": "E89CC6", "spoolCount": 2,
                "updatedAt": "2026-08-27T10:00:00Z"}
        self.assertTrue(store.merge_remote([base]))
        self.assertEqual(store.filaments[0].spoolCount, 2)
        older = dict(base, spoolCount=9, updatedAt="2026-08-26T10:00:00Z")
        self.assertFalse(store.merge_remote([older]))
        self.assertEqual(store.filaments[0].spoolCount, 2)
        newer = dict(base, spoolCount=5, updatedAt="2026-08-28T10:00:00.500000+00:00")
        self.assertTrue(store.merge_remote([newer]))
        self.assertEqual(store.filaments[0].spoolCount, 5)


class WebFleetTests(unittest.TestCase):
    def test_fleet_snapshot_shape(self):
        printer = Printer("X1", "X1", "192.168.1.9", model="Bambu Lab", port=8883, kind=PrinterKind.BAMBU)
        tel = Telemetry(state=PrinterState.PRINTING, progress=42, job_name="vase.3mf", nozzle=210.0, bed=60.0)
        tel.filament_groups = [FilamentGroup(
            group_id="ams-0", source_type="ams", display_name="AMS A", declared_capacity=4, external=False,
            slots=[FilamentSlot(slot_id="a1", label="A1", material="PLA", color="E89CC6FF",
                                remaining=85, active=True, remaining_weight_g=850.0)])]
        snap = fleet_snapshot([printer], {"X1": tel})
        self.assertEqual(len(snap["printers"]), 1)
        card = snap["printers"][0]
        self.assertEqual(card["state"], "printing")
        self.assertEqual(card["job"], "vase.3mf")           # shown while printing
        self.assertEqual(card["groups"][0]["slots"][0]["grams"], 850)
        self.assertEqual(card["groups"][0]["slots"][0]["colorHex"], "E89CC6")

    def test_job_hidden_when_not_printing(self):
        printer = Printer("X1", "X1", "192.168.1.9", model="Bambu Lab", port=8883, kind=PrinterKind.BAMBU)
        tel = Telemetry(state=PrinterState.FINISHED, progress=100, job_name="vase.3mf")
        snap = fleet_snapshot([printer], {"X1": tel})
        self.assertEqual(snap["printers"][0]["job"], "")


class CameraSplitTests(unittest.TestCase):
    def test_split_jpegs(self):
        from gantry.jpegstream import split_jpegs
        f1 = b"\xff\xd8AAA\xff\xd9"
        f2 = b"\xff\xd8BBBB\xff\xd9"
        buffer = bytearray(b"garble" + f1 + f2 + b"\xff\xd8partial")
        out = []
        split_jpegs(buffer, out.append)
        self.assertEqual(out, [f1, f2])
        self.assertTrue(bytes(buffer).startswith(b"\xff\xd8partial"))   # incomplete frame kept


class HmsResolverTests(unittest.TestCase):
    def test_reads_local_bambu_studio_catalogue_and_falls_back_to_code(self):
        import gantry.hms as hms
        root = Path(tempfile.mkdtemp())
        (root / "hms").mkdir()
        (root / "hms" / "hms_pl_01P.json").write_text(json.dumps([
            {"ecode": "0000_0001", "intro": "Sprawdź prowadzenie filamentu"}
        ]), encoding="utf-8")
        hms._CACHE.clear()
        with patch("gantry.hms._roots", return_value=[root]):
            self.assertEqual(hms.description(["00000001"], "01P123", "pl"),
                             "Sprawdź prowadzenie filamentu")
            self.assertEqual(hms.description(["DEADBEEF"], "01P123", "pl"), "HMS DEADBEEF")


class BambuDetailParseTests(unittest.TestCase):
    def test_fans_speed_diameter(self):
        report = {"print": {"cooling_fan_speed": "15", "big_fan1_speed": "8", "big_fan2_speed": "0",
                            "spd_lvl": 2, "spd_mag": 100, "nozzle_diameter": "0.4"}}
        tel = parse_telemetry(report)
        self.assertEqual(tel.part_fan, 100)     # gear 15 -> 100%
        self.assertEqual(tel.aux_fan, 53)       # gear 8/15 -> 53%
        self.assertEqual(tel.chamber_fan, 0)
        self.assertEqual(tel.speed_level, 2)
        self.assertEqual(tel.speed_percent, 100)
        self.assertEqual(tel.nozzle_diameter, 0.4)


if __name__ == "__main__":
    unittest.main()
