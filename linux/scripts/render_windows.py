#!/usr/bin/env python3
"""Render the complete GTK windows used by Gantry to a directory of PNG files."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402

from gantry import app as gapp  # noqa: E402
from gantry.core import FilamentGroup  # noqa: E402
from gantry.spoolassign import open_assign_dialog  # noqa: E402
from gantry.spoolbase import Filament, SpoolbaseWindow  # noqa: E402
from gantry.layout import place_cards  # noqa: E402
from render_preview import StubApp, preview_data  # noqa: E402


class PreviewFilamentStore:
    def __init__(self) -> None:
        self.on_change = None
        self.filaments = [
            Filament("Bambu Lab", "Basic", "PLA", "Jade White", "F4F4EF", id="pla-white", spoolCount=4),
            Filament("Bambu Lab", "Matte", "PLA", "Charcoal", "303235", id="pla-charcoal", spoolCount=1),
            Filament("Fiberlogy", "Easy PLA", "PLA", "Pastel Blue", "5A9CCA", id="pla-blue", spoolCount=2),
            Filament("Bambu Lab", "HF", "PETG", "Black", "151719", id="petg-black", spoolCount=3),
            Filament("Spectrum", "PET-G Premium", "PETG", "Lime Green", "78B94B", id="petg-green", spoolCount=1),
            Filament("Fiberlogy", "FiberFlex 40D", "TPU", "Orange", "E87235", id="tpu-orange", spoolCount=1),
            Filament("Bambu Lab", "Support for PLA", "Support", "Natural", "E1D6BF", id="support", spoolCount=0),
        ]

    def adjust(self, filament_id: str, delta: int) -> None:
        for filament in self.filaments:
            if filament.id == filament_id:
                filament.spoolCount = max(0, filament.spoolCount + delta)
        if callable(self.on_change):
            self.on_change()


class PreviewPhysicalStore:
    def __init__(self) -> None:
        self.spools = [
            {
                "id": "SP-00012", "filamentDefinitionID": "petg-black",
                "nominalWeightGrams": 1000.0, "remainingWeightGrams": 360.0,
                "status": "active",
                "location": {"printerSerial": "P1S", "feeder": "ams", "amsIndex": 0, "slot": 0},
            },
            {
                "id": "SP-00017", "filamentDefinitionID": "pla-blue",
                "nominalWeightGrams": 1000.0, "remainingWeightGrams": 820.0,
                "status": "stored", "location": {},
            },
            {
                "id": "SP-00021", "filamentDefinitionID": "tpu-orange",
                "nominalWeightGrams": 1000.0, "remainingWeightGrams": 540.0,
                "status": "active",
                "location": {"printerSerial": "X1", "feeder": "ext", "amsIndex": 1, "slot": 0},
            },
        ]

    @staticmethod
    def _same_slot(left: dict[str, Any], right: dict[str, Any]) -> bool:
        return all(left.get(key) == right.get(key) for key in ("printerSerial", "feeder", "amsIndex", "slot"))

    def spool_at(self, location: dict[str, Any]) -> dict[str, Any] | None:
        return next((spool for spool in self.spools
                     if self._same_slot(spool.get("location", {}), location)), None)

    @staticmethod
    def percent(spool: dict[str, Any]) -> int:
        nominal = float(spool.get("nominalWeightGrams", 0) or 0)
        return int(round(float(spool.get("remainingWeightGrams", 0) or 0) / nominal * 100)) if nominal else 0

    def set_remaining(self, *args): pass
    def clear_slot(self, *args): pass
    def assign(self, *args): pass
    def create_spool(self, *args): pass


def settle(window: Gtk.Window, size: tuple[int, int] | None = None) -> None:
    window.show_all()
    while Gtk.events_pending():
        Gtk.main_iteration()
    if size is not None:
        window.resize(*size)
        while Gtk.events_pending():
            Gtk.main_iteration()


def capture(window: Gtk.Window, path: Path, size: tuple[int, int] | None = None) -> None:
    settle(window, size)
    width, height = window.get_size()
    pixbuf = Gdk.pixbuf_get_from_window(window.get_window(), 0, 0, width, height)
    if pixbuf is None:
        raise RuntimeError(f"GTK did not expose a drawable window for {path.name}")
    pixbuf.savev(str(path), "png", [], [])
    print("rendered", path, pixbuf.get_width(), "x", pixbuf.get_height())


def dashboard(app: StubApp) -> gapp.Dashboard:
    window = gapp.Dashboard(app)
    app.window = window
    placements = place_cards([printer.serial for printer in app.printers], app.telemetry, 2)
    for printer, placement in zip(app.printers, placements):
        card = gapp.PrinterCard(app, printer)
        app.cards[printer.serial] = card
        window.grid.attach(card, placement.column, placement.row, placement.span, 1)
        card.update(app.telemetry[printer.serial])
    window.update_header()
    window.grid.show_all()
    return window


def main(out_dir: str) -> None:
    target = Path(out_dir)
    target.mkdir(parents=True, exist_ok=True)

    settings = Gtk.Settings.get_default()
    settings.set_property("gtk-application-prefer-dark-theme", True)
    provider = Gtk.CssProvider()
    provider.load_from_data(gapp.css_for("dark", 0.82))
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

    printers, telemetry = preview_data()
    app = StubApp(printers, telemetry)
    app.filament_store = PreviewFilamentStore()
    app.physical_spools = PreviewPhysicalStore()
    app.config.data.update({
        "stock_red_max": 1,
        "stock_blue_max": 5,
        "panel_transparency": "low",
        "notify_finished": True,
        "notify_error": True,
        "notify_paused": True,
        "notify_low_filament": True,
        "notify_humidity": True,
        "notify_offline": False,
        "quiet_hours_enabled": True,
        "quiet_hours_start": "22:00",
        "quiet_hours_end": "07:00",
        "allow_script_actions": False,
        "web_dashboard_enabled": True,
        "developer_mode": False,
    })

    main_window = dashboard(app)
    # The production tray popover is intentionally non-resizable. The renderer needs one complete
    # review viewport, so lift only that host-window constraint; the dashboard widgets stay intact.
    main_window.set_resizable(True)
    main_window.set_size_request(750, 780)
    capture(main_window, target / "01-dashboard.png", (750, 780))

    settings_window = gapp.SettingsDialog(app)
    # One shot per tab; the window carries three pages instead of one long scrolling column.
    for index, (name, filename) in enumerate((("general", "02-settings.png"),
                                              ("appearance", "02b-settings-appearance.png"),
                                              ("advanced", "02c-settings-advanced.png"))):
        settings_window.stack.set_visible_child_name(name)
        while Gtk.events_pending():
            Gtk.main_iteration()
        capture(settings_window, target / filename, (640, 720))
    settings_window.destroy()

    spoolbase = SpoolbaseWindow(app)
    capture(spoolbase, target / "03-spoolbase.png", (500, 640))
    spoolbase.destroy()

    p1s_groups = app.telemetry["P1S"].filament_groups
    group: FilamentGroup = p1s_groups[0]
    open_assign_dialog(app, "P1S", group, 0, group.slots[0], 0)
    while Gtk.events_pending():
        Gtk.main_iteration()
    assign = next(
        (window for window in Gtk.Window.list_toplevels()
         if isinstance(window, Gtk.Dialog) and window.get_title() == "Przypisz rolkę"),
        None,
    )
    if assign is None:
        raise RuntimeError("assign dialog did not open")
    capture(assign, target / "04-assign-filament.png")
    assign.destroy()
    main_window.destroy()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "renders")
