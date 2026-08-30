from __future__ import annotations

import argparse
import subprocess
import threading
from datetime import datetime, timedelta
from pathlib import Path

import gi

# Ubuntu 26.04 ships both GTK 3 and GTK 4 typelibs.  Importing Gdk from the
# combined gi.repository statement before its version is pinned lets PyGObject
# select Gdk 4, after which loading Gtk 3 fails with "Gdk 4.0 is already
# loaded".  Pin every namespace used by the GTK 3 UI before the first
# gi.repository import so import order cannot change the selected ABI.
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # type: ignore # noqa: E402
except (ValueError, ImportError):
    AppIndicator = None

from . import __version__
from .core import Printer, PrinterKind, PrinterState, Telemetry, expand_scan_targets
from .csvimport import parse_printer_csv
from .discovery import scan
from .desktop import installed_slicers, open_desktop_app
from .http_clients import HttpConnection
from .mqtt import MqttConnection
from .storage import Config, SecretStore, SecretStoreError, autostart_enabled, set_autostart
from .studio import devices as studio_devices


TEXT = {
    "pl": {
        "printers": "drukarek", "online": "online", "collapse": "Zwiń", "expand": "Rozwiń",
        "add": "Dodaj drukarkę", "scan": "Skanuj sieć", "settings": "Ustawienia",
        "quit": "Zakończ", "close": "Zamknij", "save": "Zapisz", "cancel": "Anuluj",
        "edit": "Edytuj drukarkę", "remove": "Usuń drukarkę", "import": "Importuj z Bambu Studio",
        "name": "Nazwa", "host": "Adres IP / host", "serial": "Numer seryjny",
        "code": "Kod dostępu / klucz API", "port": "Port", "found": "Wykryte drukarki",
        "kind": "Typ drukarki", "api_optional": "Klucz API (opcjonalny)",
        "searching": "Szukam drukarek…", "none": "Nie znaleziono drukarek",
        "language": "Język", "theme": "Wygląd", "dark": "Ciemny", "light": "Jasny",
        "targets": "Dodatkowe adresy VPN", "targets_hint": "IP, zakres a-b lub CIDR /n (maks. 1024 adresy)",
        "autostart": "Uruchamiaj po zalogowaniu", "notifications": "Powiadomienia",
        "finished_notice": "Zakończenie druku", "error_notice": "Błędy drukarki",
        "paused_notice": "Wstrzymanie druku", "low_notice": "Niski poziom filamentu",
        "humidity_notice": "Wysoka wilgotność AMS", "quiet": "Godziny ciszy",
        "offline_notice": "Utrata połączenia", "printing": "Drukowanie", "ready": "Gotowa",
        "paused": "Wstrzymana", "finished": "Zakończono", "error": "Błąd", "offline": "Offline",
        "invalid": "Sprawdź wymagane pola i zakres portu.", "secret_error": "Nie udało się zapisać kodu w systemowym pęku kluczy.",
        "studio_missing": "Nie znaleziono konfiguracji Bambu Studio albo zapisanych drukarek.",
        "certificate": "Certyfikat drukarki zmienił się. Połączenie zostało zablokowane.",
        "rejected": "Drukarka odrzuciła kod dostępu.", "version": "Wersja",
        "import_consent": "Pozwól odczytać konfigurację Bambu Studio",
        "import_hint": "Przyspiesza dodawanie, ale odczytuje lokalny plik slicera z kodami dostępu. Nic nie jest czytane, dopóki tego nie zaznaczysz.",
    },
    "en": {
        "printers": "printers", "online": "online", "collapse": "Collapse", "expand": "Expand",
        "add": "Add printer", "scan": "Scan network", "settings": "Settings",
        "quit": "Quit", "close": "Close", "save": "Save", "cancel": "Cancel",
        "edit": "Edit printer", "remove": "Remove printer", "import": "Import from Bambu Studio",
        "name": "Name", "host": "IP address / host", "serial": "Serial number",
        "code": "Access code / API key", "port": "Port", "found": "Discovered printers",
        "kind": "Printer type", "api_optional": "API key (optional)",
        "searching": "Scanning for printers…", "none": "No printers found",
        "language": "Language", "theme": "Appearance", "dark": "Dark", "light": "Light",
        "targets": "Additional VPN targets", "targets_hint": "IP, a-b range or CIDR /n (up to 1024 addresses)",
        "autostart": "Start after login", "notifications": "Notifications",
        "finished_notice": "Print finished", "error_notice": "Printer errors",
        "paused_notice": "Print paused", "low_notice": "Low filament",
        "humidity_notice": "High AMS humidity", "quiet": "Quiet hours",
        "offline_notice": "Connection lost", "printing": "Printing", "ready": "Ready",
        "paused": "Paused", "finished": "Finished", "error": "Error", "offline": "Offline",
        "invalid": "Check the required fields and port range.", "secret_error": "Could not store the code in the system keyring.",
        "studio_missing": "Bambu Studio configuration or stored printers were not found.",
        "certificate": "The printer certificate changed. The connection was blocked.",
        "rejected": "The printer rejected the access code.", "version": "Version",
        "import_consent": "Allow reading the Bambu Studio configuration",
        "import_hint": "Speeds up adding, but reads the local slicer file containing access codes. Nothing is read until you tick this.",
    },
}

STAGES = {
    1: ("Poziomowanie stołu", "Auto bed leveling"), 2: ("Nagrzewanie stołu", "Heating bed"),
    3: ("Kalibracja drgań", "Vibration calibration"), 4: ("Zmiana filamentu", "Changing filament"),
    7: ("Nagrzewanie dyszy", "Heating nozzle"), 8: ("Kalibracja ekstruzji", "Calibrating extrusion"),
    13: ("Bazowanie", "Homing"), 14: ("Czyszczenie dyszy", "Cleaning nozzle"),
    22: ("Wyładowanie filamentu", "Unloading filament"), 24: ("Ładowanie filamentu", "Loading filament"),
    49: ("Nagrzewanie komory", "Heating chamber"), 77: ("Przygotowanie AMS", "Preparing AMS"),
}


def quiet_hours_active(config: Config, now: datetime | None = None) -> bool:
    if not config.data.get("quiet_hours_enabled", True): return False
    current = (now or datetime.now()).strftime("%H:%M")
    start = str(config.data.get("quiet_hours_start", "22:00"))
    end = str(config.data.get("quiet_hours_end", "07:00"))
    return start <= current < end if start < end else current >= start or current < end

def css_for(theme: str, window_alpha: float = 1.0) -> bytes:
    if theme == "light":
        colors = ("#f2f2f7", "#1c1c1e", "#ffffff", "#d1d1d6", "#636366", "#f2f2f7", "#c7c7cc")
    else:
        # Matched 1:1 to the macOS design tokens (GantryTheme.swift): canvas / text / card / line /
        # secondary / progress-trough / job-name.
        colors = ("#0c0d0e", "#f2f3f1", "#151719", "#2a2c2e", "#a7aaa6", "#33363a", "#9da09c")
    background, foreground, card, border, secondary, trough, job = colors
    # Only the window backdrop gets the transparency; cards keep their solid background so their
    # text stays readable at every level (matches the macOS/Windows behaviour).
    return ("""
window { background: %(background)s; color: %(foreground)s; }
window.popover-window { background-color: alpha(%(background)s, %(walpha).2f); border: 1px solid %(border)s; border-radius: 14px; }
.popover-window .header { padding: 12px 16px 8px; }
.header { padding: 12px 16px 8px; }
.title { font-size: 18px; font-weight: 700; }
.subtitle { color: %(secondary)s; font-size: 11px; }
.card { background: %(card)s; border: 1px solid alpha(#ffffff, 0.08); border-radius: 16px; padding: 9px; }
.card.printing { background-color: %(card)s; background-image: radial-gradient(farthest-side at left top, alpha(#ff6857, 0.22), alpha(#ff6857, 0.08) 42%%, alpha(#ff6857, 0.00) 82%%); border-color: alpha(#ff6857, 0.24); }
.printer-icon { color: %(secondary)s; margin-right: 2px; }
.printer-name { font-size: 13px; font-weight: 600; }
.connection { color: %(secondary)s; border: 1px solid alpha(#ffffff, 0.12); border-radius: 6px; padding: 2px 6px; font-family: monospace; font-size: 9px; font-weight: 600; }
.job-surface { background: alpha(#ffffff, 0.052); border: 1px solid alpha(#ffffff, 0.09); border-radius: 10px; padding: 5px 7px 6px; }
.card-notice { background: alpha(#ff6857, 0.16); border: 1px solid alpha(#ff6857, 0.34); border-radius: 9px; padding: 5px 6px 5px 9px; }
.card-notice label { color: #f0d9d5; font-size: 10px; }
.card-notice-ok { color: #ff8a7c; font-weight: 700; font-size: 10px; padding: 1px 8px; }
.detail-body { padding: 10px 12px 14px; }
.detail-body .status { font-size: 12px; }
.job { color: %(job)s; font-weight: 600; font-size: 10px; }
.meta { color: %(secondary)s; font-size: 11px; }
.status { color: #d4d7d3; font-weight: 700; font-size: 10px; }
.card.printing .status, .card.printing .percent { color: #ff6857; }
.percent { color: #d4d7d3; font-size: 22px; font-weight: 600; }
.eta { color: #d4d7d3; border: 1px solid alpha(#ffffff, 0.10); border-radius: 8px; padding: 3px 7px; font-family: monospace; font-size: 10px; font-weight: 600; }
.temp-bento { background: alpha(#ffffff, 0.052); border: 1px solid alpha(#ffffff, 0.09); border-radius: 10px; }
.temp-zone { padding: 3px 7px 4px; border-left: 1px solid alpha(#ffffff, 0.09); }
.temp-zone:first-child { border-left: none; }
.temp-name { color: %(secondary)s; font-family: monospace; font-size: 7px; font-weight: 600; }
/* Temperature value colour follows activity, like macOS: heating warm, cooling cool, at-temp/idle grey. */
.temp-value { color: %(secondary)s; font-family: monospace; font-size: 14px; font-weight: 600; }
.temp-value.heat { color: #d18c82; }
.temp-value.cool { color: #8ca8c7; }
.ams { border-radius: 9px; border: 1px solid alpha(#ffffff, 0.10); }
.ams.active { border: 2px solid #ffffff; box-shadow: 0 0 0 1px alpha(#000000, 0.5); }
.ams-group { background: alpha(#ffffff, 0.052); border-radius: 12px; padding: 9px 11px; }
button { border-radius: 10px; padding: 7px 12px; }
button.cardmenu { background: alpha(#ffffff, 0.08); border: none; box-shadow: none; padding: 0; min-width: 26px; min-height: 24px; border-radius: 12px; color: %(secondary)s; font-size: 15px; }
entry { padding: 8px; border-radius: 8px; }
progressbar trough { min-height: 7px; border-radius: 5px; background: %(trough)s; }
progressbar progress { border-radius: 2px; background: #ff6857; }
.sb-tile { border-radius: 11px; padding: 6px 8px; }
.sb-tile:hover { background: alpha(#ffffff, 0.08); }
.sb-color { font-size: 11px; font-weight: 600; }
.sb-product { font-size: 8px; color: %(secondary)s; }
.sb-type { font-size: 13px; font-weight: 600; }
.sb-count { font-size: 10px; color: %(secondary)s; }
.sb-badge { border-radius: 8px; padding: 1px 7px; font-size: 10px; font-weight: 600; }
.sb-badge.zero { background: alpha(#9a9a9e, 0.18); color: %(secondary)s; }
.sb-badge.red { background: alpha(#ff453a, 0.20); color: #ff6a5f; }
.sb-badge.blue { background: alpha(#0a84ff, 0.20); color: #4aa8ff; }
.sb-badge.green { background: alpha(#30d158, 0.20); color: #4ae37a; }
.sb-swatch { border-radius: 15px; border: 1px solid alpha(#ffffff, 0.25); }
.sb-empty { color: %(secondary)s; font-size: 12px; font-weight: 600; }
""" % {"background": background, "foreground": foreground, "card": card, "border": border,
         "secondary": secondary, "trough": trough, "job": job, "walpha": window_alpha}).encode()


