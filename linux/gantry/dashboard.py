from __future__ import annotations

"""GTK dashboard rebuilt from the current macOS dashboard implementation.

The Linux transport/storage code intentionally stays platform-native.  This module is the UI
port: its structure follows PrinterDashboardViewController/PrinterCardView instead of extending
the original 0.5 Linux prototype.
"""

import math
from datetime import datetime, timedelta
from typing import Any

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
from gi.repository import Gdk, GLib, Gtk, Pango  # noqa: E402

from .core import Printer, PrinterKind, PrinterState, Telemetry, TEMP_SYMBOLS, temp_state
from .desktop import installed_slicers, open_desktop_app


PANEL_ONE_COLUMN = 380
PANEL_TWO_COLUMNS = 563
PANEL_COMPACT = 512
CARD_GAP = 10
CARD_ROW_GAP = 8
CONTENT_INSET = 12


def css_for(theme: str, window_alpha: float = 1.0) -> bytes:
    """Current GantryTheme tokens translated to GTK CSS.

    Only the panel backdrop uses ``window_alpha``.  Cards remain readable and translucent through
    their own fixed surface, matching applyPanelTransparency() on macOS.
    """
    if theme == "light":
        canvas, text, card, line, secondary, muted, metric = (
            "#f2f2f7", "#1c1c1e", "#ffffff", "#d1d1d6", "#636366", "#8e8e93", "#3a3a3c"
        )
        segment_off = "alpha(#1c1c1e, 0.14)"
    else:
        canvas, text, card, line, secondary, muted, metric = (
            "#0c0d0e", "#f2f3f1", "#151719", "#2a2c2e", "#a7aaa6", "#6d716e", "#d4d7d3"
        )
        segment_off = "alpha(#f2f3f1, 0.14)"
    values = {
        "canvas": canvas, "text": text, "card": card, "line": line, "secondary": secondary,
        "muted": muted, "metric": metric, "alpha": window_alpha, "segment_off": segment_off,
    }
    return ("""
window { background: %(canvas)s; color: %(text)s; }
window.popover-window { background-color: alpha(%(canvas)s, %(alpha).3f); border: 1px solid %(line)s; border-radius: 20px; }
.fleet-root { padding: 12px 14px 8px; }
.fleet-header { background: alpha(#ffffff, 0.052); border: 1px solid alpha(#ffffff, 0.09); border-radius: 11px; padding: 6px 8px 6px 12px; }
.wordmark { color: %(text)s; font-size: 17px; font-weight: 800; }
.title { color: %(text)s; font-size: 20px; font-weight: 700; }
.summary { color: %(secondary)s; font-size: 11px; }
.subtitle { color: %(secondary)s; font-size: 11px; }
.meta { color: %(secondary)s; font-size: 11px; }
.footer { color: %(muted)s; font-size: 10px; padding-top: 1px; }
button.headericon { background: transparent; border: none; box-shadow: none; padding: 1px 4px; min-width: 24px; min-height: 24px; color: %(secondary)s; font-size: 15px; }
button.headericon:hover { background: alpha(#ffffff, 0.07); border-radius: 10px; }
.card { background: alpha(%(card)s, 0.86); border: 1px solid alpha(#ffffff, 0.09); border-radius: 16px; padding: 6px 10px; }
.card.offline { color: %(muted)s; background: alpha(#0c0d0e, 0.78); }
.offline-overlay { background: alpha(#0c0d0e, 0.72); border-radius: 16px; color: %(secondary)s; padding: 12px; }
.offline-overlay label { color: %(secondary)s; font-size: 11px; font-weight: 600; }
.card-row { background: alpha(%(card)s, 0.70); border: 1px solid alpha(#ffffff, 0.07); border-radius: 12px; padding: 5px 9px; }
.printer-icon { color: %(metric)s; }
.printer-name { color: %(text)s; font-size: 14px; font-weight: 600; }
.connection { color: %(muted)s; border: 1px solid alpha(#ffffff, 0.09); border-radius: 5px; padding: 0 4px; font-size: 10px; }
button.cardmenu { background: alpha(#ffffff, 0.065); border: none; box-shadow: none; padding: 0; min-width: 24px; min-height: 24px; border-radius: 12px; color: %(secondary)s; font-size: 15px; }
button.cardmenu:hover { background: alpha(#ffffff, 0.11); }
.status-dot { background: %(metric)s; border-radius: 3px; min-width: 6px; min-height: 6px; }
.status { color: %(metric)s; font-size: 10px; font-weight: 600; }
.job { color: %(text)s; font-size: 10px; font-weight: 600; }
.percent { color: %(metric)s; font-family: monospace; font-size: 22px; font-weight: 600; }
.metric { color: %(secondary)s; font-family: monospace; font-size: 10px; font-weight: 600; }
.section-rule { background: alpha(#ffffff, 0.09); min-height: 1px; }
.temp-zone { padding: 3px 7px 4px; border-left: 1px solid alpha(#ffffff, 0.09); }
.temp-zone:first-child { border-left: none; }
.temp-name { color: %(muted)s; font-family: monospace; font-size: 7px; font-weight: 600; }
.temp-value { color: %(metric)s; font-family: monospace; font-size: 14px; font-weight: 600; }
.temp-target { color: %(muted)s; font-family: monospace; font-size: 7px; }
.temp-value.heat { color: #d18c82; }
.temp-value.cool { color: #8ba9c7; }
.temp-value.idle, .temp-value.unavail { color: #6d716e; }
.temp-value.ready { color: #d4d7d3; }
.temp-value.hold { color: #f2f3f1; font-weight: 700; }
.temp-value.err { color: #ff5a4e; font-weight: 700; }
.temp-value.mono { color: %(secondary)s; }
.ams-group { background: transparent; padding: 4px 6px; }
.ams-group.divided { border-left: 1px solid alpha(#ffffff, 0.09); }
.ams-title { color: %(text)s; font-size: 10px; font-weight: 600; }
.ams-env { color: alpha(%(metric)s, 0.72); font-size: 10px; font-weight: 500; }
.ams { border-radius: 6px; border: 1px solid alpha(#000000, 0.14); min-height: 18px; }
.ams.active { border: 2px solid alpha(#ffffff, 0.85); }
.ams.empty { background-image: repeating-linear-gradient(45deg, alpha(#ffffff, 0.04), alpha(#ffffff, 0.04) 2px, transparent 2px, transparent 7px); border-color: alpha(#ffffff, 0.075); }
.slot-pct { font-family: monospace; font-size: 9px; font-weight: 700; text-shadow: 0 1px alpha(#000000, 0.55); }
.slot-id { color: %(muted)s; font-family: monospace; font-size: 8px; }
.slot-material { color: %(text)s; font-size: 10px; font-weight: 600; }
.slot-grams { color: %(metric)s; font-size: 10px; font-weight: 600; }
.lowdot { background: #ff5a4e; border: 1px solid #202020; border-radius: 4px; }
.card-notice { background: alpha(#ff6857, 0.16); border: 1px solid alpha(#ff6857, 0.34); border-radius: 9px; padding: 5px 6px 5px 9px; }
.card-notice label { color: #f0d9d5; font-size: 10px; }
.settings-root { padding: 18px 20px 16px; }
.settings-header { padding: 1px 2px 4px; }
.settings-title { color: %(text)s; font-size: 22px; font-weight: 700; }
.settings-author { color: %(secondary)s; font-size: 13px; font-weight: 600; }
.settings-links { padding-top: 2px; }
.settings-card { background: alpha(%(card)s, 0.72); border: 1px solid alpha(#ffffff, 0.09); border-radius: 16px; padding: 12px 14px; }
.settings-section { color: %(muted)s; font-size: 10px; font-weight: 700; }
.settings-label { color: %(secondary)s; font-size: 12px; }
.settings-hint { color: %(muted)s; font-size: 10px; }
.settings-version { color: %(muted)s; font-size: 10px; }
.settings-support { background: alpha(#ffffff, 0.055); border: 1px solid alpha(#ffffff, 0.09); border-radius: 10px; padding: 8px 12px; }
.settings-card checkbutton { padding: 3px 0; }
.settings-card entry { min-height: 26px; }
.sb-root { padding: 14px 14px 10px; }
.sb-header { padding: 1px 2px 8px 6px; }
.sb-icon { color: %(text)s; }
.sb-title { color: %(text)s; font-size: 18px; font-weight: 700; }
.sb-summary { color: %(secondary)s; font-size: 10px; }
.sb-toolbar { padding: 0 2px 8px; }
entry.sb-search { background: alpha(#ffffff, 0.055); border: 1px solid alpha(#ffffff, 0.09); border-radius: 10px; padding: 7px 10px; }
button.sb-filter { background: alpha(#ffffff, 0.055); border: 1px solid alpha(#ffffff, 0.09); box-shadow: none; border-radius: 10px; padding: 6px 10px; min-height: 26px; }
button.sb-filter:hover { background: alpha(#ffffff, 0.09); }
.sb-chips { padding: 0 3px 5px; }
button.sb-chip { color: #8bb8e4; background: alpha(#4d9ee8, 0.14); border: none; box-shadow: none; border-radius: 9px; padding: 3px 8px; font-size: 10px; }
.sb-type { color: %(text)s; font-size: 12px; font-weight: 600; }
.sb-count { color: %(secondary)s; font-size: 9px; }
eventbox.sb-tile { background: transparent; border-radius: 11px; padding: 6px 7px; min-height: 46px; }
eventbox.sb-tile:hover { background: alpha(#ffffff, 0.055); }
.sb-color { color: %(text)s; font-size: 10px; font-weight: 600; }
.sb-product { color: %(secondary)s; font-size: 8px; }
.sb-badge { border-radius: 8px; padding: 4px 7px; min-width: 16px; font-family: monospace; font-size: 9px; font-weight: 700; }
.sb-badge.zero { color: %(muted)s; background: alpha(%(muted)s, 0.10); }
.sb-badge.red { color: #ff6158; background: alpha(#ff6158, 0.17); }
.sb-badge.blue { color: #61a8ec; background: alpha(#61a8ec, 0.17); }
.sb-badge.green { color: #58bd70; background: alpha(#58bd70, 0.17); }
.sb-swatch { border: 1px solid alpha(#ffffff, 0.18); border-radius: 15px; }
.sb-empty { color: %(secondary)s; font-size: 11px; font-weight: 600; }
.detail-root { padding: 10px 12px 12px; }
.detail-card { background: alpha(%(card)s, 0.78); border: 1px solid alpha(#ffffff, 0.09); border-radius: 16px; padding: 10px; }
.detail-title { color: %(muted)s; font-size: 10px; font-weight: 600; }
.detail-value { color: %(text)s; font-size: 12px; font-weight: 600; }
entry { padding: 8px; border-radius: 8px; }
progressbar trough { min-height: 7px; border-radius: 3px; background: %(segment_off)s; }
progressbar progress { border-radius: 2px; background: %(metric)s; }
""" % values).encode()


