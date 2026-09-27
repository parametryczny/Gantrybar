import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from gantry import printcost
from gantry.filamentstore import Filament


class PrintCostTests(unittest.TestCase):
    def test_split_matches_macos(self):
        settings = printcost.PrintCostSettings(filamentPerKg=80, materialPerKg={"PETG": 100},
                                               electricityPerKWh=1.2, printerWatts=200, machinePerHour=2)
        cost = printcost.compute(3 * 3600, [printcost.Use(250, "pla"), printcost.Use(100, "PETG")], "X", settings)
        self.assertAlmostEqual(cost.filament, 30)
        self.assertAlmostEqual(cost.kwh, 0.6)
        self.assertAlmostEqual(cost.energy, 0.72)
        self.assertAlmostEqual(cost.machine, 6)
        self.assertAlmostEqual(cost.total, 36.72)

    def test_unknown_filament_stays_unknown(self):
        cost = printcost.compute(3600, [], "X", printcost.PrintCostSettings())
        self.assertIsNone(cost.filament)
        self.assertEqual(cost.total, cost.energy + cost.machine)

    def test_shared_settings_json_and_parsing(self):
        settings = printcost.PrintCostSettings.from_dict({"filamentPerKg": 95, "watts": {"A": 300}})
        self.assertEqual(settings.filamentPerKg, 95)
        self.assertEqual(settings.power("A"), 300)
        self.assertEqual(settings.currency, "PLN")
        self.assertEqual(printcost.parse_material_prices("petg=90, ASA = 119,50; TPU=140\nbroken"),
                         {"PETG": 90, "ASA": 119.5, "TPU": 140})
        self.assertEqual(printcost.parse_amount("89,90"), 89.9)
        self.assertIsNone(printcost.parse_amount("abc"))

    def test_roll_price_then_product_price_then_list(self):
        now = datetime.now(timezone.utc)
        definition = Filament(brand="B", name="N", type="PLA", colorName="W", colorHex="FFFFFF", pricePerRoll=60)
        spools = SimpleNamespace(
            usage=[{"printerSerial": "X", "spoolID": "SP-1", "consumedGrams": 100, "timestamp": now.isoformat()},
                   {"printerSerial": "X", "spoolID": "SP-2", "consumedGrams": 100, "timestamp": now.isoformat()},
                   {"printerSerial": "Y", "spoolID": "SP-1", "consumedGrams": 999, "timestamp": now.isoformat()}],
            spool=lambda sid: {"SP-1": {"price": 90, "nominalWeightGrams": 750, "filamentDefinitionID": definition.id},
                               "SP-2": {"nominalWeightGrams": 1000, "filamentDefinitionID": definition.id}}.get(sid))
        app = SimpleNamespace(physical_spools=spools, filament_store=SimpleNamespace(filaments=[definition]))
        used = printcost.uses(app, "X", now - timedelta(hours=1), now)
        self.assertEqual([round(u.price_per_kg) for u in used], [120, 60])
        cost = printcost.compute(0, used, "X", printcost.PrintCostSettings(filamentPerKg=80))
        self.assertAlmostEqual(cost.filament, 18)

    def test_ean_check_digit(self):
        self.assertTrue(printcost.ean_plausible("5901234123457"))
        self.assertFalse(printcost.ean_plausible("5901234123458"))
        self.assertTrue(printcost.ean_plausible("96385074"))
        self.assertTrue(printcost.ean_plausible("036000291452"))
        self.assertFalse(printcost.ean_plausible("12345"))
        self.assertTrue(printcost.ean_plausible("BL-PLA-1001"))


if __name__ == "__main__":
    unittest.main()