def _draw_glyph(widget: Gtk.Widget, cr: object, kind: str) -> bool:
    """Draw a small monochrome icon with Cairo (chart / layers / reorder grip) so it never depends on
    font glyphs. Some fonts lack the block/geometric characters and render them as tofu boxes."""
    alloc = widget.get_allocation()
    w, h = alloc.width, alloc.height
    style = widget.get_style_context()
    rgba = style.get_color(style.get_state())
    cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, rgba.alpha)
    cr.set_line_width(1.4)
    cr.set_line_cap(1)   # round
    cr.set_line_join(1)  # round
    if kind == "chart":
        pad = 1.5
        pts = [(pad, h - pad - 1), (w * 0.34, h * 0.46), (w * 0.6, h * 0.6), (w - pad, pad + 1)]
        cr.move_to(*pts[0])
        for p in pts[1:]:
            cr.line_to(*p)
        cr.stroke()
    elif kind == "layers":
        for y in (h * 0.28, h * 0.52, h * 0.76):
            cr.move_to(1, y)
            cr.line_to(w - 1, y)
        cr.stroke()
    elif kind == "grip":
        cx = w / 2
        cr.move_to(cx - 3, h * 0.40); cr.line_to(cx, h * 0.28); cr.line_to(cx + 3, h * 0.40)  # ^
        cr.move_to(cx - 3, h * 0.60); cr.line_to(cx, h * 0.72); cr.line_to(cx + 3, h * 0.60)  # v
        cr.stroke()
    return False


def _icon(kind: str, width: int, height: int, css: str = "meta") -> Gtk.DrawingArea:
    area = Gtk.DrawingArea()
    area.set_size_request(width, height)
    area.get_style_context().add_class(css)
    area.connect("draw", lambda widget, cr: _draw_glyph(widget, cr, kind))
    return area