def _muted_hex(value: str, amount: float = 0.62) -> str:
    try:
        value = value.lstrip("#")[:6]
        r, g, b = int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)
        lum = 0.299 * r + 0.587 * g + 0.114 * b
        channels = [int(c + (lum - c) * amount) for c in (r, g, b)]
        return "".join(f"{max(0, min(255, c)):02X}" for c in channels)
    except Exception:
        return value


def _contrast_ink(value: str, remaining: float | None = 100) -> str:
    if remaining is not None and remaining < 50:
        return "#ffffff"
    try:
        value = value.lstrip("#")[:6]
        r, g, b = int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)
        return "#111111" if (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.58 else "#ffffff"
    except Exception:
        return "#ffffff"


def _clear(container: Gtk.Container) -> None:
    for child in container.get_children():
        container.remove(child)


def _rule() -> Gtk.Widget:
    rule = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
    rule.get_style_context().add_class("section-rule")
    return rule


class SegmentedProgress(Gtk.DrawingArea):
    def __init__(self) -> None:
        super().__init__()
        self.value = 0
        self.set_size_request(-1, 8)
        self.connect("draw", self._draw)

    def set_value(self, value: int) -> None:
        self.value = max(0, min(100, value))
        self.queue_draw()

    def _draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        width = self.get_allocated_width()
        height = self.get_allocated_height()
        count, gap = 32, 2.0
        segment = max(1.0, (width - gap * (count - 1)) / count)
        active = round(self.value / 100 * count)
        for index in range(count):
            if index < active:
                cr.set_source_rgba(0.831, 0.843, 0.827, 1.0)
            else:
                cr.set_source_rgba(0.831, 0.843, 0.827, 0.14)
            x = index * (segment + gap)
            cr.rectangle(x, 1, segment, max(1, height - 2))
            cr.fill()
        return False


class FilamentSwatch(Gtk.DrawingArea):
    """GTK/Cairo equivalent of FilamentSwatchView and EmptyFilamentSwatchView."""

    def __init__(self, color_hex: str, remaining: float | None, present: bool, active: bool,
                 width: int) -> None:
        super().__init__()
        self.remaining = max(0.0, min(100.0, remaining if remaining is not None else 100.0))
        self.present, self.active = present, active
        rgba = Gdk.RGBA()
        if not rgba.parse("#" + color_hex.lstrip("#")[:6]): rgba.parse("#8E8E93")
        self.color = rgba
        self.set_size_request(width, 18)
        # The swatch is a compact colour sample, not a progress bar. The surrounding slot cell may
        # stretch to keep captions evenly spaced, but the colour pill itself keeps the contract width.
        self.set_hexpand(False)
        self.set_halign(Gtk.Align.CENTER)
        self.connect("draw", self._draw)

    @staticmethod
    def _rounded(cr: Any, x: float, y: float, width: float, height: float, radius: float) -> None:
        radius = min(radius, width / 2, height / 2)
        cr.new_sub_path()
        cr.arc(x + width - radius, y + radius, radius, -math.pi / 2, 0)
        cr.arc(x + width - radius, y + height - radius, radius, 0, math.pi / 2)
        cr.arc(x + radius, y + height - radius, radius, math.pi / 2, math.pi)
        cr.arc(x + radius, y + radius, radius, math.pi, math.pi * 1.5)
        cr.close_path()

    def _draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        self._rounded(cr, 0.5, 0.5, width - 1, height - 1, 6)
        cr.clip(); cr.new_path()
        if not self.present:
            cr.set_source_rgba(1, 1, 1, 0.018); cr.paint()
            cr.set_source_rgba(1, 1, 1, 0.035); cr.set_line_width(1)
            for offset in range(-height, width + height, 9):
                cr.move_to(offset, height); cr.line_to(offset + height, 0)
            cr.stroke()
        else:
            cr.set_source_rgba(self.color.red, self.color.green, self.color.blue, 0.20)
            cr.paint()
            fill_height = height * self.remaining / 100
            top = height - fill_height
            cr.move_to(0, height); cr.line_to(0, top)
            for index in range(29):
                x = width * index / 28
                y = top + min(0.4, fill_height / 2) * math.sin(math.pi * 3 * index / 28)
                cr.line_to(x, y)
            cr.line_to(width, height); cr.close_path()
            cr.set_source_rgba(self.color.red, self.color.green, self.color.blue, 1)
            cr.fill()
        cr.reset_clip()
        self._rounded(cr, 0.75, 0.75, width - 1.5, height - 1.5, 5.5)
        if self.active:
            cr.set_source_rgba(1, 1, 1, 0.85); cr.set_line_width(1.5)
        elif self.present:
            cr.set_source_rgba(0, 0, 0, 0.14); cr.set_line_width(0.5)
        else:
            cr.set_source_rgba(1, 1, 1, 0.075); cr.set_line_width(0.5)
        cr.stroke()
        return False


class PrinterCard(Gtk.Frame):
    """The Linux translation of macOS PrinterCardView."""

    def __init__(self, app: Any, printer: Printer) -> None:
        super().__init__()
        self.app, self.printer = app, printer
        self.set_shadow_type(Gtk.ShadowType.NONE)
        self.get_style_context().add_class("card")
        self.set_hexpand(True)
        self._last_telemetry = Telemetry()

        self.overlay = Gtk.Overlay()
        self.add(self.overlay)
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.overlay.add(self.box)
        self.offline_overlay = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.offline_overlay.get_style_context().add_class("offline-overlay")
        self.offline_overlay.set_halign(Gtk.Align.FILL); self.offline_overlay.set_valign(Gtk.Align.FILL)
        offline_content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        offline_content.set_halign(Gtk.Align.CENTER); offline_content.set_valign(Gtk.Align.CENTER)
        offline_icon = Gtk.Label(label="⌁")
        offline_icon.get_style_context().add_class("wordmark")
        self.offline_label = Gtk.Label(xalign=0.5, wrap=True)
        offline_content.pack_start(offline_icon, False, False, 0)
        offline_content.pack_start(self.offline_label, False, False, 0)
        self.offline_overlay.pack_start(offline_content, True, True, 0)
        self.offline_overlay.set_no_show_all(True); self.offline_overlay.hide()
        self.overlay.add_overlay(self.offline_overlay)
        self.notice = Gtk.Box(spacing=8)
        self.notice.get_style_context().add_class("card-notice")
        self.notice_label = Gtk.Label(xalign=0, wrap=True)
        notice_ok = Gtk.Button(label="OK")
        notice_ok.set_relief(Gtk.ReliefStyle.NONE)
        notice_ok.connect("clicked", lambda *_: self.notice.hide())
        self.notice.pack_start(self.notice_label, True, True, 0)
        self.notice.pack_start(notice_ok, False, False, 0)
        self.notice.set_no_show_all(True)
        self.box.pack_start(self.notice, False, False, 0)

        top = Gtk.Box(spacing=7)
        icon = Gtk.Image.new_from_icon_name("printer-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
        icon.get_style_context().add_class("printer-icon")
        self.name = Gtk.Label(label=printer.name, xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.name.get_style_context().add_class("printer-name")
        connection = {PrinterKind.BAMBU: "MQTT", PrinterKind.KLIPPER: "KLIPPER",
                      PrinterKind.PRUSA: "PRUSALINK", PrinterKind.SNAPMAKER: "HTTP",
                      PrinterKind.ELEGOO_CC1: "SDCP", PrinterKind.ELEGOO_CC2: "MQTT LAN"}[printer.kind]
        self.connection = Gtk.Label(label=connection)
        self.connection.get_style_context().add_class("connection")
        details = self._button("⌁", "Szczegóły" if app.language == "pl" else "Details")
        details.connect("clicked", lambda *_: app.open_details(printer.serial))
        grip = Gtk.Label(label="⠿")
        grip.get_style_context().add_class("metric")
        menu = self._button("⋯", "Menu")
        menu.connect("clicked", self._show_menu)
        for child, expand in ((icon, False), (self.name, True), (self.connection, False),
                              (details, False), (grip, False), (menu, False)):
            top.pack_start(child, expand, expand, 0)
        self.box.pack_start(top, False, False, 0)

        self.status_row = Gtk.Box(spacing=5)
        dot = Gtk.Label(label="")
        dot.set_size_request(6, 6)
        dot.get_style_context().add_class("status-dot")
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        sep = Gtk.Label(label="·")
        sep.get_style_context().add_class("metric")
        self.job = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.job.get_style_context().add_class("job")
        self.status_row.pack_start(dot, False, False, 0)
        self.status_row.pack_start(self.status, False, False, 0)
        self.job_separator = sep
        self.status_row.pack_start(self.job_separator, False, False, 0)
        self.status_row.pack_start(self.job, True, True, 0)
        self.box.pack_start(self.status_row, False, False, 0)

        metrics = Gtk.Box(spacing=7)
        self.percent = Gtk.Label(label="0%", xalign=0)
        self.percent.get_style_context().add_class("percent")
        self.eta = Gtk.Label(label="—", xalign=0)
        self.eta.get_style_context().add_class("metric")
        self.layers = Gtk.Label(label="—", xalign=0)
        self.layers.get_style_context().add_class("metric")
        metrics.pack_start(self.percent, False, False, 0)
        metrics.pack_start(self.eta, False, False, 0)
        metrics.pack_start(self.layers, False, False, 0)
        self.box.pack_start(metrics, False, False, 0)
        self.progress = SegmentedProgress()
        self.box.pack_start(self.progress, False, False, 0)

        self.temp_rule = _rule()
        self.box.pack_start(self.temp_rule, False, False, 1)
        self.temps = Gtk.Box(spacing=0, homogeneous=True)
        self.box.pack_start(self.temps, False, False, 0)
        self.ams_rule = _rule()
        self.box.pack_start(self.ams_rule, False, False, 1)
        self.ams = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.pack_start(self.ams, False, False, 0)

        target = Gtk.TargetEntry.new("application/x-gantry-printer", Gtk.TargetFlags.SAME_APP, 0)
        self.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [target], Gdk.DragAction.MOVE)
        self.drag_dest_set(Gtk.DestDefaults.ALL, [target], Gdk.DragAction.MOVE)
        self.connect("drag-data-get", self._drag_data_get)
        self.connect("drag-data-received", self._drag_data_received)
        self.update(Telemetry())

    @staticmethod
    def _button(label: str, tooltip: str) -> Gtk.Button:
        button = Gtk.Button(label=label)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.get_style_context().add_class("cardmenu")
        button.set_tooltip_text(tooltip)
        return button

    def _show_menu(self, button: Gtk.Button) -> None:
        pl = self.app.language == "pl"
        menu = Gtk.Menu()
        entries: list[tuple[str, Any]] = [
            (("Szczegóły" if pl else "Details"), lambda *_: self.app.open_details(self.printer.serial)),
            (("Połącz ponownie" if pl else "Reconnect"), lambda *_: self.app.reconnect_printer(self.printer.serial)),
        ]
        for label, callback in entries:
            item = Gtk.MenuItem(label=label); item.connect("activate", callback); menu.append(item)
        slicers = installed_slicers()
        if self.printer.kind == PrinterKind.BAMBU:
            bambu = next((slicer for slicer in slicers if slicer.name == "Bambu Studio"), None)
            if bambu is not None:
                item = Gtk.MenuItem(label="Kamera w Bambu Studio" if pl else "Camera in Bambu Studio")
                item.connect("activate", lambda *_, value=bambu: open_desktop_app(value)); menu.append(item)
        if slicers:
            slicer_item = Gtk.MenuItem(label="Otwórz slicer" if pl else "Open slicer")
            slicer_menu = Gtk.Menu()
            for slicer in slicers:
                item = Gtk.MenuItem(label=slicer.name)
                item.connect("activate", lambda *_, value=slicer: open_desktop_app(value))
                slicer_menu.append(item)
            slicer_item.set_submenu(slicer_menu); menu.append(slicer_item)
        clipboard_item = Gtk.MenuItem(label="Kopiuj adres IP" if pl else "Copy IP address")
        clipboard_item.connect("activate", lambda *_: Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(self.printer.host, -1))
        menu.append(clipboard_item)
        for label, callback in [
            (("Edytuj drukarkę" if pl else "Edit printer"), lambda *_: self.app.open_printer_dialog(self.printer)),
            (("Usuń drukarkę" if pl else "Remove printer"), lambda *_: self.app.confirm_remove_printer(self.printer)),
        ]:
            item = Gtk.MenuItem(label=label); item.connect("activate", callback); menu.append(item)
        menu.show_all()
        window = getattr(self.app, "window", None)
        if window is not None:
            window._suppress_hide = True
            menu.connect("deactivate", lambda *_: setattr(window, "_suppress_hide", False))
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_EAST, Gdk.Gravity.NORTH_EAST, None)

    def _drag_data_get(self, _widget: Gtk.Widget, _context: Gdk.DragContext,
                       selection: Gtk.SelectionData, _info: int, _timestamp: int) -> None:
        selection.set_text(self.printer.serial, -1)

    def _drag_data_received(self, _widget: Gtk.Widget, context: Gdk.DragContext, _x: int, _y: int,
                            selection: Gtk.SelectionData, _info: int, timestamp: int) -> None:
        source = selection.get_text() or ""
        if source and source != self.printer.serial:
            self.app.move_printer(source, self.printer.serial)
        Gtk.drag_finish(context, True, True, timestamp)

    def set_compact(self, compact: bool, expanded: bool = False) -> None:
        hidden = compact and not expanded
        for widget in (self.status_row, self.percent.get_parent(), self.progress, self.temp_rule,
                       self.temps, self.ams_rule, self.ams):
            widget.set_no_show_all(hidden)
            widget.set_visible(not hidden)
        if compact:
            self.connect("button-release-event", self._toggle_compact)

    def _toggle_compact(self, _widget: Gtk.Widget, event: Gdk.EventButton) -> bool:
        if event.button == 1:
            self.app.toggle_compact_printer(self.printer.serial)
            return True
        return False

    def update(self, telemetry: Telemetry, reason: str | None = None) -> None:
        self._last_telemetry = telemetry
        labels = self.app.text
        state = labels.get(telemetry.state.value, telemetry.state.value)
        stages = getattr(self.app, "stages", None)
        if stages and telemetry.stage in stages:
            state = stages[telemetry.stage][0 if self.app.language == "pl" else 1]
        if reason:
            if "certificate-changed" in reason: state = labels["certificate"]
            elif "access-code-rejected" in reason: state = labels["rejected"]
        if telemetry.state == PrinterState.ERROR and telemetry.hms_codes:
            from .hms import description
            state = description(telemetry.hms_codes, self.printer.serial, self.app.language) or state
        self.status.set_text(state)
        active = telemetry.state in {PrinterState.PRINTING, PrinterState.PAUSED}
        self.job.set_text(telemetry.job_name if active and telemetry.job_name else
                          ("BRAK AKTYWNEGO ZADANIA" if self.app.language == "pl" else "NO ACTIVE JOB"))
        self.percent.set_text(f"{telemetry.progress}%")
        self.progress.set_value(telemetry.progress)
        if telemetry.remaining_minutes:
            mins = telemetry.remaining_minutes
            finish = (datetime.now() + timedelta(minutes=mins)).strftime("%H:%M")
            remaining = f"{mins // 60}h {mins % 60}m" if mins >= 60 else f"{mins}m"
            self.eta.set_text(f"◷ {remaining} · {finish}")
        else:
            self.eta.set_text("◷ —")
        layer = "—" if telemetry.current_layer is None else f"{telemetry.current_layer}/{telemetry.total_layers or '—'}"
        self.layers.set_text(f"≋ {layer}")
        self._fill_temperatures(telemetry)
        self._fill_filaments(telemetry)
        show_filename = bool(self.app.config.data.get("card_show_filename", True))
        show_progress = bool(self.app.config.data.get("card_show_progress", True))
        show_temperatures = bool(self.app.config.data.get("card_show_temperatures", True))
        show_filaments = bool(self.app.config.data.get("card_show_filaments", True))
        for widget in (self.job, self.job_separator):
            widget.set_no_show_all(not show_filename); widget.set_visible(show_filename)
        for widget in (self.percent.get_parent(), self.progress):
            widget.set_no_show_all(not show_progress); widget.set_visible(show_progress)
        for widget in (self.temp_rule, self.temps):
            widget.set_no_show_all(not show_temperatures); widget.set_visible(show_temperatures)
        has_filaments = bool(telemetry.filament_groups) and show_filaments
        for widget in (self.ams_rule, self.ams):
            widget.set_no_show_all(not has_filaments); widget.set_visible(has_filaments)
        offline = telemetry.state == PrinterState.OFFLINE
        ctx = self.get_style_context()
        if offline: ctx.add_class("offline")
        else: ctx.remove_class("offline")
        self.offline_label.set_text(reason or ("Łączenie…" if self.app.language == "pl" else "Connecting…"))
        self.offline_overlay.set_no_show_all(not offline); self.offline_overlay.set_visible(offline)

    def _fill_temperatures(self, telemetry: Telemetry) -> None:
        _clear(self.temps)
        pl = self.app.language == "pl"
        mono = bool(self.app.config.data.get("monochrome", False))
        printing = telemetry.state == PrinterState.PRINTING
        errored = telemetry.state == PrinterState.ERROR

        def zone(label: str, current: float | None, target: float | None) -> Gtk.Widget:
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
            box.get_style_context().add_class("temp-zone")
            title = Gtk.Label(label=label.upper(), xalign=0)
            title.get_style_context().add_class("temp-name")
            values = Gtk.Box(spacing=3)
            state = temp_state(current, target, printing, errored and target is not None)
            current_text = f"{current:.0f}°" if current is not None else "—"
            if mono: current_text = f"{TEMP_SYMBOLS[state]} {current_text}"
            value = Gtk.Label(label=current_text)
            value.get_style_context().add_class("temp-value")
            value.get_style_context().add_class("mono" if mono else state)
            target_label = Gtk.Label(label=f"/ {target:.0f}°" if target else "/ —")
            target_label.get_style_context().add_class("temp-target")
            values.set_halign(Gtk.Align.CENTER)
            values.pack_start(value, False, False, 0)
            values.pack_start(target_label, False, False, 0)
            box.pack_start(title, False, False, 0)
            box.pack_start(values, False, False, 0)
            return box

        nozzles = telemetry.nozzles
        dual = any(nozzle.position == "right" for nozzle in nozzles)
        if dual:
            left = next((n for n in nozzles if n.position == "left"), nozzles[0])
            right = next((n for n in nozzles if n.position == "right"), None)
            self.temps.pack_start(zone("Dysze L" if pl else "Nozzles L", left.current, left.target), True, True, 0)
            self.temps.pack_start(zone("P" if pl else "R", right.current if right else None,
                                       right.target if right else None), True, True, 0)
        else:
            nozzle = nozzles[0] if nozzles else None
            self.temps.pack_start(zone("Dysza" if pl else "Nozzle",
                                       nozzle.current if nozzle else telemetry.nozzle,
                                       nozzle.target if nozzle else telemetry.nozzle_target), True, True, 0)
        self.temps.pack_start(zone("Stół" if pl else "Bed", telemetry.bed, telemetry.bed_target), True, True, 0)
        if telemetry.chamber is not None:
            self.temps.pack_start(zone("Komora" if pl else "Chamber", telemetry.chamber, None), True, True, 0)
        self.temps.show_all()

    def _fill_filaments(self, telemetry: Telemetry) -> None:
        _clear(self.ams)
        groups = telemetry.filament_groups
        self.ams_rule.set_visible(bool(groups))
        self.ams.set_visible(bool(groups))
        store = getattr(self.app, "physical_spools", None) if self.app.config.data.get("spoolbase_enabled", True) else None
        for row_start in range(0, len(groups), 2):
            row_groups = groups[row_start:row_start + 2]
            row = Gtk.Grid(column_spacing=0, column_homogeneous=True)
            weights = [3 if group.declared_capacity > 1 else 1 for group in row_groups]
            # A spanning child alone does not reliably establish proportional homogeneous tracks in
            # GTK 3 (some themes allocate the two group children 1:1). Tiny zero-height track anchors
            # make the macOS 3:1 AMS→HT/EXT ratio deterministic without adding visible content.
            for track in range(sum(weights)):
                anchor = Gtk.Box()
                anchor.set_size_request(1, 0)
                row.attach(anchor, track, 1, 1, 1)
            column = 0
            for offset, (group, weight) in enumerate(zip(row_groups, weights)):
                group_index = row_start + offset
                gbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
                gbox.get_style_context().add_class("ams-group")
                if offset: gbox.get_style_context().add_class("divided")
                # macOS uses one compact, left-aligned sequence: name · temperature · humidity.
                # Do not pack humidity at the far edge — that made the header look detached on GTK.
                header = Gtk.Box(spacing=6)
                header.set_halign(Gtk.Align.START)
                short = group.display_name
                if short.startswith("AMS "):
                    suffix = short[4:]
                    short = "AMS" if len(suffix) == 1 else suffix
                name = Gtk.Label(label=short, xalign=0)
                name.get_style_context().add_class("ams-title")
                header.pack_start(name, False, False, 0)

                def add_environment(glyph: str, value: str) -> None:
                    separator = Gtk.Label(label="·")
                    separator.get_style_context().add_class("ams-env")
                    cluster = Gtk.Box(spacing=3)
                    icon = Gtk.Label(label=glyph)
                    metric = Gtk.Label(label=value)
                    icon.get_style_context().add_class("ams-env")
                    metric.get_style_context().add_class("ams-env")
                    cluster.pack_start(icon, False, False, 0)
                    cluster.pack_start(metric, False, False, 0)
                    header.pack_start(separator, False, False, 0)
                    header.pack_start(cluster, False, False, 0)

                if group.temperature is not None:
                    add_environment("🌡", f"{group.temperature:.0f}°")
                if group.humidity is not None:
                    humidity = f"{group.humidity}/5" if group.humidity <= 5 else f"{group.humidity}%"
                    add_environment("💧", humidity)
                gbox.pack_start(header, False, False, 0)
                slots = Gtk.Box(spacing=5, homogeneous=True)
                for slot_index, slot in enumerate(group.slots):
                    slots.pack_start(self._slot(group, group_index, slot, slot_index, store), True, True, 0)
                gbox.pack_start(slots, False, False, 0)
                row.attach(gbox, column, 0, weight, 1)
                column += weight
            self.ams.pack_start(row, False, False, 0)
        self.ams.show_all()

    def _slot(self, group: Any, group_index: int, slot: Any, slot_index: int, store: Any) -> Gtk.Widget:
        assigned = None
        if store is not None:
            from .physicalspool import location_for
            assigned = store.spool_at(location_for(self.printer.serial, group.external, group_index, slot_index))
        definition = None
        if assigned is not None and getattr(self.app, "filament_store", None) is not None:
            definition = next((f for f in self.app.filament_store.filaments
                               if f.id == assigned.get("filamentDefinitionID")), None)
        present = slot.present or assigned is not None
        color = ((slot.color or "8E8E93FF") if slot.present else
                 (str(definition.colorHex) if definition is not None else "1D1F22")).lstrip("#")[:6]
        if self.app.config.data.get("monochrome", False): color = _muted_hex(color)
        remaining = (store.percent(assigned) if assigned is not None and store is not None else slot.remaining)
        material = (slot.material if slot.present else
                    ((definition.type or definition.name) if definition is not None else "—")) or "—"
        grams = slot.remaining_weight_g
        if grams is None and assigned is not None: grams = assigned.get("remainingWeightGrams")

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        is_single = len(group.slots) == 1
        # macOS parity: a lone slot is 35% of its module (minimum 60 px). Multi-slot swatches cap at
        # 56 px for AMS/CFS and 92 px for an external multi-slot feeder.
        swatch_width = 60 if is_single else (92 if group.external else 56)
        overlay = Gtk.Overlay()
        overlay.set_size_request(swatch_width, 18)
        overlay.set_hexpand(False)
        overlay.set_halign(Gtk.Align.CENTER)
        swatch = FilamentSwatch(color, remaining, present, slot.active, swatch_width)
        if is_single:
            swatch.set_hexpand(True)
            swatch.set_halign(Gtk.Align.FILL)
        overlay.add(swatch)
        if present and remaining is not None:
            pct = Gtk.Label(label=f"{int(remaining)}%")
            pct.get_style_context().add_class("slot-pct")
            pct.set_halign(Gtk.Align.CENTER); pct.set_valign(Gtk.Align.CENTER)
            ink = Gtk.CssProvider()
            ink.load_from_data(f".slot-pct {{ color: {_contrast_ink(color, remaining)}; }}".encode())
            pct.get_style_context().add_provider(ink, Gtk.STYLE_PROVIDER_PRIORITY_USER)
            overlay.add_overlay(pct)
        trusted_low = slot.remaining_weight_g is not None and slot.remaining is not None and slot.remaining <= 15
        if present and not group.external and trusted_low:
            dot = Gtk.Label(label="")
            dot.set_size_request(7, 7); dot.set_halign(Gtk.Align.END); dot.set_valign(Gtk.Align.START)
            dot.get_style_context().add_class("lowdot")
            overlay.add_overlay(dot)
        caption = Gtk.Overlay()
        mat = Gtk.Label(label=material, ellipsize=Pango.EllipsizeMode.END)
        mat.get_style_context().add_class("slot-material")
        caption.add(mat)
        if not group.external:
            slot_id = Gtk.Label(label=slot.label, xalign=0)
            slot_id.get_style_context().add_class("slot-id")
            slot_id.set_halign(Gtk.Align.START)
            caption.add_overlay(slot_id)
        box.pack_start(overlay, False, False, 0)
        box.pack_start(caption, False, False, 0)
        if is_single:
            def resize_single_swatch(_widget: Gtk.Widget, allocation: Gdk.Rectangle) -> None:
                width = min(allocation.width, max(60, int(round(allocation.width * 0.35))))
                overlay.set_size_request(width, 18)
            box.connect("size-allocate", resize_single_swatch)
        if grams and self.app.config.data.get("card_show_spool_grams", False):
            label = Gtk.Label(label=f"{int(grams)} g")
            label.get_style_context().add_class("slot-grams")
            box.pack_start(label, False, False, 0)
        if store is None:
            return box
        event = Gtk.EventBox(); event.add(box)
        event.connect("button-press-event", lambda *_: self._open_slot_assign(group, group_index, slot, slot_index))
        return event

    def _open_slot_assign(self, group: Any, group_index: int, slot: Any, slot_index: int) -> bool:
        try:
            from .spoolassign import open_assign_dialog
            open_assign_dialog(self.app, self.printer.serial, group, group_index, slot, slot_index)
        except Exception:
            pass
        return True

    def show_notice(self, text: str) -> None:
        self.notice_label.set_text(text)
        self.notice.show_all()


class CompactPrinterRow(Gtk.Box):
    """CompactPrinterRowView port with an optional full-card accordion."""

    def __init__(self, app: Any, printer: Printer, expanded: bool = False) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.app, self.printer = app, printer
        row_event = Gtk.EventBox()
        row = Gtk.Box(spacing=7)
        row.get_style_context().add_class("card-row")
        handle = Gtk.Label(label="⠿"); handle.get_style_context().add_class("metric")
        icon = Gtk.Image.new_from_icon_name("printer-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
        icon.get_style_context().add_class("printer-icon")
        name = Gtk.Label(label=printer.name, xalign=0, ellipsize=Pango.EllipsizeMode.END)
        name.get_style_context().add_class("printer-name")
        self.status = Gtk.Label(xalign=1, ellipsize=Pango.EllipsizeMode.END)
        self.status.get_style_context().add_class("summary")
        row.pack_start(handle, False, False, 0); row.pack_start(icon, False, False, 0)
        row.pack_start(name, False, False, 0); row.pack_start(self.status, True, True, 0)
        row_event.add(row)
        row_event.connect("button-release-event", self._clicked)
        self.pack_start(row_event, False, False, 0)
        self.full_card = PrinterCard(app, printer) if expanded else None
        if self.full_card is not None: self.pack_start(self.full_card, False, False, 0)

        target = Gtk.TargetEntry.new("application/x-gantry-printer", Gtk.TargetFlags.SAME_APP, 0)
        row_event.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [target], Gdk.DragAction.MOVE)
        row_event.drag_dest_set(Gtk.DestDefaults.ALL, [target], Gdk.DragAction.MOVE)
        row_event.connect("drag-data-get", lambda _w, _c, selection, _i, _t:
                          selection.set_text(printer.serial, -1))
        row_event.connect("drag-data-received", self._drop)

    def _clicked(self, _widget: Gtk.Widget, event: Gdk.EventButton) -> bool:
        if event.button == 1:
            self.app.toggle_compact_printer(self.printer.serial)
            return True
        return False

    def _drop(self, _widget: Gtk.Widget, context: Gdk.DragContext, _x: int, _y: int,
              selection: Gtk.SelectionData, _info: int, timestamp: int) -> None:
        source = selection.get_text() or ""
        if source and source != self.printer.serial: self.app.move_printer(source, self.printer.serial)
        Gtk.drag_finish(context, True, True, timestamp)

    def update(self, telemetry: Telemetry, reason: str | None = None) -> None:
        status = self.app.text.get(telemetry.state.value, telemetry.state.value)
        if telemetry.state == PrinterState.PRINTING:
            status += f" · {telemetry.progress}%"
        if reason: status = reason
        self.status.set_text(status)
        if self.full_card is not None: self.full_card.update(telemetry, reason)

    def show_notice(self, text: str) -> None:
        if self.full_card is not None: self.full_card.show_notice(text)


class Dashboard(Gtk.Window):
    """Popover host matching macOS panel sizing and view swapping."""

    def __init__(self, app: Any) -> None:
        super().__init__()
        self.app = app
        self._just_shown = False
        self._suppress_hide = False
        self.tray_mode = getattr(app, "indicator_available", True)
        rgba = self.get_screen().get_rgba_visual()
        if rgba is not None: self.set_visual(rgba)
        self.set_title("Gantry")
        self.set_decorated(not self.tray_mode)
        self.set_resizable(not self.tray_mode)
        if self.tray_mode:
            self.set_skip_taskbar_hint(True); self.set_skip_pager_hint(True); self.set_keep_above(True)
            self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
            self.get_style_context().add_class("popover-window")
            self.connect("focus-out-event", self._on_focus_out)
            self.connect("realize", lambda *_: self._apply_backdrop())
            self.connect("map", lambda *_: self._apply_backdrop())
        else:
            self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._hide)
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.add(self.stack)
        self.fleet = self._build_fleet()
        self.stack.add_named(self.fleet, "fleet")
        self.stack.set_visible_child_name("fleet")

    def _build_fleet(self) -> Gtk.Widget:
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        root.get_style_context().add_class("fleet-root")
        header = Gtk.Box(spacing=7)
        header.get_style_context().add_class("fleet-header")
        wordmark = Gtk.Label(label="GANTRY")
        wordmark.get_style_context().add_class("wordmark")
        dot = Gtk.Label(label="·"); dot.get_style_context().add_class("summary")
        self.subtitle = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.subtitle.get_style_context().add_class("summary")
        header.pack_start(wordmark, False, False, 0); header.pack_start(dot, False, False, 0)
        header.pack_start(self.subtitle, True, True, 0)
        self.columns = self._header_button("▯", self._toggle_columns)
        self.collapse = self._header_button("☷", self._toggle_compact)
        clear = self._header_button("⊗", lambda *_: self.app.reset_completed())
        refresh = self._header_button("↻", lambda *_: self.app.reconnect_and_refresh())
        add = self._header_button("＋", lambda *_: self.app.open_printer_dialog())
        for button in (self.columns, self.collapse, clear, refresh, add):
            header.pack_start(button, False, False, 0)
        root.pack_start(header, False, False, 0)
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.grid = Gtk.Grid(column_spacing=CARD_GAP, row_spacing=CARD_ROW_GAP, margin=0)
        self.scroll.add(self.grid)
        root.pack_start(self.scroll, True, True, 0)
        footer = Gtk.Label(label=("Drukuj spokojnie — wszystko pod kontrolą" if self.app.language == "pl"
                                  else "Print in peace — everything under control"))
        footer.get_style_context().add_class("footer")
        root.pack_start(footer, False, False, 0)
        return root

    @staticmethod
    def _header_button(label: str, callback: Any) -> Gtk.Button:
        button = Gtk.Button(label=label)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.get_style_context().add_class("headericon")
        button.connect("clicked", callback)
        return button

    def _toggle_columns(self, *_args: Any) -> None:
        current = int(self.app.config.data.get("dashboard_columns", 2))
        self.app.config.data["dashboard_columns"] = 1 if current == 2 else 2
        self.app.config.save(); self.app.rebuild_cards()

    def _toggle_compact(self, *_args: Any) -> None:
        self.app.config.data["collapsed"] = not self.app.is_compact()
        self.app.config.data["collapsed_chosen"] = True
        self.app.expanded_compact_serial = None
        self.app.config.save(); self.app.rebuild_cards()

    def update_header(self) -> None:
        active = sum(1 for value in self.app.telemetry.values() if value.state == PrinterState.PRINTING)
        self.subtitle.set_text((f"{len(self.app.printers)} drukarek · {active} pracuje" if self.app.language == "pl"
                                else f"{len(self.app.printers)} printers · {active} printing"))
        compact = self.app.is_compact()
        self.collapse.set_visible(len(self.app.printers) >= 4)
        self.collapse.set_label("▦" if compact else "☷")
        self.columns.set_visible(not compact)
        self.columns.set_label("▯" if int(self.app.config.data.get("dashboard_columns", 2)) == 2 else "▥")

    def resize_for_content(self) -> None:
        compact = self.app.is_compact()
        columns = max(1, min(2, int(self.app.config.data.get("dashboard_columns", 2))))
        width = PANEL_COMPACT if compact else (PANEL_ONE_COLUMN if columns == 1 else PANEL_TWO_COLUMNS)
        minimum, natural = self.fleet.get_preferred_height_for_width(width)
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() if display else None
        max_height = (monitor.get_workarea().height - 24) if monitor else 820
        height = max(150, min(max_height, natural))
        self.set_default_size(width, height)
        self.resize(width, height)

    def show_detail(self, widget: Gtk.Widget) -> None:
        old = self.stack.get_child_by_name("detail")
        if old is not None:
            deactivate = getattr(old, "deactivate", None)
            if callable(deactivate): deactivate()
            self.stack.remove(old)
        self.stack.add_named(widget, "detail")
        self.stack.show_all(); self.stack.set_visible_child_name("detail")
        self.resize(480, min(700, self.get_screen().get_height() - 48))

    def show_fleet(self) -> None:
        detail = self.stack.get_child_by_name("detail")
        deactivate = getattr(detail, "deactivate", None)
        if callable(deactivate): deactivate()
        self.stack.set_visible_child_name("fleet")
        self.resize_for_content()

    def _apply_backdrop(self, *_args: Any) -> None:
        try:
            from .backdrop import apply_backdrop
            self._backdrop_mode = apply_backdrop(self)
        except Exception:
            self._backdrop_mode = "transparency"

    def _hide(self, *_args: Any) -> bool:
        self.hide(); return True

    def _on_focus_out(self, *_args: Any) -> bool:
        if not self._just_shown and not self._suppress_hide: self.hide()
        return False

    def position_top_right(self) -> None:
        display = Gdk.Display.get_default()
        monitor = (display.get_primary_monitor() or display.get_monitor(0)) if display else None
        if monitor is None: return
        area = monitor.get_workarea(); width, _ = self.get_size()
        self.move(area.x + area.width - width - 10, area.y + 10)
