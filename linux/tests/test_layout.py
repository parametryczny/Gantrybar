import unittest

from gantry.core import FilamentGroup, NozzleTelemetry, Telemetry
from gantry.layout import Placement, needs_wide, panel_width, place_cards


class DashboardLayoutTests(unittest.TestCase):
    def test_panel_widths_match_current_macos_controller(self) -> None:
        self.assertEqual(panel_width(False, 1), 380)
        self.assertEqual(panel_width(False, 2), 563)
        self.assertEqual(panel_width(True, 2), 512)

    def test_last_odd_card_spans_full_width_like_macos(self) -> None:
        values = {serial: Telemetry() for serial in ("a", "b", "c")}
        self.assertEqual(place_cards(["a", "b", "c"], values, 2), [
            Placement("a", 0, 0, 1), Placement("b", 0, 1, 1), Placement("c", 1, 0, 2),
        ])

    def test_dual_nozzle_and_multiple_ams_are_wide(self) -> None:
        dual = Telemetry(nozzles=[NozzleTelemetry("left"), NozzleTelemetry("right")])
        groups = [
            FilamentGroup("a", "ams", "AMS A", 4),
            FilamentGroup("b", "ams", "AMS B", 4),
        ]
        multiple_ams = Telemetry(filament_groups=groups)
        self.assertTrue(needs_wide(dual))
        self.assertTrue(needs_wide(multiple_ams))
        placed = place_cards(["normal", "dual", "normal2"],
                             {"dual": dual, "normal": Telemetry(), "normal2": Telemetry()}, 2)
        self.assertEqual(placed, [
            Placement("normal", 0, 0, 1),
            Placement("dual", 1, 0, 2),
            Placement("normal2", 2, 0, 2),
        ])

    def test_compact_mode_is_one_column(self) -> None:
        values = {serial: Telemetry() for serial in ("a", "b")}
        self.assertEqual(place_cards(["a", "b"], values, 2, compact=True), [
            Placement("a", 0, 0, 1), Placement("b", 1, 0, 1),
        ])


if __name__ == "__main__":
    unittest.main()