class PrinterCard(Gtk.Frame):
    def __init__(self, app: "Gantry", printer: Printer) -> None:
        super().__init__()
        # A GtkFrame draws its own etched, square border by default — kill it so only the rounded
        # CSS card border shows (otherwise a hard white rectangle boxes every card).
        self.set_shadow_type(Gtk.ShadowType.NONE)
        self.set_label(None)
        self.app, self.printer = app, printer
        self.get_style_context().add_class("card")
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        self.add(self.box)
        # Small on-card notice (e.g. a Spoolbase roll auto-detached when an NFC spool was inserted).
        self.notice = Gtk.Box(spacing=8)
        self.notice.get_style_context().add_class("card-notice")
        self.notice_label = Gtk.Label(xalign=0, wrap=True)
        self._notice_ok = Gtk.Button(label="OK")
        self._notice_ok.set_relief(Gtk.ReliefStyle.NONE)
        self._notice_ok.get_style_context().add_class("card-notice-ok")
        self._notice_ok.connect("clicked", lambda _b: self.notice.hide())
        self.notice.pack_start(self.notice_label, True, True, 0)
        self.notice.pack_start(self._notice_ok, False, False, 0)
        self.notice.set_no_show_all(True)
        self.box.pack_start(self.notice, False, False, 0)
        self.job_surface = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        self.job_surface.get_style_context().add_class("job-surface")
        self.box.pack_start(self.job_surface, False, False, 0)
        # Header: name + drag handle (chevrons, like macOS) + menu. The whole card is the drag source.
        top = Gtk.Box(spacing=6)
        icon = Gtk.Image.new_from_icon_name("printer-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
        icon.get_style_context().add_class("printer-icon")
        self.name = Gtk.Label(label=printer.name, xalign=0)
        self.name.get_style_context().add_class("printer-name")
        connection_text = {PrinterKind.BAMBU: "MQTT", PrinterKind.KLIPPER: "KLIPPER",
                           PrinterKind.PRUSA: "PRUSALINK", PrinterKind.SNAPMAKER: "HTTP"}[printer.kind]
        self.connection = Gtk.Label(label=connection_text)
        self.connection.get_style_context().add_class("connection")
        top.pack_start(icon, False, False, 0)
        drag = _icon("grip", 12, 18)
        drag.set_tooltip_text("Przeciągnij w górę/dół, aby zmienić kolejność drukarek"
                              if self.app.language == "pl" else "Drag up/down to reorder printers")
        chart = Gtk.Button(); chart.set_relief(Gtk.ReliefStyle.NONE); chart.get_style_context().add_class("cardmenu")
        chart.add(_icon("chart", 18, 13, css="cardmenu"))
        chart.set_tooltip_text("Szczegóły" if self.app.language == "pl" else "Details")
        chart.connect("clicked", lambda *_: self.app.open_details(self.printer.serial))
        menu = Gtk.Button(label="⋯"); menu.set_relief(Gtk.ReliefStyle.NONE); menu.get_style_context().add_class("cardmenu")
        menu.connect("clicked", self._show_menu)
        top.pack_start(self.name, True, True, 0)
        top.pack_start(self.connection, False, False, 0)
        top.pack_start(drag, False, False, 0)
        top.pack_start(chart, False, False, 0)
        top.pack_start(menu, False, False, 0)
        self.job_surface.pack_start(top, False, False, 0)
        # Status line carries the state on the left and time + layers on the right (macOS layout).
        self.status_row = Gtk.Box(spacing=8)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        self.progress_meta = Gtk.Label(xalign=1)
        self.progress_meta.get_style_context().add_class("meta")
        self.job = Gtk.Label(label="—", xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.job.get_style_context().add_class("job")
        self.status_row.pack_start(self.status, False, False, 0)
        self.status_row.pack_start(Gtk.Label(label="·"), False, False, 0)
        self.status_row.pack_start(self.job, True, True, 0)
        meta_box = Gtk.Box(spacing=4)
        meta_box.pack_start(_icon("layers", 12, 11), False, False, 0)
        meta_box.pack_start(self.progress_meta, False, False, 0)
        self.status_row.pack_start(meta_box, False, False, 0)
        self.job_surface.pack_start(self.status_row, False, False, 0)
        progress_row = Gtk.Box(spacing=7)
        self.progress = Gtk.ProgressBar(show_text=False)
        self.percent = Gtk.Label(label="0%")
        self.percent.get_style_context().add_class("percent")
        self.eta = Gtk.Label(label="—")
        self.eta.get_style_context().add_class("eta")
        progress_row.pack_start(self.percent, False, False, 0)
        progress_row.pack_start(self.eta, False, False, 0)
        self.job_surface.pack_start(progress_row, False, False, 0)
        self.job_surface.pack_start(self.progress, False, False, 0)
        # Temperatures on their own row, coloured by activity (heating red / cooling blue).
        self.temps = Gtk.Box(spacing=0, homogeneous=True)
        self.temps.get_style_context().add_class("temp-bento")
        self.box.pack_start(self.temps, False, False, 0)
        self.ams = Gtk.Box(spacing=6)
        self.box.pack_start(self.ams, False, False, 0)
        target = Gtk.TargetEntry.new("application/x-gantry-printer", Gtk.TargetFlags.SAME_APP, 0)
        self.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [target], Gdk.DragAction.MOVE)
        self.drag_dest_set(Gtk.DestDefaults.ALL, [target], Gdk.DragAction.MOVE)
        self.connect("drag-data-get", self._drag_data_get)
        self.connect("drag-data-received", self._drag_data_received)
        self.update(Telemetry())

    def _show_menu(self, button: Gtk.Button) -> None:
        menu = Gtk.Menu()
        details = Gtk.MenuItem(label="Szczegóły" if self.app.language == "pl" else "Details")
        details.connect("activate", lambda *_: self.app.open_details(self.printer.serial))
        menu.append(details)
        autos = Gtk.MenuItem(label="Automatyzacje" if self.app.language == "pl" else "Automations")
        autos.connect("activate", lambda *_: self.app.open_automations(self.printer.serial))
        menu.append(autos)
        if self.printer.kind in (PrinterKind.BAMBU, PrinterKind.KLIPPER):
            cam = Gtk.MenuItem(label="Kamera na żywo" if self.app.language == "pl" else "Live camera")
            cam.connect("activate", lambda *_: self.app.open_camera(self.printer.serial))
            menu.append(cam)
        menu.append(Gtk.SeparatorMenuItem())
        slicers = installed_slicers()
        bambu_studio = next((slicer for slicer in slicers if slicer.name == "Bambu Studio"), None)
        if self.printer.kind == PrinterKind.BAMBU and bambu_studio:
            camera = Gtk.MenuItem(label="Kamera w Bambu Studio" if self.app.language == "pl" else "Camera in Bambu Studio")
            camera.connect("activate", lambda *_: open_desktop_app(bambu_studio))
            menu.append(camera)
        for slicer in slicers:
            label = f"Otwórz w {slicer.name}" if self.app.language == "pl" else f"Open in {slicer.name}"
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda *_, value=slicer: open_desktop_app(value))
            menu.append(item)
        if slicers:
            menu.append(Gtk.SeparatorMenuItem())
        edit = Gtk.MenuItem(label=self.app.text["edit"])
        edit.connect("activate", lambda *_: self.app.open_printer_dialog(self.printer))
        menu.append(edit)
        remove = Gtk.MenuItem(label=self.app.text["remove"])
        remove.connect("activate", lambda *_: self.app.remove_printer(self.printer))
        menu.append(remove)
        menu.show_all()
        # Keep the popover panel open while its own card menu is up.
        window = getattr(self.app, "window", None)
        if window is not None:
            window._suppress_hide = True
            menu.connect("deactivate", lambda *_: setattr(window, "_suppress_hide", False))
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_EAST, Gdk.Gravity.NORTH_EAST, None)

    def _drag_data_get(self, _widget: Gtk.Widget, _context: Gdk.DragContext,
                       selection: Gtk.SelectionData, _info: int, _time: int) -> None:
        selection.set_text(self.printer.serial, -1)

    def _drag_data_received(self, _widget: Gtk.Widget, context: Gdk.DragContext, _x: int, _y: int,
                            selection: Gtk.SelectionData, _info: int, timestamp: int) -> None:
        source = selection.get_text() or ""
        if source and source != self.printer.serial:
            self.app.move_printer(source, self.printer.serial)
        Gtk.drag_finish(context, True, True, timestamp)

    def set_compact(self, compact: bool, expanded: bool = False) -> None:
        hidden = compact and not expanded
        for widget in (self.status_row, self.percent.get_parent(), self.progress, self.temps, self.ams):
            widget.set_no_show_all(hidden)
            widget.set_visible(not hidden)
        if compact:
            self.connect("button-release-event", self._toggle_compact_card)

    def _toggle_compact_card(self, _widget: Gtk.Widget, event: Gdk.EventButton) -> bool:
        if event.button == 1:
            self.app.toggle_compact_printer(self.printer.serial)
            return True
        return False

    def update(self, telemetry: Telemetry, reason: str | None = None) -> None:
        labels = self.app.text
        state_key = telemetry.state.value
        status = labels.get(state_key, state_key)
        if telemetry.stage in STAGES and telemetry.state in {PrinterState.PRINTING, PrinterState.PAUSED}:
            status = STAGES[telemetry.stage][0 if self.app.language == "pl" else 1]
        if reason:
            if "certificate-changed" in reason:
                status = labels["certificate"]
            elif "access-code-rejected" in reason:
                status = labels["rejected"]
        self.status.set_text(status)
        context = self.status.get_style_context()
        card_context = self.get_style_context()
        for name in ("printing", "finished", "error"):
            context.remove_class(name)
            card_context.remove_class(name)
        if telemetry.state == PrinterState.PRINTING:
            card_context.add_class("printing")
        # Only a running/paused print has a job to show; finished/idle still echoes the last file name,
        # so treat those as "no active job" (matches macOS/Windows).
        has_active_job = telemetry.state in {PrinterState.PRINTING, PrinterState.PAUSED} and bool(telemetry.job_name)
        self.job.set_text(telemetry.job_name if has_active_job else "—")
        self.progress.set_fraction(telemetry.progress / 100)
        self.percent.set_text(f"{telemetry.progress}%")
        if telemetry.remaining_minutes:
            mins = telemetry.remaining_minutes
            # Remaining time + estimated finish clock ("33m · 14:32"); now + remaining stays stable
            # as the printer counts the remaining minutes down.
            finish = (datetime.now() + timedelta(minutes=mins)).strftime("%H:%M")
            eta = f"{mins // 60}h {mins % 60}m · {finish}" if mins >= 60 else f"{mins}m · {finish}"
        else:
            eta = "—"
        layers = "—" if telemetry.current_layer is None else f"{telemetry.current_layer}/{telemetry.total_layers or '—'}"
        self.eta.set_text(f"ETA {eta}")
        self.progress_meta.set_text(layers)

        pl = self.app.language == "pl"

        def fmt(cur: float | None, tgt: float | None) -> str:
            if cur is None:
                return "—"
            return f"{cur:.0f}/{tgt:.0f}°" if tgt else f"{cur:.0f}°"

        def temp_zone(label: str, cur: float | None, tgt: float | None) -> Gtk.Widget:
            zone = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            zone.get_style_context().add_class("temp-zone")
            name = Gtk.Label(label=label.upper(), xalign=0)
            name.get_style_context().add_class("temp-name")
            value = Gtk.Label(label=fmt(cur, tgt), xalign=0.5)
            vctx = value.get_style_context()
            vctx.add_class("temp-value")
            # Colour by activity (matches macOS tempColor): heating warm, cooling cool, else grey.
            target = tgt or 0
            if cur is not None and target > 5 and cur < target - 3:
                vctx.add_class("heat")
            elif cur is not None and cur > max(target, 0) + 5 and cur > 30:
                vctx.add_class("cool")
            zone.pack_start(name, False, False, 0)
            zone.pack_start(value, False, False, 0)
            return zone

        # Nozzle(s) with explicit L/P (pl) or L/R (en) for dual-nozzle printers, plus chamber when real.
        nozzles = telemetry.nozzles
        dual = any(n.position == "right" for n in nozzles)
        for child in self.temps.get_children():
            self.temps.remove(child)
        zones: list[Gtk.Widget] = []
        if dual:
            left = next((n for n in nozzles if n.position == "left"), nozzles[0])
            right = next((n for n in nozzles if n.position == "right"), None)
            zones.append(temp_zone("Dysze P" if pl else "Nozzles R", right.current if right else None, right.target if right else None))
            zones.append(temp_zone("L", left.current, left.target))
        else:
            cur = nozzles[0].current if nozzles else telemetry.nozzle
            tgt = nozzles[0].target if nozzles else telemetry.nozzle_target
            zones.append(temp_zone("Dysza" if pl else "Nozzle", cur, tgt))
        zones.append(temp_zone("Stół" if pl else "Bed", telemetry.bed, telemetry.bed_target))
        zones.append(temp_zone("Komora" if pl else "Chamber", telemetry.chamber, None))
        for zone in zones:
            self.temps.pack_start(zone, True, True, 0)
        self.temps.show_all()

        # Physical filament modules as side-by-side groups (name + per-module humidity/temp, then slots).
        for child in self.ams.get_children():
            self.ams.remove(child)
        spoolbase_on = bool(self.app.config.data.get("spoolbase_enabled", True))
        store = getattr(self.app, "physical_spools", None) if spoolbase_on else None
        for group_index, group in enumerate(telemetry.filament_groups):
            gbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            gbox.get_style_context().add_class("ams-group")
            env: list[str] = []
            if group.humidity is not None:
                env.append(f"{group.humidity}/5" if group.humidity <= 5 else f"{group.humidity}%")
            if group.temperature is not None:
                env.append(f"{group.temperature:.0f}°")
            header = Gtk.Label(xalign=0)
            suffix = f"  <span alpha='60%'>{GLib.markup_escape_text(' · '.join(env))}</span>" if env else ""
            header.set_markup(f"<b>{GLib.markup_escape_text(group.display_name)}</b>{suffix}")
            gbox.pack_start(header, False, False, 0)
            srow = Gtk.Box(spacing=4)
            for slot_index, slot in enumerate(group.slots):
                # A manually-assigned Spoolbase roll fills in colour/grams for a slot the printer cannot
                # read itself (chipless spool), matching macOS/Windows.
                assigned = None
                if store is not None:
                    from .physicalspool import location_for
                    assigned = store.spool_at(location_for(self.printer.serial, group.external, group_index, slot_index))
                assigned_def = None
                if assigned is not None and getattr(self.app, "filament_store", None) is not None:
                    assigned_def = next((f for f in self.app.filament_store.filaments
                                         if f.id == assigned.get("filamentDefinitionID")), None)
                sbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
                swatch = Gtk.Label(label="")
                swatch.set_size_request(56, 38)
                ctx = swatch.get_style_context()
                ctx.add_class("ams")
                if slot.active:
                    ctx.add_class("active")
                present = slot.present or assigned is not None
                color = (slot.color or "8E8E93FF").lstrip("#")[:6] if slot.present else "5A5A5E"
                if not slot.present and assigned_def is not None:
                    color = assigned_def.colorHex
                # Set the colour through a per-widget CSS provider rather than the deprecated
                # override_background_color(), which paints a flat fill over the CSS border and hides
                # the white ring on the active slot.
                try:
                    provider = Gtk.CssProvider()
                    provider.load_from_data((".ams { background-color: #%s; }" % color).encode())
                    ctx.add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
                except Exception:
                    pass
                # Low-filament marker (red corner dot) — only when the level is trustworthy. External
                # spools and chipless AMS spools both report remain=0 as "unknown", so warn only for a
                # real RFID/NFC tag (weight known), never a chipless spool (issue #27).
                trusted_level = slot.remaining_weight_g is not None
                low = present and not group.external and trusted_level and (slot.remaining if slot.remaining is not None else 100) <= 15
                if low:
                    overlay = Gtk.Overlay()
                    overlay.add(swatch)
                    dot = Gtk.Label(label="")
                    dot.set_size_request(7, 7)
                    dot.set_halign(Gtk.Align.END)
                    dot.set_valign(Gtk.Align.START)
                    dot.set_margin_top(3)
                    dot.set_margin_end(3)
                    dctx = dot.get_style_context()
                    dctx.add_class("lowdot")
                    try:
                        dp = Gtk.CssProvider()
                        dp.load_from_data(b".lowdot { background-color: #ff3b30; border-radius: 4px; border: 1px solid #202020; }")
                        dctx.add_provider(dp, Gtk.STYLE_PROVIDER_PRIORITY_USER)
                    except Exception:
                        pass
                    overlay.add_overlay(dot)
                    swatch_widget: Gtk.Widget = overlay
                else:
                    swatch_widget = swatch
                caption = Gtk.Label(xalign=0.5)
                caption.get_style_context().add_class("meta")
                caption.set_markup(f"<b>{GLib.markup_escape_text(slot.label)}</b>" if slot.active else GLib.markup_escape_text(slot.label))
                sbox.pack_start(swatch_widget, False, False, 0)
                sbox.pack_start(caption, False, False, 0)
                # Grams on the spool: the AMS NFC/RFID tag, or a manually-assigned Spoolbase roll.
                grams_value = slot.remaining_weight_g
                if grams_value is None and assigned is not None:
                    grams_value = assigned.get("remainingWeightGrams")
                if grams_value and self.app.config.data.get("card_show_spool_grams"):
                    grams = Gtk.Label(xalign=0.5)
                    grams.get_style_context().add_class("meta")
                    grams.set_text(f"{int(grams_value)} g")
                    sbox.pack_start(grams, False, False, 0)
                # Click a slot to assign / edit / detach its physical roll (Spoolbase only).
                if store is not None:
                    event_box = Gtk.EventBox()
                    event_box.add(sbox)
                    event_box.connect("button-press-event",
                                      lambda _w, _e, g=group, gi=group_index, s=slot, si=slot_index:
                                      self._open_slot_assign(g, gi, s, si))
                    srow.pack_start(event_box, False, False, 0)
                else:
                    srow.pack_start(sbox, False, False, 0)
            gbox.pack_start(srow, False, False, 0)
            self.ams.pack_start(gbox, False, False, 0)
        self.ams.show_all()

    def show_notice(self, text: str) -> None:
        self.notice_label.set_text(text)
        self.notice.show()
        self.notice_label.show()
        self._notice_ok.show()

    def _open_slot_assign(self, group: Any, group_index: int, slot: Any, slot_index: int) -> bool:
        try:
            from .spoolassign import open_assign_dialog
            open_assign_dialog(self.app, self.printer.serial, group, group_index, slot, slot_index)
        except Exception:
            pass
        return True


