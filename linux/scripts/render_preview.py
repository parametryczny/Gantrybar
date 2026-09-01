#!/usr/bin/env python3
"""Render the real GTK dashboard to PNG.

The preview is built from ``Dashboard`` and ``PrinterCard`` rather than from a separate mock UI.
On Linux CI run it through Xvfb; Homebrew GTK can render it through the Quartz backend on macOS.
"""
from __future__ import annotations

import sys

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402

from gantry import app as gapp  # noqa: E402
from gantry.core import (  # noqa: E402
    FilamentGroup,
    FilamentSlot,
    NozzleTelemetry,
    Printer,
    PrinterKind,
    PrinterState,
    Telemetry,
)
from gantry.layout import place_cards  # noqa: E402


class _StubConfig:
    data = {
        "theme": "dark",
        "dashboard_columns": 2,
        "collapsed": False,
        "collapsed_chosen": True,
        "spoolbase_enabled": True,
        "card_show_spool_grams": True,
        "card_show_filename": True,
        "card_show_progress": True,
        "card_show_temperatures": True,
        "card_show_filaments": True,
        "monochrome": False,
    }

    def save(self) -> None:
        pass


class StubApp:
    language = "pl"
    text = gapp.TEXT["pl"]
    config = _StubConfig()
    physical_spools = None
    filament_store = None
    indicator_available = True
    expanded_compact_serial = None
    stages = gapp.STAGES

    def __init__(self, printers: list[Printer], telemetry: dict[str, Telemetry]) -> None:
        self.printers = printers
        self.telemetry = telemetry
        self.cards: dict[str, gapp.PrinterCard] = {}
        self.window = None

    def is_compact(self) -> bool:
        return False

    def open_printer_dialog(self, *args): pass
    def remove_printer(self, *args): pass
    def move_printer(self, *args): pass
    def toggle_compact_printer(self, *args): pass
    def open_details(self, *args): pass
    def open_automations(self, *args): pass
    def open_camera(self, *args): pass
    def reconnect_all(self, *args): pass
    def reset_completed(self, *args): pass
    def rebuild_cards(self, *args): pass


def slot(label: str, material: str | None = None, color: str | None = None,
         remaining: int | None = None, active: bool = False,
         grams: float | None = None) -> FilamentSlot:
    return FilamentSlot(
        slot_id=label, label=label, material=material, color=color, remaining=remaining,
        active=active, remaining_weight_g=grams,
    )


def group(group_id: str, name: str, slots: list[FilamentSlot], *, external: bool = False,
          humidity: int | None = None, temperature: float | None = None) -> FilamentGroup:
    return FilamentGroup(
        group_id=group_id, source_type="external" if external else "ams", display_name=name,
        declared_capacity=len(slots), external=external, humidity=humidity,
        temperature=temperature, slots=slots,
    )


def telemetry(*, progress: int, remaining: int, nozzle: float, nozzle_target: float,
              bed: float, bed_target: float, chamber: float | None, layer: int,
              layers: int, job: str, groups: list[FilamentGroup],
              nozzles: list[NozzleTelemetry] | None = None) -> Telemetry:
    return Telemetry(
        state=PrinterState.PRINTING, progress=progress, remaining_minutes=remaining,
        nozzle=nozzle, nozzle_target=nozzle_target, bed=bed, bed_target=bed_target,
        chamber=chamber, current_layer=layer, total_layers=layers, job_name=job,
        filament_groups=groups,
        nozzles=nozzles or [NozzleTelemetry(position="single", current=nozzle, target=nozzle_target)],
    )


