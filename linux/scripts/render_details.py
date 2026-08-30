#!/usr/bin/env python3
"""Render the real Details window (details.DetailWindow) to a PNG offscreen, so the new view can be
reviewed without a Linux desktop. Uses the actual widgets and css_for(), same as render_preview.py.
Run under xvfb: xvfb-run python3 scripts/render_details.py out.png
"""
import math
import sys

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, Gtk  # noqa: E402

from gantry import app as gapp  # noqa: E402
from gantry.details import DetailWindow  # noqa: E402
from gantry.core import (  # noqa: E402
    FilamentGroup, FilamentSlot, NozzleTelemetry, Printer, PrinterKind, PrinterState, Telemetry,
)


class StubApp:
    language = "pl"
    text = gapp.TEXT["pl"]
    window = None

    class _Cfg:
        data = {"monochrome": False, "card_show_spool_grams": False, "spoolbase_enabled": True}

    def __init__(self, printers):
        self.printers = printers
        self.temp_history = {}
        self.config = StubApp._Cfg()

    def open_automations(self, *a): ...
    def open_camera(self, *a): ...


def slot(label, material, color, remaining, active):
    return FilamentSlot(slot_id=label, label=label, material=material, color=color,
                        remaining=remaining, active=active)


def main(out_path: str) -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(gapp.css_for("dark"))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    printer = Printer(serial="X1", name="Bambu 3058", host="1.2.3.4", kind=PrinterKind.BAMBU)
    app = StubApp([printer])
    # A rolling history so the graph draws real lines (time, nozzle, bed, chamber).
    app.temp_history["X1"] = [
        (float(i), 40 + 205 * min(1, i / 12) + 3 * math.sin(i / 2),
         22 + 48 * min(1, i / 7) + 1.5 * math.sin(i / 3),
         24 + 27 * min(1, i / 18)) for i in range(48)]

    tel = Telemetry()
    tel.state = PrinterState.PRINTING
    tel.progress = 76
    tel.remaining_minutes = 43
    tel.nozzle, tel.nozzle_target = 245, 245
    tel.bed, tel.bed_target = 70, 70
    tel.chamber = 51
    tel.current_layer, tel.total_layers = 185, 326
    tel.job_name = "demo_1"
    tel.part_fan, tel.aux_fan, tel.chamber_fan = 100, 53, 0
    tel.speed_level, tel.speed_percent = 2, 100
    tel.nozzle_diameter = 0.4
    tel.nozzles = [NozzleTelemetry(position="single", current=245, target=245)]
    tel.filament_groups = [
        FilamentGroup(group_id="a", source_type="ams", display_name="AMS A", declared_capacity=4,
                      external=False, humidity=19, temperature=47, slots=[
                          slot("A1", None, None, None, False),
                          slot("A2", "PLA", "E8C848FF", 60, False),
                          slot("A3", "PETG", "111111FF", 8, True),
                          slot("A4", None, None, None, False)]),
        FilamentGroup(group_id="e", source_type="external", display_name="EXT", declared_capacity=1,
                      external=True, slots=[slot("EXT", "TPU", "487705FF", 100, True)]),
    ]

    detail = DetailWindow(app, "X1")
    detail.update(tel)
    # Render the content box directly: the ScrolledWindow collapses to zero height offscreen, so
    # reparent the body (graph + tiles + filaments) which has a real natural height.
    body = detail.body
    body.get_parent().remove(body)
    body.set_size_request(430, -1)

    win = Gtk.OffscreenWindow()
    win.get_style_context().add_class("popover-window")
    win.add(body)
    win.show_all()
    for _ in range(4):
        while Gtk.events_pending():
            Gtk.main_iteration()
    # The temperature graph is a DrawingArea; force an expose after it has a real allocation so its
    # cairo lines land in the captured pixbuf.
    detail.graph.queue_draw()
    for _ in range(4):
        while Gtk.events_pending():
            Gtk.main_iteration()
    pixbuf = win.get_pixbuf()
    pixbuf.savev(out_path, "png", [], [])
    print("rendered", out_path, pixbuf.get_width(), "x", pixbuf.get_height())


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "details.png")