class Dashboard(Gtk.Window):
    def __init__(self, app: "Gantry") -> None:
        super().__init__()
        self.app = app
        self._just_shown = False
        self._suppress_hide = False
        # Use an RGBA visual (before realize) so a translucent panel background can show the desktop
        # when the transparency setting is medium/high. Harmless when the background is opaque.
        _rgba = self.get_screen().get_rgba_visual()
        if _rgba is not None:
            self.set_visual(_rgba)
        # With a system tray, behave like the macOS menu-bar popover: a borderless panel with no
        # taskbar entry that drops near the tray and closes when you click elsewhere. Without a tray
        # (no AppIndicator) fall back to a normal titled window so it stays reachable.
        self.tray_mode = AppIndicator is not None
        self.set_title("Gantry")
        if self.tray_mode:
            self.set_default_size(840, 640)
            self.set_decorated(False)
            self.set_skip_taskbar_hint(True)
            self.set_skip_pager_hint(True)
            self.set_resizable(False)
            self.set_keep_above(True)
            try:
                self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
            except Exception:
                pass
            self.get_style_context().add_class("popover-window")
            self.connect("focus-out-event", self._on_focus_out)
            # Request a compositor blur behind the popover once it has a native window, and again each
            # time it is shown (a compositor can drop the property when the surface changes). Best-effort:
            # real blur only happens on KDE/KWin X11; elsewhere the RGBA transparency alone remains.
            self._backdrop_mode = "transparency"
            self.connect("realize", lambda *_: self._apply_backdrop())
            self.connect("map", lambda *_: self._apply_backdrop())
        else:
            self.set_title("Gantry")
            self.set_default_size(840, 720)
            self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._hide)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)
        header = Gtk.Box(spacing=10)
        header.get_style_context().add_class("header")
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        title = Gtk.Label(label="GANTRY", xalign=0); title.get_style_context().add_class("title")
        self.subtitle = Gtk.Label(xalign=0); self.subtitle.get_style_context().add_class("subtitle")
        titles.pack_start(title, False, False, 0); titles.pack_start(self.subtitle, False, False, 0)
        self.collapse = Gtk.Button(); self.collapse.connect("clicked", self._toggle)
        refresh = Gtk.Button(label="↻"); refresh.connect("clicked", lambda _b: app.reconnect_all())
        add = Gtk.Button(label="＋"); add.connect("clicked", lambda _b: app.open_printer_dialog())
        header.pack_start(titles, True, True, 0)
        header.pack_start(self.collapse, False, False, 0); header.pack_start(refresh, False, False, 0); header.pack_start(add, False, False, 0)
        root.pack_start(header, False, False, 0)
        scroll = Gtk.ScrolledWindow(); scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.grid = Gtk.Grid(column_spacing=10, row_spacing=10, margin=12)
        scroll.add(self.grid); root.pack_start(scroll, True, True, 0)
        # Light, unobtrusive tagline under the cards (matches the macOS panel).
        footer = Gtk.Label(
            label=("Drukuj spokojnie — wszystko pod kontrolą" if app.language == "pl"
                   else "Print in peace — everything under control"))
        footer.get_style_context().add_class("subtitle")
        footer.set_margin_top(2); footer.set_margin_bottom(8)
        root.pack_start(footer, False, False, 0)

    def _apply_backdrop(self, *_args: object) -> None:
        # Ask the compositor to blur behind the popover (KDE/KWin X11). Safe no-op everywhere else, so
        # the RGBA-translucent background stays intact. Never raises.
        try:
            from .backdrop import apply_backdrop
            self._backdrop_mode = apply_backdrop(self)
        except Exception:
            self._backdrop_mode = "transparency"

    def _hide(self, *_args: object) -> bool:
        self.hide(); return True

    def _on_focus_out(self, *_args: object) -> bool:
        # Close on click-away, like a popover — but not right after opening, and not while a child
        # dialog (Add printer / Settings) has taken focus.
        if not self._just_shown and not self._suppress_hide:
            self.hide()
        return False

    def position_top_right(self) -> None:
        display = Gdk.Display.get_default()
        if display is None:
            return
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return
        geometry = monitor.get_geometry()
        width, height = self.get_size()
        self.move(geometry.x + geometry.width - width - 10, geometry.y + 10)

    def _toggle(self, _button: Gtk.Button) -> None:
        self.app.config.data["collapsed"] = not self.app.is_compact()
        self.app.config.data["collapsed_chosen"] = True
        self.app.expanded_compact_serial = None
        self.app.config.save(); self.app.rebuild_cards()

    def update_header(self) -> None:
        online = sum(1 for value in self.app.telemetry.values() if value.state != PrinterState.OFFLINE)
        self.subtitle.set_text(f"{len(self.app.printers)} {self.app.text['printers']} • {online} {self.app.text['online']}")
        self.collapse.set_label(self.app.text["expand"] if self.app.is_compact() else self.app.text["collapse"])
        self.collapse.set_visible(len(self.app.printers) >= 4)


