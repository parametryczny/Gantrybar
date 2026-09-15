"""Edge dock on simulated desktops: which monitor it lands on and where. The same cases as macOS
EdgeDockPlacementTests and the Windows presentation tests, in y-down pixels."""
import unittest

from gantry.dockplacement import (EdgeDockDisplay, choices, format_frame, is_inner_edge, parse_frame, place,
                                  resolve)


def display(ident, x, y, width, height, primary=False):
    # A 40 px panel at the bottom of the work area.
    return EdgeDockDisplay(ident, ident, width, height, (x, y, width, height), (x, y, width, height - 40), primary)


class DisplayLookupTests(unittest.TestCase):
    def test_no_choice_means_the_main_display(self):
        chosen, matched = resolve([display("side", 1920, 0, 2560, 1440), display("main", 0, 0, 1920, 1080, True)], "", None)
        self.assertEqual((chosen.id, matched), ("main", False))
        self.assertIsNone(resolve([], "", None))

    def test_saved_display_by_id_then_frame_then_fallback(self):
        main, side = display("main", 0, 0, 1920, 1080, True), display("side", 1920, 0, 2560, 1440)
        saved = (1920, 0, 2560, 1440)
        self.assertEqual(resolve([main, side], "side", saved)[0].id, "side")
        renamed = display("side-2", 1924, 0, 2560, 1440)
        self.assertEqual(resolve([main, renamed], "side", saved), (renamed, True))
        self.assertEqual(resolve([main, display("side", 1920, 0, 3840, 2160)], "side", saved)[0].id, "side")
        self.assertEqual(resolve([main], "side", saved), (main, False))

    def test_twins_with_the_saved_frame_resolve_to_the_main_display(self):
        twins = [display("a", 0, 0, 1920, 1080), display("b", 0, 0, 1920, 1080, True)]
        self.assertEqual(resolve(twins, "gone", (0, 0, 1920, 1080))[0].id, "b")

    def test_without_a_primary_the_first_monitor_is_the_main_one(self):
        # Wayland compositors may name no primary monitor.
        first, second = display("first", 0, 0, 1920, 1080), display("second", 1920, 0, 1920, 1080)
        self.assertEqual(resolve([first, second], "", None)[0].id, "first")


class PlacementTests(unittest.TestCase):
    screen, work = (0, 0, 1000, 1040), (0, 0, 1000, 1000)

    def test_rows_keep_clear_of_corners(self):
        self.assertEqual(place(self.screen, self.work, False, "top", 22, 100), (978, 200))
        self.assertEqual(place(self.screen, self.work, True, "middle", 22, 100), (0, 450))
        self.assertEqual(place(self.screen, self.work, True, "bottom", 22, 100), (0, 700))

    def test_a_tall_strip_stays_on_its_display(self):
        self.assertEqual(place(self.screen, self.work, False, "top", 240, 900), (760, 100))
        self.assertEqual(place(self.screen, self.work, False, "bottom", 240, 1200)[1], 0)

    def test_inner_edges_are_shared_with_another_display(self):
        left, right = display("left", 0, 0, 1920, 1080, True), display("right", 1920, -200, 2560, 1440)
        above = display("above", 0, -1080, 1920, 1080)
        everything = [left, right, above]
        self.assertTrue(is_inner_edge(left, False, everything))
        self.assertFalse(is_inner_edge(left, True, everything))
        self.assertTrue(is_inner_edge(right, True, everything))
        self.assertFalse(is_inner_edge(right, False, everything))
        self.assertFalse(is_inner_edge(above, False, [left, above]))

    def test_frames_round_trip_and_the_list_keeps_an_unplugged_display(self):
        frame = (-1920, 120, 1920, 1080)
        self.assertEqual(parse_frame(format_frame(frame)), frame)
        self.assertIsNone(parse_frame("1,2,0,4"))
        self.assertIsNone(parse_frame("junk"))
        main = display("main", 0, 0, 1920, 1080, True)
        listed = choices([main], "dell", "DELL U2723QE")
        self.assertEqual([ident for ident, _title, _selected in listed], ["", "main", "dell"])
        self.assertEqual([ident for ident, _title, selected in listed if selected], ["dell"])
        self.assertTrue(choices([main], "", "")[0][2])


if __name__ == "__main__":
    unittest.main()
