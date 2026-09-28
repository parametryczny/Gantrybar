"""SpoolAutoPair port (macOS Tests/GantryTests/SpoolAutoPairTests.swift) plus the pairing flow."""
import json
import tempfile
import unittest
from pathlib import Path

from gantry import printcost
from gantry.core import FilamentGroup, FilamentSlot, parse_telemetry, tag_uid
from gantry.filamentstore import Filament
from gantry.physicalspool import PhysicalSpoolStore, location_for
from gantry.spoolautopair import best_product, pair


def _slot(material, color, product=None, uid="ABCDEF0123", nominal=None):
    return FilamentSlot(slot_id="ams-0-0", label="A1", material=material, color=color, remaining=100,
                        active=False, spool_uid=uid, product_name=product, nominal_grams=nominal)


def _groups(slot):
    return [FilamentGroup(group_id="ams-0", source_type="ams", display_name="AMS A", declared_capacity=4,
                          slots=[slot])]


class SpoolAutoPairTests(unittest.TestCase):
    def test_the_printer_brand_and_product_name_win_at_the_same_colour(self):
        other = Filament(brand="Devil Design", name="PETG", type="PETG", colorName="Black", colorHex="000000")
        bambu = Filament(brand="Bambu Lab", name="PETG Basic", type="PETG", colorName="Black", colorHex="000000")
        pla = Filament(brand="Bambu Lab", name="PLA Basic", type="PLA", colorName="Black", colorHex="000000")
        best = best_product(_slot("PETG", "000000FF", product="PETG Basic"), [other, bambu, pla])
        self.assertEqual(best.id, bambu.id)

    def test_a_different_colour_is_not_the_same_product(self):
        red = Filament(brand="Bambu Lab", name="PETG Basic", type="PETG", colorName="Red", colorHex="FF0000")
        self.assertIsNone(best_product(_slot("PETG", "0000FFFF"), [red]))

    def test_a_tag_of_zeros_is_no_tag(self):
        self.assertIsNone(tag_uid({"tray_uuid": "00000000000000000000000000000000"}))
        self.assertEqual(tag_uid({"tray_uuid": "a1b2c3"}), "A1B2C3")
        self.assertIsNone(tag_uid({}))


class ParserTests(unittest.TestCase):
    def test_the_ams_report_carries_the_tag_product_and_full_weight(self):
        payload = {"print": {"ams": {"tray_now": "255", "ams": [{"id": "0", "tray": [
            {"id": "0", "tray_type": "PETG", "tray_color": "000000FF", "remain": 50, "tray_weight": "1000",
             "tray_uuid": "a1b2c3d4", "tray_sub_brands": "PETG Basic"},
            {"id": "1", "tray_type": "PLA", "tray_color": "FFFFFFFF", "tray_uuid": "0000", "tray_sub_brands": ""}]}]}}}
        groups = parse_telemetry(json.dumps(payload)).filament_groups
        tagged, plain = groups[0].slots[0], groups[0].slots[1]
        self.assertEqual((tagged.spool_uid, tagged.product_name, tagged.nominal_grams), ("A1B2C3D4", "PETG Basic", 1000.0))
        self.assertEqual((plain.spool_uid, plain.product_name, plain.nominal_grams), (None, None, None))


class PairingFlowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.store = PhysicalSpoolStore(root / "spools.json", root / "usage.json")
        self.product = Filament(brand="Bambu Lab", name="PETG Basic", type="PETG", colorName="Black",
                                colorHex="000000", pricePerRoll=80.0)
        self.location = location_for("X1", False, 0, 0)

    def tearDown(self):
        self.directory.cleanup()

    def test_a_new_tag_takes_an_opened_roll_from_storage_and_keeps_the_tag(self):
        older, opened = self.store.create_rolls(self.product.id, 2, 1000)
        opened["openedAt"] = "2026-09-01T00:00:00Z"
        notices = pair("X1", _groups(_slot("PETG", "000000FF", "PETG Basic")), self.store, [self.product])
        self.assertEqual(len(notices), 1)
        self.assertEqual(self.store.spool_at(self.location)["id"], opened["id"])
        self.assertEqual(opened["tagUID"], "ABCDEF0123")
        self.assertNotIn("tagUID", older)

    def test_without_a_stored_roll_one_is_created_priced_like_the_product(self):
        pair("X1", _groups(_slot("PETG", "000000FF", nominal=750)), self.store, [self.product])
        roll = self.store.spool_at(self.location)
        self.assertEqual((roll["nominalWeightGrams"], roll["price"], roll["tagUID"]), (750.0, 80.0, "ABCDEF0123"))

    def test_a_known_tag_is_recognised_in_another_slot(self):
        roll = self.store.create_rolls(self.product.id, 1, 1000)[0]
        self.store.set_tag(roll["id"], "ABCDEF0123")
        notices = pair("X1", _groups(_slot("PETG", "FF0000FF")), self.store, [])
        self.assertEqual(self.store.spool_at(self.location)["id"], roll["id"])
        self.assertEqual(len(notices), 1)

    def test_a_manual_assignment_without_a_tag_is_never_replaced(self):
        manual = self.store.create_rolls(self.product.id, 1, 1000)[0]
        self.store.assign(manual["id"], self.location)
        self.assertEqual(pair("X1", _groups(_slot("PETG", "000000FF")), self.store, [self.product]), [])
        self.assertEqual(self.store.spool_at(self.location)["id"], manual["id"])
        self.assertEqual(len(self.store.spools), 1)

    def test_a_roll_without_a_tag_is_left_alone(self):
        self.assertEqual(pair("X1", _groups(_slot("PETG", "000000FF", uid=None)), self.store, [self.product]), [])
        self.assertEqual(self.store.spools, [])

    def test_calculator_prices_a_product_from_its_rolls_or_the_product(self):
        self.assertEqual(printcost.spoolbase_price_per_kg(self.product, self.store), 80.0)
        self.store.create_rolls(self.product.id, 1, 500, price=50)
        self.store.create_rolls(self.product.id, 1, 1000, price=90)
        self.assertAlmostEqual(printcost.spoolbase_price_per_kg(self.product, self.store), 95.0)


if __name__ == "__main__":
    unittest.main()