class PrinterDialog(Gtk.Dialog):
    def __init__(self, app: "Gantry", printer: Printer | None = None) -> None:
        super().__init__(title=app.text["edit"] if printer else app.text["add"], transient_for=app.window, modal=True)
        self.app, self.printer = app, printer
        self.add_button(app.text["cancel"], Gtk.ResponseType.CANCEL)
        if printer:
            self.add_button(app.text["remove"], Gtk.ResponseType.REJECT)
        self.add_button(app.text["save"], Gtk.ResponseType.OK)
        self.set_default_size(590, 620)
        box = self.get_content_area(); box.set_spacing(10); box.set_border_width(18)

        box.pack_start(Gtk.Label(label=app.text["kind"], xalign=0), False, False, 0)
        self.kind = Gtk.ComboBoxText()
        for value, label in (("bambu", "Bambu Lab"), ("klipper", "Klipper / Moonraker"),
                             ("prusa", "Prusa / PrusaLink"), ("snapmaker", "Snapmaker")):
            self.kind.append(value, label)
        self.kind.set_active_id((printer.kind if printer else PrinterKind.BAMBU).value)
        self.kind.connect("changed", lambda _combo: self._apply_kind())
        box.pack_start(self.kind, False, False, 0)
        csv_button = Gtk.Button(label="Importuj wiele drukarek z CSV" if app.language == "pl" else "Import multiple printers from CSV")
        csv_button.connect("clicked", lambda _button: app.import_csv_on_screen(self))
        box.pack_start(csv_button, False, False, 0)

        self.bambu_section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.combo = Gtk.ComboBoxText(); self.combo.append("manual", app.text["searching"]); self.combo.set_active(0)
        self.combo.connect("changed", self._selected)
        self.bambu_section.pack_start(Gtk.Label(label=app.text["found"], xalign=0), False, False, 0)
        self.bambu_section.pack_start(self.combo, False, False, 0)
        self.targets = Gtk.Entry(text=str(app.config.data.get("scan_targets", "")))
        self.targets.set_placeholder_text("100.71.10.5")
        self.bambu_section.pack_start(Gtk.Label(label=app.text["targets"], xalign=0), False, False, 0)
        self.bambu_section.pack_start(self.targets, False, False, 0)
        hint = Gtk.Label(label=app.text["targets_hint"], xalign=0); hint.get_style_context().add_class("meta")
        self.bambu_section.pack_start(hint, False, False, 0)
        # Reading the slicer config is opt-in: it holds access codes, so gate the import button on consent.
        self.import_consent = Gtk.CheckButton(label=app.text["import_consent"])
        import_hint = Gtk.Label(label=app.text["import_hint"], xalign=0, wrap=True); import_hint.get_style_context().add_class("meta")
        self.bambu_section.pack_start(self.import_consent, False, False, 0)
        self.bambu_section.pack_start(import_hint, False, False, 0)
        buttons = Gtk.Box(spacing=8)
        rescan = Gtk.Button(label=app.text["scan"]); rescan.connect("clicked", lambda _b: self.start_scan())
        self.import_button = Gtk.Button(label=app.text["import"]); self.import_button.connect("clicked", lambda _b: self._import())
        self.import_button.set_sensitive(False)
        self.import_consent.connect("toggled", lambda cb: self.import_button.set_sensitive(cb.get_active()))
        buttons.pack_start(rescan, False, False, 0); buttons.pack_start(self.import_button, False, False, 0)
        self.bambu_section.pack_start(buttons, False, False, 0)
        box.pack_start(self.bambu_section, False, False, 0)

        self.fields: dict[str, Gtk.Entry] = {}
        self.rows: dict[str, Gtk.Box] = {}
        defaults = {"name": printer.name if printer else "", "host": printer.host if printer else "",
                    "serial": printer.serial if printer and printer.kind == PrinterKind.BAMBU else "",
                    "code": "", "port": str(printer.port if printer else 8883)}
        for key in ("name", "host", "serial", "code", "port"):
            row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            label = Gtk.Label(label=app.text[key], xalign=0); row.pack_start(label, False, False, 0)
            entry = Gtk.Entry(text=defaults[key]); entry.set_visibility(key != "code")
            if key == "serial" and printer and printer.kind == PrinterKind.BAMBU: entry.set_sensitive(False)
            self.fields[key] = entry; self.rows[key] = row; row.pack_start(entry, False, False, 0)
        # Host takes the width; the short Port sits beside it instead of on its own full-width row.
        self.fields["port"].set_width_chars(6)
        host_port = Gtk.Box(spacing=10)
        host_port.pack_start(self.rows["host"], True, True, 0)
        host_port.pack_start(self.rows["port"], False, False, 0)
        box.pack_start(self.rows["name"], False, False, 0)
        box.pack_start(host_port, False, False, 0)
        box.pack_start(self.rows["serial"], False, False, 0)
        box.pack_start(self.rows["code"], False, False, 0)
        self.code_label = self.rows["code"].get_children()[0]
        self.info = Gtk.Label(xalign=0, wrap=True); self.info.get_style_context().add_class("meta")
        box.pack_start(self.info, False, False, 0)
        self.error = Gtk.Label(xalign=0, wrap=True); self.error.get_style_context().add_class("status")
        box.pack_start(self.error, False, False, 0)
        self.discovered: list[Printer] = []
        self.show_all(); self._apply_kind()
        if not printer: self.start_scan()

    @property
    def selected_kind(self) -> PrinterKind:
        try: return PrinterKind(self.kind.get_active_id() or "bambu")
        except ValueError: return PrinterKind.BAMBU

    def _apply_kind(self) -> None:
        kind = self.selected_kind
        self.bambu_section.set_visible(kind == PrinterKind.BAMBU)
        self.rows["serial"].set_visible(kind == PrinterKind.BAMBU)
        # Snapmaker authorizes via the printer's touchscreen — no access code / API key field.
        self.rows["code"].set_visible(kind != PrinterKind.SNAPMAKER)
        defaults = {PrinterKind.BAMBU: 8883, PrinterKind.KLIPPER: 7125,
                    PrinterKind.PRUSA: 80, PrinterKind.SNAPMAKER: 8080}
        if not self.printer or self.printer.kind != kind:
            self.fields["port"].set_text(str(defaults[kind]))
        if kind == PrinterKind.BAMBU:
            self.code_label.set_text(self.app.text["code"].split(" /")[0])
            self.info.set_text("MQTT/TLS • port 8883. Dodatkowy adres VPN wpisz wyżej i przeskanuj ponownie.")
        elif kind == PrinterKind.KLIPPER:
            self.code_label.set_text(self.app.text["api_optional"])
            self.info.set_text("Moonraker • port 7125. Happy Hare MMU i Creality CFS są wykrywane automatycznie.")
        elif kind == PrinterKind.PRUSA:
            self.code_label.set_text("Klucz API PrusaLink")
            self.info.set_text("PrusaLink • port 80 • połączenie lokalne, bez konta Prusy.")
        else:
            self.info.set_text(
                "Snapmaker 2.0 / Artisan • HTTP, port 8080. Po dodaniu NA EKRANIE DRUKARKI pojawi się "
                "prośba o zgodę — dotknij „Zezwól” (Allow). Autoryzację trzeba powtórzyć po każdym "
                "wyłączeniu drukarki."
                if self.app.language == "pl" else
                "Snapmaker 2.0 / Artisan • HTTP, port 8080. After adding, the PRINTER SCREEN shows a "
                "permission request — tap “Allow” to authorize. Re-authorize after each power cycle.")

    def start_scan(self) -> None:
        if self.selected_kind != PrinterKind.BAMBU: return
        try:
            expand_scan_targets(self.targets.get_text())
        except ValueError:
            self.error.set_text(self.app.text["invalid"]); return
        targets = self.targets.get_text().strip()
        self.app.config.data["scan_targets"] = targets; self.app.config.save()
        self.combo.remove_all(); self.combo.append("manual", self.app.text["searching"]); self.combo.set_active(0)
        def work() -> None:
            values = scan(targets)
            GLib.idle_add(self._scan_done, values)
        threading.Thread(target=work, daemon=True).start()

    def _scan_done(self, values: list[Printer]) -> bool:
        self.discovered = values; self.combo.remove_all(); self.combo.append("manual", self.app.text["none"] if not values else "—")
        for value in values: self.combo.append(value.serial, f"{value.name} — {value.host}")
        untouched = not any(self.fields[key].get_text().strip() for key in ("name", "host", "serial"))
        self.combo.set_active(1 if values and untouched else 0); return False

    def _selected(self, combo: Gtk.ComboBoxText) -> None:
        serial = combo.get_active_id()
        value = next((item for item in self.discovered if item.serial == serial), None)
        if value:
            self.fields["name"].set_text(value.name); self.fields["host"].set_text(value.host)
            self.fields["serial"].set_text(value.serial); self.fields["port"].set_text(str(value.port))

    def _import(self) -> None:
        # Defensive: never read the slicer config without explicit consent.
        if not self.import_consent.get_active():
            return
        try:
            values = studio_devices()
        except Exception:
            self.error.set_text(self.app.text["studio_missing"]); return
        imported = 0
        for serial, code, host in values:
            if not host: continue
            printer = Printer(serial=serial, name=f"Bambu {serial[-4:]}", host=host)
            try: self.app.secrets.set(serial, code)
            except SecretStoreError: continue
            self.app.upsert_printer(printer); imported += 1
        if imported:
            self.destroy(); self.app.reconnect_all()
        else: self.error.set_text(self.app.text["studio_missing"])

    def value(self) -> tuple[Printer, str] | None:
        values = {key: field.get_text().strip() for key, field in self.fields.items()}
        kind = self.selected_kind
        try: port = int(values["port"])
        except ValueError: port = 0
        serial = values["serial"] if kind == PrinterKind.BAMBU else f"{kind.value}-{values['host']}-{port}"
        secret_required = kind in {PrinterKind.BAMBU, PrinterKind.PRUSA}
        if not values["name"] or not values["host"] or not serial or not 1 <= port <= 65535 or (secret_required and not values["code"] and not self.printer):
            self.error.set_text(self.app.text["invalid"]); return None
        model = {PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper",
                 PrinterKind.PRUSA: "Prusa", PrinterKind.SNAPMAKER: "Snapmaker"}[kind]
        return Printer(serial, values["name"], values["host"], model=model, port=port, kind=kind), values["code"]