def preview_data() -> tuple[list[Printer], dict[str, Telemetry]]:
    printers = [
        Printer(serial="X1", name="X1", host="192.168.1.31", kind=PrinterKind.BAMBU),
        Printer(serial="P2S", name="P2S", host="192.168.1.32", kind=PrinterKind.BAMBU),
        Printer(serial="P1S", name="P1S", host="192.168.1.33", kind=PrinterKind.BAMBU),
        Printer(serial="MINI", name="MINI", host="192.168.1.34", kind=PrinterKind.PRUSA),
        Printer(serial="X2D", name="X2D", host="192.168.1.35", kind=PrinterKind.BAMBU),
    ]
    x1_ams = group("x1-ams", "AMS A", [
        slot("A1"), slot("A2"), slot("A3"),
        slot("A4", "PETG", "1D1F22FF", 8, True, 80),
    ], humidity=20, temperature=49)
    p2s_ht = group("p2s-ht", "AMS HT", [slot("A1", "PETG", "222326FF", 0, True)],
                   humidity=36, temperature=30)
    p1s_ht = group("p1s-ht", "AMS HT", [slot("A1", "PETG", "202124FF", 36, True, 360)],
                   humidity=42, temperature=33)
    x2d_ams = group("x2d-ams", "AMS A", [
        slot("A1", "PLA", "6E5D68FF", 2, True, 20), slot("A2"), slot("A3"),
        slot("A4", "PLA", "168ED1FF", 56, True, 560),
    ], humidity=22, temperature=39)
    ext_tpu = group("x1-ext", "EXT", [slot("EXT", "TPU", "40572EFF", 100, True, 1000)], external=True)
    ext_petg = group("p2s-ext", "EXT", [slot("EXT", "PETG", "A6A8ADFF", 100, True, 1000)], external=True)
    ext_pla = group("x2d-ext", "EXT 2", [slot("EXT 2", "PLA", "F2F2F2FF", 100, True, 1000)], external=True)

    values = {
        "X1": telemetry(progress=70, remaining=44, nozzle=255, nozzle_target=255, bed=65,
                        bed_target=65, chamber=51, layer=120, layers=276,
                        job="ADAPTER-PVC110-SPIRO100", groups=[x1_ams, ext_tpu]),
        "P2S": telemetry(progress=67, remaining=44, nozzle=250, nozzle_target=250, bed=70,
                         bed_target=70, chamber=52, layer=95, layers=226,
                         job="zero clearance dewalt 7492", groups=[p2s_ht, ext_petg]),
        "P1S": telemetry(progress=38, remaining=97, nozzle=256, nozzle_target=255, bed=65,
                         bed_target=65, chamber=None, layer=28, layers=110,
                         job="set print", groups=[p1s_ht]),
        "MINI": Telemetry(state=PrinterState.OFFLINE),
        "X2D": telemetry(
            progress=46, remaining=154, nozzle=220, nozzle_target=220, bed=46, bed_target=46,
            chamber=41, layer=25, layers=115, job="magnetic_x2d", groups=[x2d_ams, ext_pla],
            nozzles=[NozzleTelemetry(position="left", current=220, target=220),
                     NozzleTelemetry(position="right", current=47, target=40)],
        ),
    }
    return printers, values


def main(out_path: str) -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(gapp.css_for("dark", 0.82))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    printers, values = preview_data()
    app = StubApp(printers, values)
    window = gapp.Dashboard(app)
    app.window = window
    placements = place_cards([printer.serial for printer in printers], values, 2)
    for printer, placement in zip(printers, placements):
        card = gapp.PrinterCard(app, printer)
        app.cards[printer.serial] = card
        window.grid.attach(card, placement.column, placement.row, placement.span, 1)
        card.update(values[printer.serial])
    window.update_header()
    window.grid.show_all()
    window.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration()
    # GTK only knows the fleet's natural height after the first allocation. Re-apply the same
    # production sizing rule now, otherwise a headless backend may keep its 150 px bootstrap size.
    window.resize_for_content()
    while Gtk.events_pending():
        Gtk.main_iteration()

    width, height = window.get_size()
    pixbuf = Gdk.pixbuf_get_from_window(window.get_window(), 0, 0, width, height)
    if pixbuf is None:
        raise RuntimeError("GTK did not expose a drawable window")
    pixbuf.savev(out_path, "png", [], [])
    print("rendered", out_path, pixbuf.get_width(), "x", pixbuf.get_height())
    window.destroy()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "preview.png")
