"""The open edge dock as one column: picture with its caption over its bottom, hairline to the next printer
(contract edgeDock.captions), and the settings button under the strip (edgeDock.settingsButton). Mixed
cameras, long names, lost pictures, all previews off and a small screen."""
import unittest

from gantry import dockcaptions as dc


class FakeMeasure:
    """7 pt per character for names, 6 for metrics; a wrapped name takes one 16 pt line per chunk."""
    name_line = 16.0
    value_line = 13.0

    def name_width(self, text):
        return len(text) * 7.0

    def value_width(self, text):
        return len(text) * 6.0

    def name_height(self, text, width):
        per_line = max(1, int(width // 7))
        lines = -(-len(text) // per_line)
        return lines * self.name_line


def caption(name, camera=dc.LIVE, picture=True, value="66% · 0:55"):
    return dc.Caption(name=name, value=value, camera=camera, has_picture=picture and camera == dc.LIVE)


WIDTH = 260.0
INF = float("inf")


class CaptionPlanTests(unittest.TestCase):
    def setUp(self):
        self.measure = FakeMeasure()

    def test_caption_over_the_bottom_of_the_picture_then_hairline(self):
        plan = dc.plan([caption("X1"), caption("P2S · stanowisko produkcyjne przy oknie")], WIDTH, self.measure)
        first, second = plan.rows
        self.assertEqual(first.picture_width, WIDTH - 2 * dc.INSET_X)
        self.assertEqual(first.picture_height, round(first.picture_width * 9 / 16))
        # A picture costs no more height than its image: the caption sits inside its bottom edge.
        self.assertEqual(first.block_height, first.picture_height)
        self.assertTrue(first.overlay)
        self.assertEqual(first.caption_top + first.caption_height, first.block_top + first.picture_height)
        self.assertIsNone(first.note)
        # Over a picture a long name stays on one line.
        self.assertFalse(second.wraps)
        self.assertEqual(second.block_top - (first.block_top + first.block_height), dc.PRINTER_GAP * 2 + 1)

    def test_mixed_fleet_notes(self):
        plan = dc.plan([caption("X1"), caption("P1S", dc.PREVIEW_OFF), caption("MINI", dc.NO_CAMERA),
                        caption("Voron", dc.HIDDEN)], WIDTH, self.measure)
        live, off, none, hidden = plan.rows
        self.assertGreater(live.picture_height, 0)
        self.assertEqual((off.picture_height, off.note), (0, "Preview off"))
        self.assertEqual((none.picture_height, none.note), (0, "No camera"))
        # No empty room for a picture that is not there.
        self.assertEqual(off.block_height, off.caption_height + dc.STATUS_ROW)
        self.assertEqual(hidden.block_height, hidden.caption_height)
        self.assertIsNone(hidden.note)

    def test_lost_picture_keeps_its_place(self):
        """A stream that stopped sending frames is still attached: its picture keeps its room and its plate
        says "No picture", which the drawing decides from frame times, not the plan."""
        live = dc.plan([caption("X1")], WIDTH, self.measure).rows[0]
        self.assertGreater(live.picture_height, 0)

    def test_long_name_wraps_and_moves_metrics_below(self):
        name = "X1 Carbon · lewy regał przy oknie"
        plan = dc.plan([caption(name, dc.NO_CAMERA)], WIDTH, self.measure)
        row = plan.rows[0]
        self.assertTrue(row.wraps)
        text_width = WIDTH - 2 * dc.INSET_X - dc.RING_SPAN
        self.assertEqual(row.name_height, self.measure.name_height(name, text_width))
        self.assertGreaterEqual(row.caption_height,
                                row.name_height + dc.WRAPPED_LINE_GAP + self.measure.value_line + dc.CAPTION_PAD_Y * 2)

    def test_long_name_does_not_widen_the_strip(self):
        short = dc.strip_width([caption("X1" + "a" * 16, dc.NO_CAMERA)], self.measure)
        long = dc.strip_width([caption("X1" + "a" * 60, dc.NO_CAMERA)], self.measure)
        self.assertEqual(short, long)
        self.assertLessEqual(long, dc.PLAIN_MAX_STRIP_WIDTH)

    def test_all_previews_off(self):
        captions = [caption(name, dc.PREVIEW_OFF) for name in ("X1", "P2S", "X2D")]
        plan = dc.plan(captions, dc.strip_width(captions, self.measure), self.measure)
        self.assertTrue(all(row.picture_height == 0 and row.note == "Preview off" for row in plan.rows))

    def test_small_screen_gives_way_in_order_and_keeps_printers(self):
        captions = [caption(f"P{i}") for i in range(6)]
        full = dc.fitted_plan(captions, WIDTH, self.measure, INF)
        self.assertTrue(all(row.picture_height > 0 for row in full.rows))

        smaller = dc.fitted_plan(captions, WIDTH, self.measure, full.height * 0.8)
        self.assertLessEqual(smaller.height, full.height * 0.8)
        self.assertTrue(all(0 < row.picture_width < full.rows[0].picture_width for row in smaller.rows))

        no_pictures = dc.fitted_plan(captions, WIDTH, self.measure, 420)
        self.assertTrue(all(row.picture_height == 0 and row.note == "Not enough room for the preview"
                            for row in no_pictures.rows))
        self.assertLessEqual(no_pictures.height, 420)

        bare = dc.fitted_plan(captions, WIDTH, self.measure, 320)
        self.assertTrue(all(row.note is None for row in bare.rows))

        cut = dc.fitted_plan(captions * 5, WIDTH, self.measure, 150)
        self.assertEqual(cut.height, 150)
        for plan in (smaller, no_pictures, bare):
            self.assertEqual(len(plan.rows), len(captions))


class GtkDockDrawingTests(unittest.TestCase):
    """Draws the real strip into an image and checks that nothing leaves it or overlaps."""

    @classmethod
    def setUpClass(cls):
        try:
            import cairo
            from gi.repository import Gtk
            from gantry import edgedock
            window = Gtk.Window()
            window.destroy()
        except Exception as error:  # pragma: no cover - no GTK display on this host
            raise unittest.SkipTest(f"GTK display unavailable: {error}")
        cls.cairo, cls.edgedock = cairo, edgedock

    def dock(self, entries, pictures=(), available=2000.0):
        from types import SimpleNamespace
        config = SimpleNamespace(data={"edge-dock-edge": "right", "edge-dock-pinned": True}, save=lambda: None)
        app = SimpleNamespace(config=config, language="pl", printers=[], telemetry={})
        dock = self.edgedock.EdgeDock(app)
        dock.entries = entries
        dock.camera_views = {serial: object() for serial in pictures}
        dock._available_height = available
        return dock

    def draw(self, dock):
        width, height = dock._size()
        surface = self.cairo.ImageSurface(self.cairo.FORMAT_ARGB32, int(width), int(height))
        dock._on_draw(None, self.cairo.Context(surface))
        return width, height

    @staticmethod
    def entry(serial, name, camera):
        return {"serial": serial, "name": name, "state": "printing", "progress": 60, "remaining": 66, "camera": camera}

    def test_mixed_fleet_with_long_name_fits_and_clicks_map_to_printers(self):
        entries = [self.entry("x1", "X1", "live"), self.entry("p2s", "P2S · stanowisko produkcyjne przy oknie", "live"),
                   self.entry("p1s", "P1S", "preview_off"), self.entry("mini", "MINI", "no_camera")]
        dock = self.dock(entries, pictures=("x1", "p2s"))
        width, height = self.draw(dock)
        self.assertLessEqual(width, self.edgedock.dc.CAMERA_MAX_STRIP_WIDTH)
        self.assertEqual([serial for _top, _bottom, serial in dock._row_hits], ["x1", "p2s", "p1s", "mini"])
        tops = [top for top, _bottom, _serial in dock._row_hits]
        self.assertEqual(tops, sorted(tops))
        for left, top, w, h in dock._picture_hits:
            self.assertGreaterEqual(left, 0)
            self.assertLessEqual(left + w, width)
        # Over a picture a long name stays on one line, cut with an ellipsis, instead of wrapping.
        plan = dock._plan(dock._expanded_width())
        self.assertTrue(plan.rows[1].overlay)
        self.assertFalse(plan.rows[1].wraps)
        # The caption over the bottom of a picture opens its printer; the rest of the picture does not.
        for left, top, w, h in dock._picture_hits:
            self.assertLess(h, plan.rows[0].picture_height)

    def test_small_screen_strip_stays_on_the_display(self):
        entries = [self.entry(f"p{i}", f"P{i}", "live") for i in range(8)]
        dock = self.dock(entries, pictures=[f"p{i}" for i in range(8)], available=600.0)
        _width, height = self.draw(dock)
        self.assertLessEqual(height, 600.0)

    def test_settings_button_sits_under_the_strip_and_opens_settings(self):
        from types import SimpleNamespace
        dock = self.dock([self.entry("x1", "X1", "hidden")])
        dock.app.config.data["edge-dock-pinned"] = False
        width, height = self.draw(dock)
        # The silhouette ends above the band that holds the button's lower half.
        self.assertEqual(height, (self.edgedock.PAD_Y * 2 + self.edgedock.RING + self.edgedock.NOTCH * 2
                                  + self.edgedock.ORB_BAND))
        cx, cy = dock._orb_logical_center()
        self.assertEqual((cx, cy), (width - self.edgedock.NOTCH, height - self.edgedock.ORB_BAND))
        # Reaching for the button does not unfold a folded strip.
        dock._on_enter(None, SimpleNamespace(x=cx, y=cy + 4))
        self.assertFalse(dock.hovering)
        opened = []
        dock.app.open_edge_dock_settings = lambda: opened.append(True)
        dock._on_click(None, SimpleNamespace(x=cx, y=cy))
        self.assertEqual(opened, [True])

    def test_value_says_how_long_is_left_and_when_it_ends(self):
        dock = self.dock([self.entry("x1", "X1", "hidden")])
        value = dock._value_text({"state": "printing", "progress": 75, "remaining": 76})
        self.assertRegex(value, r"^75% · 1h 16m · \d\d:\d\d$")
        self.assertRegex(dock._value_text({"state": "printing", "progress": 9, "remaining": 42}), r"^9% · 42m · ")


class GearTests(unittest.TestCase):
    def test_gear_has_eight_teeth_inside_its_box(self):
        points = dc.gear_outline(0, 0, 12)
        self.assertEqual(len(points), dc.GEAR_TEETH * 4)
        radii = sorted({round((x * x + y * y) ** 0.5, 6) for x, y in points})
        self.assertEqual(radii, [round(6 * dc.GEAR_ROOT, 6), 6.0])


if __name__ == "__main__":
    unittest.main()
