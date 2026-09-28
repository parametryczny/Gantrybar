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


class SaleQuoteTests(unittest.TestCase):
    """Mirrors SaleQuoteTests in Tests/GantryTests/PrintCostTests.swift."""

    @staticmethod
    def cost(total: float) -> printcost.PrintCost:
        return printcost.PrintCost(filament=total, grams=100, energy=0, machine=0, kwh=0)

    @staticmethod
    def settings(**values: object) -> printcost.PrintCostSettings:
        settings = printcost.PrintCostSettings()
        for key, value in values.items():
            setattr(settings, key, value)
        return settings

    def test_unregistered_without_fees_keeps_the_profit_after_tax(self):
        s = self.settings(business="unregistered", incomeTaxPercent=12, marginPercent=50,
                          failurePercent=0, laborPerHour=0, packaging=0, platformFeePercent=0)
        q = printcost.SaleQuote.compute(self.cost(10), s)
        self.assertEqual(q.vat, 0)
        # Profit before tax 5 / 0.88; after 12% tax exactly 5 is left.
        self.assertAlmostEqual(q.net - q.costs - q.tax, 5, places=9)
        self.assertAlmostEqual(q.gross, 10 + 5 / 0.88, places=9)

    def test_a_vat_payer_adds_vat_on_top_and_pays_the_fee_from_the_gross(self):
        s = self.settings(business="companyVAT", vatPercent=23, incomeTaxPercent=19, marginPercent=30,
                          failurePercent=0, laborPerHour=0, packaging=0, platformFeePercent=10)
        q = printcost.SaleQuote.compute(self.cost(20), s)
        self.assertAlmostEqual(q.gross, q.net * 1.23, places=9)
        self.assertAlmostEqual(q.fee, q.gross * 0.10 / 1.23, places=9)
        self.assertAlmostEqual(q.net - q.fee - q.costs - q.tax, q.profit, places=9)

    def test_lump_sum_tax_is_taken_from_revenue(self):
        s = self.settings(business="company", incomeTaxPercent=8.5, taxOnRevenue=True, marginPercent=20,
                          failurePercent=0, laborPerHour=0, packaging=0, platformFeePercent=0)
        q = printcost.SaleQuote.compute(self.cost(10), s)
        self.assertAlmostEqual(q.tax, q.net * 0.085, places=9)
        self.assertAlmostEqual(q.net - q.costs - q.tax, 2, places=9)

    def test_labour_packaging_and_failures_are_costs(self):
        s = self.settings(failurePercent=10, laborPerHour=60, laborMinutes=10, packaging=3, marginPercent=0)
        q = printcost.SaleQuote.compute(self.cost(10), s)
        self.assertAlmostEqual(q.failures, 1, places=9)
        self.assertAlmostEqual(q.labor, 10, places=9)
        self.assertAlmostEqual(q.costs, 24, places=9)

    def test_older_settings_still_load_with_selling_defaults(self):
        s = printcost.PrintCostSettings.from_dict({"currency": "EUR", "filamentPerKg": 25})
        self.assertEqual(s.currency, "EUR")
        self.assertEqual(s.business, "unregistered")
        self.assertEqual(s.marginPercent, 30)

    def test_selling_fields_round_trip_under_the_macos_names(self):
        s = self.settings(business="companyVAT", taxOnRevenue=True, marginPercent=45, packaging=2.5,
                          materialPerKg={}, watts={})
        data = s.to_dict()
        for key in ("business", "incomeTaxPercent", "taxOnRevenue", "vatPercent", "marginPercent",
                    "platformFeePercent", "laborPerHour", "laborMinutes", "packaging", "failurePercent"):
            self.assertIn(key, data)
        self.assertEqual(printcost.PrintCostSettings.from_dict(data), s)
        self.assertEqual(printcost.PrintCostSettings.from_dict({"business": "bogus"}).business, "unregistered")

    def test_breakdown_lists_vat_only_for_a_vat_payer(self):
        plain = printcost.SaleQuote.compute(self.cost(10), self.settings()).breakdown("PLN", t=lambda k: k)
        self.assertNotIn("VAT", plain)
        self.assertTrue(plain.splitlines()[-1].startswith("Sell for "))
        vat = printcost.SaleQuote.compute(self.cost(10), self.settings(business="companyVAT")).breakdown("PLN", t=lambda k: k)
        self.assertIn("gross", vat.splitlines()[-1])


if __name__ == "__main__":
    unittest.main()
