"""The edge dock outline on Linux: the rounded corners on the screen side must be filled, not bitten out
(a clockwise arc there drew a loop and left a hole in each corner, reported 2026-09-18)."""
import unittest

try:
    import cairo
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("PangoCairo", "1.0")
    from gantry.edgedock import EdgeDock
except (ImportError, ValueError) as error:  # pragma: no cover - runs only where GTK is installed
    EdgeDock = None
    SKIP_REASON = str(error)


def _alpha(surface, x, y):
    stride = surface.get_stride()
    return surface.get_data()[int(y) * stride + int(x) * 4 + 3]


@unittest.skipIf(EdgeDock is None, "GTK/cairo unavailable")
class SilhouetteTests(unittest.TestCase):
    def render(self, width=300, height=90):
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        cr = cairo.Context(surface)
        EdgeDock._silhouette(cr, width, height)
        cr.set_source_rgba(0, 0, 0, 1)
        cr.fill()
        surface.flush()
        return surface

    def test_rounded_corners_are_filled_not_bitten_out(self):
        surface = self.render()
        top, bottom, body = 11, 90 - 11, 12
        # The centres of both corner arcs and the middle of the body lie inside the outline.
        for x, y in [(body, top + body), (body, bottom - body), (150, 45), (4, 45)]:
            self.assertEqual(_alpha(surface, x, y), 255, (x, y))

    def test_outer_corner_pixels_stay_clear(self):
        surface = self.render()
        # The very corner outside each rounding stays transparent.
        self.assertEqual(_alpha(surface, 1, 12), 0)
        self.assertEqual(_alpha(surface, 1, 90 - 13), 0)


if __name__ == "__main__":
    unittest.main()