class SettingsDialog(Gtk.Dialog):
    def __init__(self, app: "Gantry") -> None:
        super().__init__(title=app.text["settings"], transient_for=app.window, modal=True)
        self.app = app; self.add_button(app.text["cancel"], Gtk.ResponseType.CANCEL); self.add_button(app.text["save"], Gtk.ResponseType.OK)
        self.set_default_size(520, 420)
        box = self.get_content_area(); box.set_spacing(12); box.set_border_width(20)
        self.language = Gtk.ComboBoxText(); self.language.append("pl", "Polski"); self.language.append("en", "English"); self.language.set_active_id(app.language)
        self.theme = Gtk.ComboBoxText(); self.theme.append("dark", app.text["dark"]); self.theme.append("light", app.text["light"]); self.theme.set_active_id(str(app.config.data.get("theme", "dark")))
        _pl = app.language == "pl"
        self.transparency = Gtk.ComboBoxText()
        self.transparency.append("low", "Niska" if _pl else "Low")
        self.transparency.append("medium", "Średnia" if _pl else "Medium")
        self.transparency.append("high", "Wysoka" if _pl else "High")
        self.transparency.set_active_id(str(app.config.data.get("panel_transparency", "low")))
        _transparency_label = "Przezroczystość" if _pl else "Transparency"
        for label, widget in ((app.text["language"], self.language), (app.text["theme"], self.theme),
                              (_transparency_label, self.transparency)):
            box.pack_start(Gtk.Label(label=label, xalign=0), False, False, 0); box.pack_start(widget, False, False, 0)
        self.autostart = Gtk.CheckButton(label=app.text["autostart"]); self.autostart.set_active(autostart_enabled()); box.pack_start(self.autostart, False, False, 0)
        self.spoolbase = Gtk.CheckButton(label="Spoolbase — magazyn filamentów" if app.language == "pl" else "Spoolbase — filament stock")
        self.spoolbase.set_active(bool(app.config.data.get("spoolbase_enabled", True)))
        box.pack_start(self.spoolbase, False, False, 0)
        self.spool_grams = Gtk.CheckButton(label="Gramy na rolce (AMS NFC / Spoolbase)" if app.language == "pl" else "Grams on spool (AMS NFC / Spoolbase)")
        self.spool_grams.set_active(bool(app.config.data.get("card_show_spool_grams", False)))
        box.pack_start(self.spool_grams, False, False, 0)
        # Security: allow automations whose action runs code (raw command / shell script). Off by default.
        self.allow_scripts = Gtk.CheckButton(label="Zezwól automatyzacjom na komendy i skrypty" if _pl else "Allow command and script automations")
        self.allow_scripts.set_active(bool(app.config.data.get("allow_script_actions", False)))
        box.pack_start(self.allow_scripts, False, False, 0)
        # Web dashboard (LAN) + sync between the user's own computers.
        self.web_dashboard = Gtk.CheckButton(label="Serwer podglądu w przeglądarce (sieć lokalna)" if _pl else "Web preview server (local network)")
        self.web_dashboard.set_active(bool(app.config.data.get("web_dashboard_enabled", True)))
        box.pack_start(self.web_dashboard, False, False, 0)
        from .webserver import local_ipv4
        _ip = local_ipv4()
        _addr = f"http://{_ip}:8787" if _ip else ("brak adresu IP" if _pl else "no IP address")
        _web_addr = Gtk.Label(label=_addr, xalign=0); _web_addr.get_style_context().add_class("meta"); box.pack_start(_web_addr, False, False, 0)
        _sync = getattr(app, "sync_service", None)
        if _sync is not None:
            box.pack_start(Gtk.Label(label=("Synchronizacja między komputerami" if _pl else "Sync between computers"), xalign=0), False, False, 0)
            self.sync_token = Gtk.Entry(text=_sync.token); box.pack_start(self.sync_token, False, False, 0)
            _peer_row = Gtk.Box(spacing=8)
            self.sync_peer = Gtk.Entry(); self.sync_peer.set_placeholder_text("adres drugiego komputera, np. 192.168.1.20" if _pl else "other computer address, e.g. 192.168.1.20")
            _add = Gtk.Button(label="Dodaj" if _pl else "Add"); _add.connect("clicked", lambda *_: (_sync.add_peer(self.sync_peer.get_text()), self.sync_peer.set_text("")))
            _peer_row.pack_start(self.sync_peer, True, True, 0); _peer_row.pack_start(_add, False, False, 0); box.pack_start(_peer_row, False, False, 0)
            _btn_row = Gtk.Box(spacing=8)
            _newtok = Gtk.Button(label="Nowy token" if _pl else "New token"); _newtok.connect("clicked", lambda *_: (_sync.regenerate_token(), self.sync_token.set_text(_sync.token)))
            _settok = Gtk.Button(label="Ustaw token" if _pl else "Set token"); _settok.connect("clicked", lambda *_: _sync.set_token(self.sync_token.get_text()))
            _syncnow = Gtk.Button(label="Synchronizuj teraz" if _pl else "Sync now"); _syncnow.connect("clicked", lambda *_: _sync.sync_now())
            _btn_row.pack_start(_newtok, False, False, 0); _btn_row.pack_start(_settok, False, False, 0); _btn_row.pack_start(_syncnow, False, False, 0); box.pack_start(_btn_row, False, False, 0)
            _peers = _sync.peers()
            _plist = (", ".join(p.get("address", "") for p in _peers)) if _peers else ("brak sparowanych" if _pl else "no paired computers")
            _peer_lbl = Gtk.Label(label=_plist, xalign=0); _peer_lbl.get_style_context().add_class("meta"); box.pack_start(_peer_lbl, False, False, 0)
        box.pack_start(Gtk.Label(label=app.text["notifications"], xalign=0), False, False, 0)
        self.notices: dict[str, Gtk.CheckButton] = {}
        for key, config_key in (("finished_notice", "notify_finished"), ("error_notice", "notify_error"),
                                ("paused_notice", "notify_paused"), ("low_notice", "notify_low_filament"),
                                ("humidity_notice", "notify_humidity"), ("offline_notice", "notify_offline")):
            check = Gtk.CheckButton(label=app.text[key]); check.set_active(bool(app.config.data.get(config_key))); self.notices[config_key] = check; box.pack_start(check, False, False, 0)
        self.quiet = Gtk.CheckButton(label=app.text["quiet"]); self.quiet.set_active(bool(app.config.data.get("quiet_hours_enabled", True)))
        box.pack_start(self.quiet, False, False, 0)
        quiet_row = Gtk.Box(spacing=8)
        self.quiet_start = Gtk.Entry(text=str(app.config.data.get("quiet_hours_start", "22:00")))
        self.quiet_end = Gtk.Entry(text=str(app.config.data.get("quiet_hours_end", "07:00")))
        quiet_row.pack_start(self.quiet_start, True, True, 0); quiet_row.pack_start(Gtk.Label(label="—"), False, False, 0); quiet_row.pack_start(self.quiet_end, True, True, 0)
        box.pack_start(quiet_row, False, False, 0)
        about = Gtk.Label(xalign=0)
        about.set_markup(f"Gantry • {app.text['version']} {__version__}\nKamil Grzegorczyk / parametryczny · <a href=\"https://suppi.pl/parametryczny\">suppi.pl</a>")
        about.get_style_context().add_class("meta"); box.pack_end(about, False, False, 0); self.show_all()

    def save(self) -> bool:
        try:
            datetime.strptime(self.quiet_start.get_text().strip(), "%H:%M")
            datetime.strptime(self.quiet_end.get_text().strip(), "%H:%M")
        except ValueError:
            return False
        self.app.config.data.update(language=self.language.get_active_id(), theme=self.theme.get_active_id(),
                                    panel_transparency=self.transparency.get_active_id() or "low")
        self.app.config.data.update(quiet_hours_enabled=self.quiet.get_active(),
                                    quiet_hours_start=self.quiet_start.get_text().strip(),
                                    quiet_hours_end=self.quiet_end.get_text().strip())
        for key, widget in self.notices.items(): self.app.config.data[key] = widget.get_active()
        self.app.config.data["spoolbase_enabled"] = self.spoolbase.get_active()
        self.app.config.data["card_show_spool_grams"] = self.spool_grams.get_active()
        self.app.config.data["allow_script_actions"] = self.allow_scripts.get_active()
        self.app.config.data["web_dashboard_enabled"] = self.web_dashboard.get_active()
        web_server = getattr(self.app, "web_server", None)
        if web_server is not None:
            web_server.start() if self.web_dashboard.get_active() else web_server.stop()
        self.app.config.save(); set_autostart(self.autostart.get_active())
        sync = getattr(self.app, "sync_service", None)
        if sync is not None:
            sync.note_settings_changed()
        return True


