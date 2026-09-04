#!/usr/bin/env python3
"""Render the Spoolbase inventory window to a PNG offscreen so the Linux look can be reviewed
without a Linux desktop. Run under xvfb: xvfb-run python3 scripts/render_spoolbase.py out.png
"""
import sys

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, Gtk  # noqa: E402

from gantry import app as gapp  # noqa: E402
from gantry import i18n
from gantry.spoolbase import Filament, SpoolbaseWindow  # noqa: E402


class StubWindow:
    tray_mode = False


class StubConfig:
    data = {"spoolbase_enabled": True, "stock_red_max": 1, "stock_blue_max": 5}


i18n.set_language("pl")


class StubApp:
    language = "pl"
    window = StubWindow()
    config = StubConfig()


def sample() -> list[Filament]:
    return [
        Filament(brand="Bambu Lab", name="PLA Basic", type="PLA", colorName="Jade White", colorHex="FFFFFF", spoolCount=6),
        Filament(brand="Polymaker", name="PolyTerra", type="PLA", colorName="Charcoal Black", colorHex="1A1A1A", spoolCount=1),
        Filament(brand="Bambu Lab", name="PLA Matte", type="PLA", colorName="Sakura Pink", colorHex="E8A6C0", spoolCount=3),
        Filament(brand="eSUN", name="PLA+", type="PLA", colorName="Fire Engine Red", colorHex="C8102E", spoolCount=0),
        Filament(brand="Prusament", name="PETG", type="PETG", colorName="Prusa Orange", colorHex="FF7A00", spoolCount=4),
        Filament(brand="Fiberlogy", name="Easy PETG", type="PETG", colorName="Graphite", colorHex="3A3A3C", spoolCount=2),
        Filament(brand="Bambu Lab", name="ABS", type="ABS", colorName="Bambu Green", colorHex="00AE42", spoolCount=5),
        Filament(brand="Polymaker", name="ASA", type="ASA", colorName="Deep Black", colorHex="000000", spoolCount=1),
    ]


def main(out_path: str) -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(gapp.css_for("dark"))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    window = SpoolbaseWindow(StubApp())
    window.store.filaments = sample()
    window._render()

    body = window.get_child()
    window.remove(body)

    off = Gtk.OffscreenWindow()
    off.get_style_context().add_class("popover-window")
    off.set_size_request(500, 620)
    off.add(body)
    off.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration()
    pixbuf = off.get_pixbuf()
    pixbuf.savev(out_path, "png", [], [])
    print("rendered", out_path, pixbuf.get_width(), "x", pixbuf.get_height())


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "spoolbase.png")
