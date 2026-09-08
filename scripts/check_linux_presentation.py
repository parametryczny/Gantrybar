#!/usr/bin/env python3
"""GTK presentation smoke test. In-memory fixtures only: no credentials, transports or user defaults.

Run with PYTHONPATH=linux python3 scripts/check_linux_presentation.py (or xvfb-run on Linux).
"""
import time
import tempfile
from pathlib import Path
from types import SimpleNamespace
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk
from gantry.app import Gantry
from gantry.dashboard import Dashboard, PrinterCard, css_for
from gantry.core import Printer, PrinterState, Telemetry, FilamentGroup, FilamentSlot
from gantry.insights import PrinterInsights
from gantry.storage import DEFAULTS
from gantry.startup import StartupState
from gantry import i18n


def pump():
    end = time.monotonic() + .25
    while time.monotonic() < end:
        while Gtk.events_pending(): Gtk.main_iteration_do(False)
        time.sleep(.01)


app = Gantry.__new__(Gantry)
app.config = SimpleNamespace(data=dict(DEFAULTS), save=lambda: None)
app.config.data.update({"floating-window-enabled": True, "gantry.onboarding.v1.seen": False})
app.language = "pl"
i18n.set_language(app.language)
app.printers = [Printer(serial=str(i), name=f"TEST {i}", host="127.0.0.1", model="X1C") for i in range(5)]
app.telemetry = {p.serial: Telemetry() for p in app.printers}
app.startup = StartupState([p.serial for p in app.printers])
app.indicator_available = True
app.expanded_compact_serial = None
app.cards = {}
app.insights = PrinterInsights(app)
app.temp_history = {}
app.detail_window = None
app.connection_reasons = {}
app.window = Dashboard(app)
provider = Gtk.CssProvider(); provider.load_from_data(css_for("dark"))
Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
app.rebuild_cards(); app.window.show_all(); pump()
assert app.window._startup_layer.get_visible()
assert not app.cards, "Initial offline placeholders must not appear"
assert app.window.get_decorated() and app.window.get_resizable()

for printer in app.printers[:3]:
    app.telemetry[printer.serial] = Telemetry(state=PrinterState.PRINTING, progress=47, job_name="TEST ONLY",
        nozzle=220, nozzle_target=220, bed=60, bed_target=60, chamber=34,
        filament_groups=[FilamentGroup("ams", "ams", "AMS A", 4, humidity=32, slots=[
            FilamentSlot(str(i), f"A{i+1}", "PLA" if i == 0 else None, "8E8E93", 47 if i == 0 else None)
            for i in range(4)])])
    app.startup.report(printer.serial)
app.rebuild_cards(); pump()
assert len(app.cards) == 3 and not app.window._startup_layer.get_visible()
card = app.cards["0"]
assert len(card.temps.get_children()) == 3, "Nozzle, bed and chamber must share the temperature row"
normal_height = card.get_allocated_height()
error_telemetry = app.telemetry["0"]
error_telemetry.state = PrinterState.ERROR
error_telemetry.error_code = 7
card.update(error_telemetry); pump()
assert card.print_error.get_visible() and card.ams.get_opacity() == 0.0
assert card.get_allocated_height() == normal_height, "Error must replace AMS without changing card height"
error_telemetry.state = PrinterState.PRINTING
error_telemetry.error_code = 0
card.update(error_telemetry); pump()
assert not card.print_error.get_visible() and card.ams.get_opacity() == 1.0
assert app.window._panel_layer is not None and app.config.data["gantry.onboarding.v1.seen"], "Automatic guide not claimed"
app.window.show_onboarding(); pump()
assert app.window._panel_layer is not None
def descendants(widget):
    yield widget
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children(): yield from descendants(child)
assert any(isinstance(w, PrinterCard) for w in descendants(app.window._panel_layer)), "Guide must use real card class"
assert not any(w.get_can_focus() for w in descendants(next(w for w in descendants(app.window._panel_layer) if isinstance(w, PrinterCard))))
for width, height in ((1200, 750), (560, 400), (380, 300), (750, 650)):
    app.window.resize(width, height); pump()
    scroll = next(w for w in descendants(app.window._panel_layer) if isinstance(w, Gtk.ScrolledWindow))
    assert scroll.get_allocated_width() <= 462
    assert scroll.get_allocated_height() <= app.window.get_size()[1] - 40, (width, height, app.window.get_size(), scroll.get_allocated_height(), scroll.get_size_request(), app.window.window_overlay.get_allocated_height())
shot = Gdk.pixbuf_get_from_window(app.window.get_window(), 0, 0, *app.window.get_size())
if shot: shot.savev(str(Path(tempfile.gettempdir()) / "gantry-gtk-guide.png"), "png", [], [])
app.window.close_panel(); pump()
app.window.show_maintenance(app.printers[0], app.telemetry["0"]); pump()
assert app.window._panel_layer is not None
app.window.close_panel()
app.open_fleet_stats(); pump()
assert app.window._panel_layer is not None
app.window.close_panel()
app.open_diagnostics(); pump()
assert app.window._panel_layer is not None
app.window.close_panel()
app.window._hide(); pump()
assert app.config.data["floating-window-enabled"] and not app.window.tray_mode
app.show(); pump()
assert app.window._panel_layer is None, "Guide must not repeat when reopening"
app.config.data["floating-window-enabled"] = False
app.window.apply_window_mode(); pump()
assert app.window.tray_mode and not app.window.get_decorated()
app.window.show_onboarding(); pump()
assert app.window._panel_layer is not None
app.window.destroy()
print("GTK presentation OK — launch, production-card guide, bounded panels, resize and persistent window mode")