class Gantry:
    def __init__(self, background: bool = False) -> None:
        self.config, self.secrets = Config(), SecretStore()
        self.language = str(self.config.data.get("language", "pl")); self.text = TEXT.get(self.language, TEXT["pl"])
        self.printers = self.config.printers
        self.telemetry = {printer.serial: Telemetry() for printer in self.printers}
        self.connections: dict[str, MqttConnection | HttpConnection] = {}; self.cards: dict[str, PrinterCard] = {}
        # Rolling temperature history per printer (time, nozzle, bed, chamber), drawn by the Details graph.
        self.temp_history: dict[str, list[tuple[float, float | None, float | None, float | None]]] = {}
        self.detail_window: DetailWindow | None = None
        self.expanded_compact_serial: str | None = None
        self.window = Dashboard(self); self.apply_theme(); self.rebuild_cards(); self._tray()
        self.reconnect_all()
        # Read-only LAN web dashboard + two-way sync between the user's own computers.
        from .webserver import GantryWebServer
        from .sync import SyncService
        from .physicalspool import PhysicalSpoolStore
        from .spoolbase import FilamentStore
        self.physical_spools = PhysicalSpoolStore()
        self.filament_store = FilamentStore()   # shared inventory (also synced as the catalog)
        from .automation import AutomationEngine
        self.automations = AutomationEngine(self)
        self.sync_service = SyncService(self)
        self.web_server = GantryWebServer(self)
        self.web_server.sync = self.sync_service
        if bool(self.config.data.get("web_dashboard_enabled", True)):
            self.web_server.start()
        self.sync_service.sync_now()
        GLib.timeout_add_seconds(45, self._sync_tick)

    def _sync_tick(self) -> bool:
        try:
            self.sync_service.sync_now()
        except Exception:
            pass
        return True  # keep the periodic timer running
        # With a tray, start hidden like a menu-bar app — the panel opens from the tray. Without a
        # tray there is no other entry point, so show the (regular) window.
        if AppIndicator is None: self.window.show_all()

    def apply_theme(self) -> None:
        settings = Gtk.Settings.get_default(); settings.set_property("gtk-application-prefer-dark-theme", self.config.data.get("theme") == "dark")
        # Background-only alpha for the frosted-glass popover (cards stay solid). Lower = more see-through:
        # low is the most opaque glass, high shows the compositor blur most. Not a whole-window opacity.
        alpha = {"low": 0.82, "medium": 0.68, "high": 0.52}.get(str(self.config.data.get("panel_transparency", "low")), 0.82)
        # Give the panel window an RGBA visual so the translucent backdrop shows the desktop through
        # (needs a running compositor; falls back to opaque otherwise). Cards stay solid.
        window = getattr(self, "window", None)
        if window is not None and alpha < 1.0:
            rgba = window.get_screen().get_rgba_visual()
            if rgba is not None:
                window.set_visual(rgba)
        provider = Gtk.CssProvider(); provider.load_from_data(css_for(str(self.config.data.get("theme", "dark")), alpha)); Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def _tray(self) -> None:
        if getattr(self, "indicator", None) is not None:
            self.indicator.set_status(AppIndicator.IndicatorStatus.PASSIVE)
        menu = Gtk.Menu()
        panel_label = "Panel Gantry" if self.language == "pl" else "Gantry panel"
        for label, callback in ((panel_label, lambda *_: self.toggle_panel()), (self.text["scan"], lambda *_: self.scan_and_import()),
                                (self.text["add"], lambda *_: self.open_printer_dialog())):
            item = Gtk.MenuItem(label=label); item.connect("activate", callback); menu.append(item)
        if bool(self.config.data.get("spoolbase_enabled", True)):
            spoolbase_label = "Spoolbase — magazyn filamentów" if self.language == "pl" else "Spoolbase — filament stock"
            item = Gtk.MenuItem(label=spoolbase_label); item.connect("activate", lambda *_: self.toggle_spoolbase()); menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        quiet = Gtk.CheckMenuItem(label=self.text["quiet"]); quiet.set_active(bool(self.config.data.get("quiet_hours_enabled", True)))
        quiet.connect("toggled", lambda item: self._toggle_quiet(item.get_active())); menu.append(quiet)
        legend = Gtk.MenuItem(label="Legenda kolorów" if self.language == "pl" else "Color legend")
        legend_menu = Gtk.Menu()
        for label in (("Niebieski — drukowanie", "Blue — printing"), ("Zielony — zakończono", "Green — finished"),
                      ("Czerwony — błąd", "Red — error"), ("Szary — offline / bezczynna", "Gray — offline / idle")):
            item = Gtk.MenuItem(label=label[0 if self.language == "pl" else 1]); item.set_sensitive(False); legend_menu.append(item)
        legend_menu.append(Gtk.SeparatorMenuItem())
        slot_header = Gtk.MenuItem(label="Sloty filamentu:" if self.language == "pl" else "Filament slots:")
        slot_header.set_sensitive(False); legend_menu.append(slot_header)
        for label in (("Biały pierścień — aktywny slot", "White ring — active slot"),):
            item = Gtk.MenuItem(label=label[0 if self.language == "pl" else 1]); item.set_sensitive(False); legend_menu.append(item)
        legend.set_submenu(legend_menu); menu.append(legend)
        menu.append(Gtk.SeparatorMenuItem())
        for label, callback in ((self.text["settings"], lambda *_: self.open_settings()), (self.text["quit"], lambda *_: self.quit())):
            item = Gtk.MenuItem(label=label); item.connect("activate", callback); menu.append(item)
        menu.show_all()
        if AppIndicator:
            installed_icon = Path("/usr/share/icons/hicolor/scalable/apps/gantry.svg")
            local_icons = Path(__file__).resolve().parent.parent / "assets"
            icon = str(installed_icon) if installed_icon.exists() else str(local_icons / "gantry.svg")
            self.indicator = AppIndicator.Indicator.new("gantry", icon, AppIndicator.IndicatorCategory.APPLICATION_STATUS)
            self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE); self.indicator.set_menu(menu)

    def _toggle_quiet(self, enabled: bool) -> None:
        self.config.data["quiet_hours_enabled"] = enabled; self.config.save()

    def _record_temperature(self, serial: str, tel: Telemetry) -> None:
        if tel.nozzle is None and tel.bed is None and tel.chamber is None:
            return
        now = datetime.now().timestamp()
        history = self.temp_history.setdefault(serial, [])
        if history and now - history[-1][0] < 2:
            return
        history.append((now, tel.nozzle, tel.bed, tel.chamber))
        if len(history) > 240:
            del history[:len(history) - 240]

    def send_command(self, serial: str, json_str: str) -> bool:
        """Publish a raw MQTT command to a Bambu printer (chamber light, pause, custom)."""
        connection = self.connections.get(serial)
        sender = getattr(connection, "send_command", None)
        return bool(sender(json_str)) if callable(sender) else False

    def send_gcode(self, serial: str, script: str) -> bool:
        """Run a G-code line on a Klipper printer via Moonraker."""
        connection = self.connections.get(serial)
        sender = getattr(connection, "send_gcode", None)
        return bool(sender(script)) if callable(sender) else False

    def set_chamber_light(self, serial: str, on: bool) -> None:
        printer = next((p for p in self.printers if p.serial == serial), None)
        if printer is not None and printer.kind == PrinterKind.KLIPPER:
            self.send_gcode(serial, "SET_PIN PIN=caselight VALUE=1" if on else "SET_PIN PIN=caselight VALUE=0")
        else:
            from .automation import light_payload
            self.send_command(serial, light_payload(on))

    def confirm_code_action(self, rule: dict) -> bool:
        """One-time consent for a command/script automation, shown on the main thread. Returns the
        approval synchronously (the engine may call from a worker thread)."""
        from gi.repository import GLib
        result: dict[str, bool] = {}
        done = threading.Event()

        def ask() -> bool:
            pl = self.language == "pl"
            action = rule.get("action", {})
            is_script = action.get("type") == "script"
            preview = (action.get("text", "") or "").strip()[:700]
            what = ("skrypt na tym komputerze" if is_script else "komendę drukarki") if pl else \
                   ("a script on this computer" if is_script else "a printer command")
            body = (f"Automatyzacja „{rule.get('name')}” chce wykonać {what}:\n\n{preview}\n\nZezwolić i zapamiętać?"
                    if pl else
                    f"Automation \"{rule.get('name')}\" wants to run {what}:\n\n{preview}\n\nAllow and remember?")
            dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                       message_type=Gtk.MessageType.WARNING, buttons=Gtk.ButtonsType.NONE,
                                       text=("Potwierdź automatyzację" if pl else "Confirm automation"))
            dialog.format_secondary_text(body)
            dialog.add_button("Odmów" if pl else "Deny", Gtk.ResponseType.CANCEL)
            dialog.add_button("Zezwól" if pl else "Allow", Gtk.ResponseType.OK)
            approved = dialog.run() == Gtk.ResponseType.OK
            dialog.destroy()
            result["ok"] = approved
            done.set()
            return False

        GLib.idle_add(ask)
        done.wait(120)
        return result.get("ok", False)

    def open_camera(self, serial: str) -> None:
        from .camera import CameraWindow
        access = None
        printer = next((p for p in self.printers if p.serial == serial), None)
        if printer is not None and printer.kind == PrinterKind.BAMBU:
            try:
                access = self.secrets.get(serial)
            except Exception:
                access = None
        window = CameraWindow(self, serial, access)
        window.show_all()
        window.present()
        window.start()

    def open_automations(self, serial: str) -> None:
        from .automations import AutomationsWindow
        window = AutomationsWindow(self, serial)
        window.show_all()
        window.present()

    def open_details(self, serial: str) -> None:
        from .details import DetailWindow
        tel = self.telemetry.get(serial, Telemetry())
        if self.detail_window is not None:
            try:
                self.detail_window.destroy()
            except Exception:
                pass
            self.detail_window = None
        self.detail_window = DetailWindow(self, serial)
        self.detail_window.update(tel)
        self.detail_window.present_panel()

    def toggle_spoolbase(self) -> None:
        window = getattr(self, "spoolbase_window", None)
        if window is None:
            from .spoolbase import SpoolbaseWindow
            window = SpoolbaseWindow(self)
            self.spoolbase_window = window
        if window.get_visible():
            window.hide()
        else:
            window.present_panel()

    def show(self) -> None:
        self.window.show_all()
        if self.window.tray_mode:
            self.window.position_top_right()
        self.window.present()
        # Ignore the focus-out that can fire right as the popover appears.
        self.window._just_shown = True
        GLib.timeout_add(300, self._clear_just_shown)

    def _clear_just_shown(self) -> bool:
        self.window._just_shown = False
        return False

    def toggle_panel(self) -> None:
        if self.window.get_visible():
            self.window.hide()
        else:
            self.show()

    def rebuild_cards(self) -> None:
        for child in self.window.grid.get_children(): self.window.grid.remove(child)
        self.cards = {}
        compact = self.is_compact()
        columns = 1 if compact else 3
        row = 0
        column = 0
        for printer in self.printers:
            card = PrinterCard(self, printer)
            card.set_compact(compact, self.expanded_compact_serial == printer.serial)
            card.set_hexpand(True)
            card.set_vexpand(True)
            self.cards[printer.serial] = card
            telemetry = self.telemetry.get(printer.serial, Telemetry())
            span = 2 if not compact and self._needs_wide(telemetry) else 1
            if column + span > columns:
                row += 1
                column = 0
            self.window.grid.attach(card, column, row, span, 1)
            if printer.serial in self.telemetry: card.update(self.telemetry[printer.serial])
            column += span
            if column == columns:
                row += 1
                column = 0
        # Show the card widgets, but don't force the popover window open on every rebuild.
        self.window.update_header(); self.window.grid.show_all()

    @staticmethod
    def _needs_wide(telemetry: Telemetry) -> bool:
        dual_nozzle = any(nozzle.position == "right" for nozzle in telemetry.nozzles)
        ams_count = sum(1 for group in telemetry.filament_groups if not group.external)
        return dual_nozzle or ams_count >= 2

    def toggle_compact_printer(self, serial: str) -> None:
        if not self.is_compact():
            return
        self.expanded_compact_serial = None if self.expanded_compact_serial == serial else serial
        self.rebuild_cards()

    def is_compact(self) -> bool:
        selected = (bool(self.config.data.get("collapsed")) if self.config.data.get("collapsed_chosen")
                    else len(self.printers) > 8)
        return selected and len(self.printers) >= 4

    def upsert_printer(self, printer: Printer) -> None:
        index = next((i for i, value in enumerate(self.printers) if value.serial == printer.serial), None)
        if index is None: self.printers.append(printer)
        else: self.printers[index] = printer
        self.config.printers = self.printers; self.telemetry.setdefault(printer.serial, Telemetry()); self.rebuild_cards()

    def move_printer(self, source_serial: str, target_serial: str) -> None:
        if source_serial == target_serial: return
        source = next((printer for printer in self.printers if printer.serial == source_serial), None)
        if not source: return
        self.printers.remove(source)
        target_index = next((index for index, printer in enumerate(self.printers) if printer.serial == target_serial), len(self.printers))
        self.printers.insert(target_index, source)
        self.config.printers = self.printers; self.rebuild_cards()

    def open_printer_dialog(self, printer: Printer | None = None) -> None:
        dialog = PrinterDialog(self, printer)
        self.window._suppress_hide = True
        dialog.connect("destroy", lambda *_: setattr(self.window, "_suppress_hide", False))
        while True:
            response = dialog.run()
            if response == Gtk.ResponseType.CANCEL or response == Gtk.ResponseType.DELETE_EVENT: dialog.destroy(); return
            if response == Gtk.ResponseType.REJECT and printer:
                self.remove_printer(printer); dialog.destroy(); return
            value = dialog.value()
            if not value: continue
            updated, code = value
            try:
                try:
                    existing_code = self.secrets.get(printer.serial) if printer else None
                except SecretStoreError:
                    if updated.kind != PrinterKind.KLIPPER: raise
                    existing_code = None
                credential = code or existing_code
                if updated.kind in {PrinterKind.BAMBU, PrinterKind.PRUSA} and not credential:
                    dialog.error.set_text(self.text["code"]); continue
                if printer and printer.serial != updated.serial:
                    self.remove_printer(printer)
                if credential:
                    self.secrets.set(updated.serial, credential)
            except SecretStoreError:
                dialog.error.set_text(self.text["secret_error"]); continue
            self.upsert_printer(updated); dialog.destroy(); self.reconnect_all(); return

    def remove_printer(self, printer: Printer) -> None:
        connection = self.connections.pop(printer.serial, None)
        if connection: connection.stop()
        self.printers = [value for value in self.printers if value.serial != printer.serial]
        self.telemetry.pop(printer.serial, None)
        try: self.secrets.delete(printer.serial)
        except SecretStoreError: pass
        if printer.kind == PrinterKind.BAMBU: self.config.remove_pin(printer.serial)
        self.config.printers = self.printers; self.rebuild_cards()

    def reconnect_all(self) -> None:
        for connection in self.connections.values(): connection.stop()
        self.connections = {}
        for printer in self.printers:
            try: code = self.secrets.get(printer.serial)
            except SecretStoreError: code = None
            callback = lambda event, value, serial=printer.serial: GLib.idle_add(self.on_event, serial, event, value)
            if printer.kind == PrinterKind.BAMBU:
                if not code: continue
                connection = MqttConnection(printer, code, self.config, callback)
            elif printer.kind == PrinterKind.PRUSA:
                if not code: continue
                connection = HttpConnection(printer, code, callback)
            else:
                connection = HttpConnection(printer, code, callback)
            self.connections[printer.serial] = connection; connection.start()

    def on_event(self, serial: str, event: str, value: object | None) -> bool:
        previous = self.telemetry.get(serial, Telemetry())
        if event == "telemetry" and isinstance(value, Telemetry): self.telemetry[serial] = value
        elif event == "disconnected": self.telemetry[serial] = Telemetry(state=PrinterState.OFFLINE)
        current = self.telemetry[serial]
        if event == "telemetry":
            self._record_temperature(serial, current)
            if self.detail_window is not None and self.detail_window.serial == serial:
                self.detail_window.update(current)
            if getattr(self, "automations", None) is not None:
                self.automations.evaluate(serial, previous, current)
        # Inserting an RFID/NFC roll supersedes a stale manual Spoolbase assignment in that slot.
        if event == "telemetry" and getattr(self, "physical_spools", None) is not None:
            for spool_id, slot_label in self.physical_spools.detach_assignments_replaced_by_nfc(
                    serial, previous.filament_groups, current.filament_groups):
                name = next((p.name for p in self.printers if p.serial == serial), "Gantry")
                msg = (f"{spool_id} wróciła do magazynu (wykryto tag NFC w {slot_label})" if self.language == "pl"
                       else f"{spool_id} returned to storage (NFC tag in {slot_label})")
                self.notify(name, msg)
                card = self.cards.get(serial)
                if card is not None:
                    card.show_notice(msg)
        if self._needs_wide(previous) != self._needs_wide(current) and not self.is_compact():
            self.rebuild_cards()
        elif card := self.cards.get(serial):
            card.update(current, str(value) if event == "disconnected" else None)
        self.window.update_header()
        if quiet_hours_active(self.config): return False
        printer_name = next((p.name for p in self.printers if p.serial == serial), "Gantry")
        if current.state != previous.state:
            key = {PrinterState.FINISHED: "notify_finished", PrinterState.ERROR: "notify_error",
                   PrinterState.PAUSED: "notify_paused", PrinterState.OFFLINE: "notify_offline"}.get(current.state)
            if key and self.config.data.get(key): self.notify(printer_name, self.text[current.state.value])
            if event == "telemetry" and getattr(self, "physical_spools", None) is not None:
                from .consumption import on_finish
                on_finish(self, serial, previous, current)
        previous_remaining = {slot.slot_id: slot.remaining for slot in previous.ams_slots}
        # Only warn for a chipped (RFID/NFC) spool: a chipless spool has no reliable remain (issue #27).
        low = next((slot for slot in current.ams_slots if slot.remaining_weight_g is not None
                    and slot.remaining is not None and slot.remaining <= 10
                    and (previous_remaining.get(slot.slot_id) is None or previous_remaining[slot.slot_id] > 10)), None)
        if low and self.config.data.get("notify_low_filament"):
            body = f"Niski poziom filamentu: {low.label} ({low.remaining}%)" if self.language == "pl" else f"Low filament: {low.label} ({low.remaining}%)"
            self.notify(printer_name, body)
        humidity_high = current.ams_humidity is not None and current.ams_humidity >= 4
        humidity_was_high = previous.ams_humidity is not None and previous.ams_humidity >= 4
        if humidity_high and not humidity_was_high and self.config.data.get("notify_humidity"):
            body = "Wysoka wilgotność AMS" if self.language == "pl" else "High AMS humidity"
            self.notify(printer_name, body)
        return False

    @staticmethod
    def notify(title: str, body: str) -> None:
        try: subprocess.Popen(["notify-send", "--app-name=Gantry", title, body], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError: pass

    def scan_and_import(self) -> None:
        self.open_printer_dialog()

    def import_records(self, records: list[dict[str, object]]) -> int:
        previous: dict[str, str | None] = {}
        written: list[str] = []
        try:
            for record in records:
                serial = str(record["serial"])
                code = str(record.get("code") or "")
                if code:
                    previous[serial] = self.secrets.get(serial)
                    self.secrets.set(serial, code); written.append(serial)
        except Exception:
            for serial in written:
                try:
                    if previous.get(serial): self.secrets.set(serial, previous[serial] or "")
                    else: self.secrets.delete(serial)
                except SecretStoreError:
                    pass
            raise
        by_serial = {printer.serial: printer for printer in self.printers}
        for record in records:
            kind = PrinterKind(str(record.get("kind", "bambu")))
            printer = Printer(
                serial=str(record["serial"]), name=str(record["name"]), host=str(record["host"]),
                model={PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper", PrinterKind.PRUSA: "Prusa"}[kind],
                port=int(record["port"]), kind=kind,
            )
            by_serial[printer.serial] = printer
            self.telemetry.setdefault(printer.serial, Telemetry())
        self.printers = list(by_serial.values()); self.config.printers = self.printers
        self.rebuild_cards(); self.reconnect_all()
        return len(records)

    def import_csv_on_screen(self, parent: Gtk.Window | Gtk.Dialog | None = None) -> None:
        self.window._suppress_hide = True
        try:
            self._import_csv_on_screen(parent)
        finally:
            self.window._suppress_hide = False

    def _import_csv_on_screen(self, parent: Gtk.Window | Gtk.Dialog | None = None) -> None:
        chooser = Gtk.FileChooserDialog(
            title="Importuj drukarki z CSV" if self.language == "pl" else "Import printers from CSV",
            transient_for=parent or self.window, action=Gtk.FileChooserAction.OPEN,
        )
        chooser.add_buttons(self.text["cancel"], Gtk.ResponseType.CANCEL, "Importuj", Gtk.ResponseType.OK)
        csv_filter = Gtk.FileFilter(); csv_filter.set_name("CSV"); csv_filter.add_pattern("*.csv"); chooser.add_filter(csv_filter)
        response = chooser.run(); filename = chooser.get_filename(); chooser.destroy()
        if response != Gtk.ResponseType.OK or not filename: return
        try:
            count = self.import_records(parse_printer_csv(Path(filename).read_text(encoding="utf-8-sig")))
            message = f"Zaimportowano {count} drukarek." if self.language == "pl" else f"Imported {count} printers."
            kind = Gtk.MessageType.INFO
        except (OSError, UnicodeError, ValueError, SecretStoreError) as error:
            message = str(error); kind = Gtk.MessageType.ERROR
        dialog = Gtk.MessageDialog(transient_for=parent or self.window, modal=True, message_type=kind,
                                   buttons=Gtk.ButtonsType.OK, text=message)
        dialog.run(); dialog.destroy()

    def open_settings(self) -> None:
        dialog = SettingsDialog(self)
        self.window._suppress_hide = True
        dialog.connect("destroy", lambda *_: setattr(self.window, "_suppress_hide", False))
        while True:
            response = dialog.run()
            if response != Gtk.ResponseType.OK:
                dialog.destroy(); return
            if dialog.save():
                dialog.destroy(); self.language = str(self.config.data.get("language", "pl")); self.text = TEXT.get(self.language, TEXT["pl"]); self.apply_theme(); self.rebuild_cards(); self._tray(); return
            dialog.quiet_start.get_style_context().add_class("error"); dialog.quiet_end.get_style_context().add_class("error")

    def quit(self) -> None:
        for connection in self.connections.values(): connection.stop()
        Gtk.main_quit()


def _diagnose() -> int:
    """Self-test the desktop integration without opening a GUI: is the tray usable, X11 or Wayland,
    and will the frosted-glass blur apply. Run: python3 -m gantry --diagnose"""
    import os
    tray = True
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3  # noqa: F401
    except Exception as exc:
        tray = False
        tray_err = str(exc)
    session = os.environ.get("XDG_SESSION_TYPE", "?")
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "?")
    print(f"Gantry {__version__} diagnostyka / diagnostics")
    print(f"  pulpit / desktop : {desktop}")
    print(f"  sesja / session  : {session}")
    if tray:
        print("  tray (AppIndicator): OK -> dymek + frosted-glass wlaczone")
    else:
        print(f"  tray (AppIndicator): BRAK -> zwykle okno. Instaluj: sudo pacman -S libayatana-appindicator")
        print(f"      ({tray_err})")
    if tray:
        if session == "x11":
            print("  rozmycie / blur  : KWin X11 -> powinno dzialac")
        elif session == "wayland":
            print("  rozmycie / blur  : Wayland -> blur przez wlasciwosc X11 nie zadziala; zostaje przezroczystosc")
        else:
            print("  rozmycie / blur  : nieznana sesja -> zostaje przezroczystosc")
    return 0 if tray else 1


def main() -> int:
    # Name the app "Gantry" for the window manager instead of the script name ("__main__.py") when run
    # from source, and set a matching WM_CLASS so GNOME/KDE group and label the window correctly.
    GLib.set_prgname("Gantry")
    GLib.set_application_name("Gantry")
    try:
        Gtk.Window.set_default_icon_name("gantry")
    except Exception:
        pass
    parser = argparse.ArgumentParser(prog="gantry")
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--kiosk", action="store_true", help="full-screen Raspberry Pi workshop dashboard")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--diagnose", action="store_true", help="check tray / blur / session and exit")
    args = parser.parse_args()
    if args.version:
        print(f"Gantry {__version__}"); return 0
    if args.diagnose:
        return _diagnose()
    if args.kiosk:
        from .kiosk import KioskGantry
        KioskGantry()
    else:
        Gantry(background=args.background)
    Gtk.main(); return 0


if __name__ == "__main__":
    raise SystemExit(main())
