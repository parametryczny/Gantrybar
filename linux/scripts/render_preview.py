#!/usr/bin/env python3
"""Render the dashboard cards to a PNG offscreen (no visible window) so the Linux look can be
reviewed without a Linux desktop. Run under xvfb-run on CI: xvfb-run python3 scripts/render_preview.py out.png
"""
import sys

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, Gtk  # noqa: E402

from gantry import app as gapp  # noqa: E402
from gantry.core import (  # noqa: E402
    FilamentGroup, FilamentSlot, NozzleTelemetry, Printer, PrinterKind, PrinterState, Telemetry,
)


class StubApp:
    language = "pl"
    text = gapp.TEXT["pl"]
    window = None

    def open_printer_dialog(self, *a): ...
    def remove_printer(self, *a): ...
    def move_printer(self, *a): ...
    def toggle_compact_printer(self, *a): ...


def slot(label, material, color, remaining, active):
    return FilamentSlot(slot_id=label, label=label, material=material, color=color,
                        remaining=remaining, active=active)


def main(out_path: str) -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(gapp.css_for("dark"))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    app = StubApp()
    ams_a = FilamentGroup(group_id="a", source_type="ams", display_name="AMS A", declared_capacity=4,
                          external=False, humidity=19, temperature=47, slots=[
                              slot("A1", None, None, None, False),
                              slot("A2", "PLA", "E8C848FF", 60, False),
                              slot("A3", "PETG", "111111FF", 8, True),
                              slot("A4", None, None, None, False)])
    ext_x1 = FilamentGroup(group_id="e", source_type="external", display_name="EXT", declared_capacity=1,
                           external=True, slots=[slot("EXT", "TPU", "487705FF", 100, True)])
    ams_ht = FilamentGroup(group_id="ht", source_type="amsHT", display_name="AMS HT", declared_capacity=1,
                           external=False, humidity=33, temperature=36, slots=[slot("A1", None, None, None, False)])
    ext_p2s = FilamentGroup(group_id="eb", source_type="external", display_name="EXT", declared_capacity=1,
                            external=True, slots=[slot("EXT", "PETG", "161616FF", 100, True)])

    def tel(dual, groups, job, prog, layer):
        t = Telemetry()
        t.state = PrinterState.PRINTING
        t.progress = prog
        t.remaining_minutes = 43
        t.nozzle, t.nozzle_target = 245, 245
        t.bed, t.bed_target = 70, 70
        t.chamber = 51
        t.current_layer, t.total_layers = layer, 326
        t.job_name = job
        t.filament_groups = groups
        t.nozzles = ([NozzleTelemetry(position="left", current=49, target=40),
                      NozzleTelemetry(position="right", current=220, target=220)]
                     if dual else [NozzleTelemetry(position="single", current=245, target=245)])
        return t

    defs = [
        (Printer(serial="X1", name="Bambu 3058", host="1.2.3.4", kind=PrinterKind.BAMBU),
         tel(False, [ams_a, ext_x1], "demo_1", 76, 185)),
        (Printer(serial="P2S", name="P1S", host="1.2.3.4", kind=PrinterKind.BAMBU),
         tel(False, [ams_ht, ext_p2s], "demo_2", 71, 113)),
    ]

    grid = Gtk.Grid(column_spacing=10, row_spacing=10, margin=12)
    for i, (printer, t) in enumerate(defs):
        card = gapp.PrinterCard(app, printer)
        card.update(t)
        grid.attach(card, i % 2, i // 2, 1, 1)

    win = Gtk.OffscreenWindow()
    win.get_style_context().add_class("popover-window")
    win.add(grid)
    win.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration()
    pixbuf = win.get_pixbuf()
    pixbuf.savev(out_path, "png", [], [])
    print("rendered", out_path, pixbuf.get_width(), "x", pixbuf.get_height())


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "preview.png")
