"""Who gets the skip-object button: a Bambu printer only in LAN Only mode with Developer Mode on,
because a cloud-bound one refuses every command Bambu Connect did not sign. Same cases as
Tests/GantryTests/ObjectSkippingTests.swift."""
import unittest

from gantry import objectskipping
from gantry.core import PrinterKind


class ObjectSkippingTests(unittest.TestCase):
    def test_a_bambu_printer_that_wants_signed_commands_is_not_offered_the_button(self):
        self.assertFalse(objectskipping.is_offered(PrinterKind.BAMBU, True))
        self.assertTrue(objectskipping.is_offered(PrinterKind.BAMBU, False))

    def test_klipper_takes_the_skip_from_anybody_on_the_lan(self):
        self.assertTrue(objectskipping.is_offered(PrinterKind.KLIPPER, True))

    def test_printers_without_object_skipping_never_show_it(self):
        for kind in (PrinterKind.PRUSA, PrinterKind.SNAPMAKER, PrinterKind.ELEGOO_CC1,
                     PrinterKind.ELEGOO_CC2, PrinterKind.ANYCUBIC_KOBRA_S1):
            self.assertFalse(objectskipping.is_offered(kind, False), kind)


if __name__ == "__main__":
    unittest.main()
