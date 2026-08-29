import io
import tempfile
import unittest
import zipfile
from pathlib import Path

from gantry.consumption import density, grams, parse_3mf_filaments, _consume_klipper
from gantry.physicalspool import PhysicalSpoolStore, location_for
from gantry.core import Telemetry, FilamentGroup, FilamentSlot, PrinterState


def _store():
    d = Path(tempfile.mkdtemp())
    return PhysicalSpoolStore(d / "spools.json", d / "usage.json")


def _make_3mf(rows: str) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Metadata/slice_info.config",
                         f'<?xml version="1.0"?><config><plate>{rows}</plate></config>')
    return buffer.getvalue()


class GramsTests(unittest.TestCase):
    def test_density_by_material(self):
        self.assertEqual(density("PLA"), 1.24)
        self.assertEqual(density("PETG"), 1.27)
        self.assertEqual(density("PLA Silk"), 1.24)
        self.assertEqual(density(None), 1.24)      # unknown falls back to PLA
        self.assertAlmostEqual(density("PA6-CF"), 1.14)

    def test_grams_matches_geometry(self):
        # 1000 mm of PLA 1.75 mm -> area * length / 1000 * density
        g = grams(1000.0, "PLA")
        self.assertAlmostEqual(g, 3.141592653589793 * 0.875 * 0.875 / 1000.0 * 1000.0 * 1.24, places=6)
        self.assertGreater(g, 2.9)
        self.assertLess(g, 3.1)


class Parse3mfTests(unittest.TestCase):
    def test_reads_used_g_and_color(self):
        data = _make_3mf('<filament id="1" type="PLA" color="#E89CC6" used_m="3.20" used_g="9.80"/>'
                         '<filament id="2" type="PETG" color="00A0FF" used_m="1.00" used_g="3.10"/>')
        fils = parse_3mf_filaments(data)
        self.assertEqual(len(fils), 2)
        self.assertEqual(fils[0]["used_g"], 9.8)
        self.assertEqual(fils[0]["color"], "E89CC6")
        self.assertEqual(fils[1]["type"], "PETG")

    def test_bad_data_is_empty(self):
        self.assertEqual(parse_3mf_filaments(b"not a zip"), [])


class ConsumeTests(unittest.TestCase):
    def test_idempotent_per_job(self):
        st = _store()
        st.spools.append({"id": "SP-1", "nominalWeightGrams": 1000, "remainingWeightGrams": 900,
                          "status": "active", "location": location_for("X1", False, 0, 0),
                          "updatedAt": "2026-08-27T10:00:00Z"})
        self.assertTrue(st.consume("SP-1", 50, "X1", "job#1"))
        self.assertEqual(st.spool("SP-1")["remainingWeightGrams"], 850)
        # Same job again is a no-op.
        self.assertFalse(st.consume("SP-1", 50, "X1", "job#1"))
        self.assertEqual(st.spool("SP-1")["remainingWeightGrams"], 850)
        self.assertEqual(len(st.usage), 1)

    def test_klipper_consumes_active_slot(self):
        st = _store()
        st.spools.append({"id": "SP-9", "nominalWeightGrams": 1000, "remainingWeightGrams": 1000,
                          "status": "active", "location": location_for("K1", False, 0, 0),
                          "updatedAt": "2026-08-27T10:00:00Z"})
        tel = Telemetry(state=PrinterState.FINISHED, job_name="cube", filament_used_mm=1000.0)
        tel.filament_groups = [FilamentGroup(
            group_id="ams-0", source_type="ams", display_name="AMS", declared_capacity=1, external=False,
            slots=[FilamentSlot(slot_id="a1", label="A1", material="PLA", active=True)])]
        self.assertTrue(_consume_klipper(st, "K1", tel, "kjob#1"))
        self.assertLess(st.spool("SP-9")["remainingWeightGrams"], 998)


if __name__ == "__main__":
    unittest.main()
