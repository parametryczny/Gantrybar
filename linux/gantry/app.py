from __future__ import annotations

import argparse
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

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
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # type: ignore # noqa: E402
except (ValueError, ImportError):
    AppIndicator = None

from . import __version__
from .core import STATE_LABELS, Printer, PrinterKind, PrinterState, Telemetry, expand_scan_targets
from .csvimport import parse_printer_csv
from .discovery import scan
from .http_clients import HttpConnection
from .layout import needs_wide, place_cards
from .mqtt import MqttConnection
from . import i18n
from .storage import Config, SecretStore, SecretStoreError, autostart_enabled, set_autostart
from .studio import devices as studio_devices


# Angielskie klucze katalogu dla wartosci wybieranych dynamicznie (stan drukarki, pola formularza).
FIELD_LABELS = {"name": "Name", "host": "IP address / host", "serial": "Serial number", "code": "Access code / API key", "port": "Port", "kind": "Printer type", "api_optional": "API key (optional)", "targets": "Additional VPN targets", "targets_hint": "IP, a-b range or CIDR /n (up to 1024 addresses)"}

STAGES = {
    1: "Auto bed leveling", 2: "Heating bed",
    3: "Vibration calibration", 4: "Changing filament",
    7: "Heating nozzle", 8: "Calibrating extrusion",
    13: "Homing", 14: "Cleaning nozzle",
    22: "Unloading filament", 24: "Loading filament",
    49: "Heating chamber", 77: "Preparing AMS",
}


def quiet_hours_active(config: Config, now: datetime | None = None) -> bool:
    if not config.data.get("quiet_hours_enabled", True): return False
    current = (now or datetime.now()).strftime("%H:%M")
    start = str(config.data.get("quiet_hours_start", "22:00"))
    end = str(config.data.get("quiet_hours_end", "07:00"))
    return start <= current < end if start < end else current >= start or current < end

class PrinterDialog(Gtk.Dialog):
    def __init__(self, app: "Gantry", printer: Printer | None = None) -> None:
        super().__init__(title=i18n.t("Edit printer") if printer else i18n.t("Add printer"), transient_for=app.window, modal=False)
        self.app, self.printer = app, printer
        self.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
        self.add_button(i18n.t("Save"), Gtk.ResponseType.OK)
        self.set_default_size(590, 620)
        box = self.get_content_area(); box.set_spacing(10); box.set_border_width(18)

        self.kind_label = Gtk.Label(label=i18n.t("Printer type"), xalign=0)
        box.pack_start(self.kind_label, False, False, 0)
        self.kind = Gtk.ComboBoxText()
        for value, label in (("bambu", "Bambu Lab"), ("elegoo", "Elegoo"),
                             (PrinterKind.ANYCUBIC_KOBRA_S1.value, "Anycubic"),
                             ("klipper", "Klipper / Moonraker"),
                             ("prusa", "Prusa / PrusaLink"), ("snapmaker", "Snapmaker")):
            self.kind.append(value, label)
        selected_brand = "elegoo" if printer and printer.kind in {PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2} \
            else (printer.kind if printer else PrinterKind.BAMBU).value
        self.kind.set_active_id(selected_brand)
        self.kind.connect("changed", lambda _combo: self._apply_kind())
        box.pack_start(self.kind, False, False, 0)
        self.elegoo_model_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.elegoo_model_row.pack_start(Gtk.Label(
            label=i18n.t("Elegoo model"), xalign=0), False, False, 0)
        self.elegoo_model = Gtk.ComboBoxText()
        self.elegoo_model.append(PrinterKind.ELEGOO_CC1.value, "Centauri Carbon")
        self.elegoo_model.append(PrinterKind.ELEGOO_CC2.value, "Centauri Carbon 2")
        self.elegoo_model.set_active_id(printer.kind.value if printer and printer.kind in {
            PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2} else PrinterKind.ELEGOO_CC1.value)
        self.elegoo_model.connect("changed", lambda _combo: self._apply_kind())
        self.elegoo_model_row.pack_start(self.elegoo_model, False, False, 0)
        box.pack_start(self.elegoo_model_row, False, False, 0)
        csv_button = Gtk.Button(label=i18n.t("Import multiple printers from CSV"))
        csv_button.connect("clicked", lambda _button: app.import_csv_on_screen(self))
        box.pack_start(csv_button, False, False, 0)

        self.bambu_section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.combo = Gtk.ComboBoxText(); self.combo.append("manual", i18n.t("Scanning for printers…")); self.combo.set_active(0)
        self.combo.connect("changed", self._selected)
        self.bambu_section.pack_start(Gtk.Label(label=i18n.t("Discovered printers"), xalign=0), False, False, 0)
        self.bambu_section.pack_start(self.combo, False, False, 0)
        self.targets = Gtk.Entry(text=str(app.config.data.get("scan_targets", "")))
        self.targets.set_placeholder_text("100.71.10.5")
        self.bambu_section.pack_start(Gtk.Label(label=i18n.t("Additional VPN targets"), xalign=0), False, False, 0)
        self.bambu_section.pack_start(self.targets, False, False, 0)
        hint = Gtk.Label(label=i18n.t("IP, a-b range or CIDR /n (up to 1024 addresses)"), xalign=0); hint.get_style_context().add_class("meta")
        self.bambu_section.pack_start(hint, False, False, 0)
        # Reading the slicer config is opt-in: it holds access codes, so gate the import button on consent.
        self.import_consent = Gtk.CheckButton(label=i18n.t("Allow reading the Bambu Studio configuration"))
        import_hint = Gtk.Label(label=i18n.t("Speeds up adding, but reads the local slicer file containing access codes. Nothing is read until you tick this."), xalign=0, wrap=True); import_hint.get_style_context().add_class("meta")
        self.bambu_section.pack_start(self.import_consent, False, False, 0)
        self.bambu_section.pack_start(import_hint, False, False, 0)
        buttons = Gtk.Box(spacing=8)
        rescan = Gtk.Button(label=i18n.t("Scan network")); rescan.connect("clicked", lambda _b: self.start_scan())
        self.import_button = Gtk.Button(label=i18n.t("Import from Bambu Studio")); self.import_button.connect("clicked", lambda _b: self._import())
        self.import_button.set_sensitive(False)
        self.import_consent.connect("toggled", lambda cb: self.import_button.set_sensitive(cb.get_active()))
        buttons.pack_start(rescan, False, False, 0); buttons.pack_start(self.import_button, False, False, 0)
        self.bambu_section.pack_start(buttons, False, False, 0)
        box.pack_start(self.bambu_section, False, False, 0)

        self.fields: dict[str, Gtk.Entry] = {}
        self.rows: dict[str, Gtk.Box] = {}
        defaults = {"name": printer.name if printer else "", "host": printer.host if printer else "",
                    "serial": printer.serial if printer and printer.kind in {
                        PrinterKind.BAMBU, PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2} else "",
                    "code": "", "port": str(printer.port if printer else 8883)}
        for key in ("name", "host", "serial", "code", "port"):
            row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            label = Gtk.Label(label=i18n.t(FIELD_LABELS[key]), xalign=0); row.pack_start(label, False, False, 0)
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
        self.progress_check = Gtk.CheckButton(
            label=(i18n.t("Show this printer's progress in the system panel")))
        self.progress_check.set_no_show_all(True)
        self.progress_check.set_active(bool(printer and app.config.is_progress_pinned(printer.serial)))
        self.progress_check.set_visible(printer is not None)
        box.pack_start(self.progress_check, False, False, 0)
        self.error = Gtk.Label(xalign=0, wrap=True); self.error.get_style_context().add_class("status")
        box.pack_start(self.error, False, False, 0)
        self.discovered: list[Printer] = []
        self.show_all(); self._apply_kind()
        if printer:
            # Keep the brand fixed while editing, like macOS/Windows. The Elegoo generation
            # selector remains available, matching the reference implementation.
            self.kind_label.set_visible(False)
            self.kind.set_visible(False)
        if not printer: self.start_scan()

    @property
    def selected_kind(self) -> PrinterKind:
        value = self.kind.get_active_id() or "bambu"
        if value == "elegoo": value = self.elegoo_model.get_active_id() or PrinterKind.ELEGOO_CC1.value
        try: return PrinterKind(value)
        except ValueError: return PrinterKind.BAMBU

    def _apply_kind(self) -> None:
        kind = self.selected_kind
        is_elegoo = kind in {PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2}
        self.elegoo_model_row.set_visible(self.kind.get_active_id() == "elegoo")
        self.bambu_section.set_visible(kind == PrinterKind.BAMBU or is_elegoo)
        self.rows["serial"].set_visible(kind == PrinterKind.BAMBU or is_elegoo)
        # Snapmaker authorizes via the printer's touchscreen — no access code / API key field.
        self.rows["code"].set_visible(kind not in {PrinterKind.SNAPMAKER, PrinterKind.ELEGOO_CC1,
                                                    PrinterKind.ANYCUBIC_KOBRA_S1})
        defaults = {PrinterKind.BAMBU: 8883, PrinterKind.KLIPPER: 7125,
                    PrinterKind.PRUSA: 80, PrinterKind.SNAPMAKER: 8080,
                    PrinterKind.ELEGOO_CC1: 3030, PrinterKind.ELEGOO_CC2: 1883,
                    PrinterKind.ANYCUBIC_KOBRA_S1: 18910}
        if not self.printer or self.printer.kind != kind:
            self.fields["port"].set_text(str(defaults[kind]))
        if kind == PrinterKind.BAMBU:
            self.code_label.set_text(i18n.t("Access code / API key").split(" /")[0])
            self.info.set_text(i18n.t("MQTT/TLS • port 8883. Enter an additional VPN address above and scan again."))
        elif kind == PrinterKind.KLIPPER:
            self.code_label.set_text(i18n.t("API key (optional)"))
            self.info.set_text(i18n.t("Moonraker • port 7125. Happy Hare MMU and Creality CFS are detected automatically."))
        elif kind == PrinterKind.PRUSA:
            self.code_label.set_text(i18n.t("PrusaLink API key"))
            self.info.set_text(i18n.t("PrusaLink • port 80 • local connection, no Prusa account required."))
        elif kind == PrinterKind.SNAPMAKER:
            self.info.set_text(i18n.t("Snapmaker 2.0 / Artisan • HTTP, port 8080. After adding, the PRINTER SCREEN shows a permission request — tap “Allow” to authorize. Re-authorize after each power cycle."))
        elif kind == PrinterKind.ELEGOO_CC1:
            self.info.set_text(i18n.t("Elegoo Centauri Carbon • SDCP WebSocket, port 3030 • no access code. Camera: port 3031."))
        elif kind == PrinterKind.ELEGOO_CC2:
            self.code_label.set_text(i18n.t("Elegoo access code"))
            self.info.set_text(i18n.t("Elegoo Centauri Carbon 2 • MQTT LAN, port 1883. Enable LAN-only mode on the printer. Camera: MJPEG 8080."))
        else:
            self.info.set_text(i18n.t("Anycubic Kobra S1 • enter its IP address and enable LAN mode on the printer. Gantry obtains the MQTT identifiers and credentials automatically (bootstrap 18910). Camera: FLV 18088."))

    def start_scan(self) -> None:
        if self.selected_kind not in {PrinterKind.BAMBU, PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2}: return
        try:
            expand_scan_targets(self.targets.get_text())
        except ValueError:
            self.error.set_text(i18n.t("Check the required fields and port range.")); return
        targets = self.targets.get_text().strip()
        self.app.config.data["scan_targets"] = targets; self.app.config.save()
        self.combo.remove_all(); self.combo.append("manual", i18n.t("Scanning for printers…")); self.combo.set_active(0)
        def work() -> None:
            values = scan(targets)
            selected = self.selected_kind
            if selected == PrinterKind.BAMBU: values = [value for value in values if value.kind == PrinterKind.BAMBU]
            else: values = [value for value in values if value.kind == selected]
            GLib.idle_add(self._scan_done, values)
        threading.Thread(target=work, daemon=True).start()

    def _scan_done(self, values: list[Printer]) -> bool:
        self.discovered = values; self.combo.remove_all(); self.combo.append("manual", i18n.t("No printers found") if not values else "—")
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
            self.error.set_text(i18n.t("Bambu Studio configuration or stored printers were not found.")); return
        imported = 0
        for serial, code, host in values:
            if not host: continue
            printer = Printer(serial=serial, name=f"Bambu {serial[-4:]}", host=host)
            try: self.app.secrets.set(serial, code)
            except SecretStoreError: continue
            self.app.upsert_printer(printer); imported += 1
        if imported:
            self.destroy(); self.app.reconnect_all()
        else: self.error.set_text(i18n.t("Bambu Studio configuration or stored printers were not found."))

    def value(self) -> tuple[Printer, str] | None:
        values = {key: field.get_text().strip() for key, field in self.fields.items()}
        kind = self.selected_kind
        try: port = int(values["port"])
        except ValueError: port = 0
        serial = values["serial"] if kind in {PrinterKind.BAMBU, PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2} \
            else (f"anycubic-kobra-s1-{values['host']}" if kind == PrinterKind.ANYCUBIC_KOBRA_S1
                  else f"{kind.value}-{values['host']}-{port}")
        secret_required = kind in {PrinterKind.BAMBU, PrinterKind.PRUSA, PrinterKind.ELEGOO_CC2}
        if not values["name"] or not values["host"] or not serial or not 1 <= port <= 65535 or (secret_required and not values["code"] and not self.printer):
            self.error.set_text(i18n.t("Check the required fields and port range.")); return None
        model = {PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper",
                 PrinterKind.PRUSA: "Prusa", PrinterKind.SNAPMAKER: "Snapmaker",
                 PrinterKind.ELEGOO_CC1: "Elegoo Centauri Carbon",
                 PrinterKind.ELEGOO_CC2: "Elegoo Centauri Carbon 2",
                 PrinterKind.ANYCUBIC_KOBRA_S1: "Anycubic Kobra S1"}[kind]
        return Printer(serial, values["name"], values["host"], model=model, port=port, kind=kind), values["code"]



# Clean port of the current macOS dashboard implementation. Re-exporting the helpers preserves the
# public surface used by preview scripts and detail widgets while app.py stays the Linux orchestrator.
from .dashboard import (  # noqa: E402
    CompactPrinterRow as CompactPrinterRow,
    Dashboard as Dashboard,
    PrinterCard as PrinterCard,
    _contrast_ink as _contrast_ink,
    _muted_hex as _muted_hex,
    css_for as css_for,
)
from .settings import SettingsDialog as SettingsDialog  # noqa: E402


class Gantry:
    def __init__(self, background: bool = False) -> None:
        self.config, self.secrets = Config(), SecretStore()
        from .insights import PrinterInsights
        self.insights = PrinterInsights(self)
        self.language = str(self.config.data.get("language", "pl"))
        i18n.set_language(self.language)
        self.printers = self.config.printers
        self.telemetry = {printer.serial: Telemetry() for printer in self.printers}
        self.connection_reasons: dict[str, str] = {}
        self.connections: dict[str, object] = {}; self.cards: dict[str, PrinterCard] = {}
        self.indicator_available = AppIndicator is not None
        self.stages = STAGES
        # Rolling temperature history per printer (time, nozzle, bed, chamber), drawn by the Details graph.
        self.temp_history: dict[str, list[tuple[float, float | None, float | None, float | None]]] = {}
        self.detail_window: Any | None = None
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
        from .telegram import TelegramBot
        self.telegram_bot = TelegramBot(self)
        self.telegram_bot.sync()
        # Optional always-on-top strip at a screen edge. It owns its own visibility, so creating it
        # unconditionally is safe: with the setting off it simply never shows itself.
        from .edgedock import EdgeDock
        self.edge_dock = EdgeDock(self)
        self.edge_dock.refresh()
        GLib.timeout_add_seconds(45, self._sync_tick)
        GLib.timeout_add_seconds(8, self._initial_update_check)
        GLib.timeout_add_seconds(6 * 3600, self._periodic_update_check)
        if AppIndicator is None and not background:
            self.window.show_all()

    def _sync_tick(self) -> bool:
        try:
            self.sync_service.sync_now()
        except Exception:
            pass
        return True  # keep the periodic timer running

    def _initial_update_check(self) -> bool:
        if bool(self.config.data.get("auto_update_check", False)):
            self.check_updates_background()
        return False

    def _periodic_update_check(self) -> bool:
        if bool(self.config.data.get("auto_update_check", False)):
            self.check_updates_background()
        return True

    def check_updates_background(self) -> None:
        if getattr(self, "_update_check_running", False):
            return
        self._update_check_running = True

        def work() -> None:
            try:
                from .updater import is_newer, latest_release
                release = latest_release()
                if is_newer(release.version, __version__):
                    GLib.idle_add(self._announce_update, release.version)
            except Exception:
                pass
            finally:
                self._update_check_running = False

        threading.Thread(target=work, daemon=True).start()

    def _announce_update(self, version: str) -> bool:
        if self.config.data.get("update_notified_version") == version:
            return False
        self.config.data["update_notified_version"] = version
        self.config.save()
        body = i18n.t("Version {0} is available. Open Settings → Updates.").format(version)
        self.notify("Gantry", body)
        return False

    @staticmethod
    def _panel_alpha(level: object) -> float:
        return {"low": 0.82, "medium": 0.68, "high": 0.52}.get(str(level), 0.82)

    def _install_theme_css(self, theme: str, alpha: float) -> None:
        """Replace the application provider instead of stacking a new provider every frame."""
        screen = Gdk.Screen.get_default()
        previous = getattr(self, "_theme_provider", None)
        if previous is not None:
            Gtk.StyleContext.remove_provider_for_screen(screen, previous)
        provider = Gtk.CssProvider()
        provider.load_from_data(css_for(theme, alpha))
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self._theme_provider = provider

    def _stop_transparency_animation(self) -> None:
        source = getattr(self, "_transparency_animation_id", None)
        if source is not None:
            GLib.source_remove(source)
            self._transparency_animation_id = None

    def apply_theme(self, panel_transparency: object | None = None, animate: bool = False) -> None:
        theme = str(self.config.data.get("theme", "dark"))
        settings = Gtk.Settings.get_default()
        settings.set_property("gtk-application-prefer-dark-theme", theme == "dark")
        # Background-only alpha for the frosted-glass popover (cards stay solid). Lower = more see-through:
        # low is the most opaque glass, high shows the compositor blur most. Not a whole-window opacity.
        level = (self.config.data.get("panel_transparency", "low")
                 if panel_transparency is None else panel_transparency)
        target_alpha = self._panel_alpha(level)
        # Give the panel window an RGBA visual so the translucent backdrop shows the desktop through
        # (needs a running compositor; falls back to opaque otherwise). Cards stay solid.
        window = getattr(self, "window", None)
        if window is not None and target_alpha < 1.0:
            rgba = window.get_screen().get_rgba_visual()
            if rgba is not None:
                window.set_visual(rgba)

        self._stop_transparency_animation()
        start_alpha = getattr(self, "_current_panel_alpha", None)
        if not animate or start_alpha is None or abs(start_alpha - target_alpha) < 0.001:
            self._current_panel_alpha = target_alpha
            self._install_theme_css(theme, target_alpha)
            return

        started_at = time.monotonic()
        duration = 0.20

        def animation_frame() -> bool:
            progress = min(1.0, (time.monotonic() - started_at) / duration)
            eased = 1.0 - (1.0 - progress) ** 3  # cubic ease-out, matching Windows
            alpha = start_alpha + (target_alpha - start_alpha) * eased
            self._current_panel_alpha = alpha
            self._install_theme_css(theme, alpha)
            if progress >= 1.0:
                self._transparency_animation_id = None
                return False
            return True

        self._transparency_animation_id = GLib.timeout_add(16, animation_frame)

    def preview_panel_transparency(self, level: object) -> None:
        """Animate the panel immediately; the settings dialog persists the same value live."""
        self.apply_theme(panel_transparency=level, animate=True)

    def _tray(self) -> None:
        if getattr(self, "indicator", None) is not None:
            self.indicator.set_status(AppIndicator.IndicatorStatus.PASSIVE)
        menu = Gtk.Menu()
        panel_label =i18n.t("Gantry panel")
        item = Gtk.MenuItem(label=panel_label); item.connect("activate", lambda *_: self.toggle_panel()); menu.append(item)
        if bool(self.config.data.get("spoolbase_enabled", True)):
            spoolbase_label =i18n.t("Spoolbase — filament stock")
            item = Gtk.MenuItem(label=spoolbase_label); item.connect("activate", lambda *_: self.toggle_spoolbase()); menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())

        for label, callback in ((i18n.t("Scan network"), lambda *_: self.scan_and_import()),
                                (i18n.t("Add printer"), lambda *_: self.open_printer_dialog())):
            item = Gtk.MenuItem(label=label); item.connect("activate", callback); menu.append(item)
        reconnect = Gtk.MenuItem(label=i18n.t("Reconnect (all)"))
        reconnect.connect("activate", lambda *_: self.reconnect_all()); menu.append(reconnect)
        diagnostics = Gtk.MenuItem(label=i18n.t("Diagnostic Center…"))
        diagnostics.connect("activate", lambda *_: self.open_diagnostics()); menu.append(diagnostics)
        stats = Gtk.MenuItem(label=i18n.t("Fleet statistics…"))
        stats.connect("activate", lambda *_: self.open_fleet_stats()); menu.append(stats)
        menu.append(Gtk.SeparatorMenuItem())

        language = Gtk.MenuItem(label=i18n.t("Language: EN"))
        language.connect("activate", lambda *_: self._toggle_language()); menu.append(language)
        quiet = Gtk.CheckMenuItem(label=i18n.t("Quiet hours")); quiet.set_active(bool(self.config.data.get("quiet_hours_enabled", True)))
        quiet.connect("toggled", lambda item: self._toggle_quiet(item.get_active())); menu.append(quiet)
        updates = Gtk.MenuItem(label=(i18n.t("Check for updates…")))
        updates.connect("activate", lambda *_: self.check_updates_background()); menu.append(updates)
        settings = Gtk.MenuItem(label=i18n.t("Settings")); settings.connect("activate", lambda *_: self.open_settings()); menu.append(settings)
        legend = Gtk.MenuItem(label=i18n.t("Color legend"))
        legend_menu = Gtk.Menu()
        for label in ("Blue — printing (live data)", "Green — ready / finished",
                      "Orange — paused, stale data, or AMS humidity", "Red — printer error",
                      "Gray — offline / none / neutral"):
            item = Gtk.MenuItem(label=i18n.t(label)); item.set_sensitive(False); legend_menu.append(item)
        legend_menu.append(Gtk.SeparatorMenuItem())
        slot_header = Gtk.MenuItem(label=i18n.t("Filament slots:"))
        slot_header.set_sensitive(False); legend_menu.append(slot_header)
        for label in ("White ring — active slot",):
            item = Gtk.MenuItem(label=i18n.t(label)); item.set_sensitive(False); legend_menu.append(item)
        legend.set_submenu(legend_menu); menu.append(legend)
        support = Gtk.MenuItem(label=i18n.t("Support the project ☕"))
        support.connect("activate", lambda *_: Gtk.show_uri_on_window(
            None, "https://buycoffee.to/parametryczny", Gdk.CURRENT_TIME)); menu.append(support)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label=(i18n.t("Quit Gantry")))
        quit_item.connect("activate", lambda *_: self.quit()); menu.append(quit_item)
        menu.show_all()
        if AppIndicator:
            installed_icon = Path("/usr/share/icons/hicolor/scalable/apps/gantry.svg")
            local_icons = Path(__file__).resolve().parent.parent / "assets"
            icon = str(installed_icon) if installed_icon.exists() else str(local_icons / "gantry.svg")
            self.indicator = AppIndicator.Indicator.new("gantry", icon, AppIndicator.IndicatorCategory.APPLICATION_STATUS)
            self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE); self.indicator.set_menu(menu)
        self._refresh_progress_indicators()

    def _toggle_language(self) -> None:
        self.language = "en" if self.language == "pl" else "pl"
        i18n.set_language(self.language)
        self.config.data["language"] = self.language
        self.config.save()
        self.rebuild_cards(); self._tray()

    def _refresh_progress_indicators(self) -> None:
        existing = getattr(self, "progress_indicators", {})
        if AppIndicator is None:
            for indicator in existing.values():
                indicator.set_status(AppIndicator.IndicatorStatus.PASSIVE) if AppIndicator else None
            self.progress_indicators = {}
            return
        valid = [printer.serial for printer in self.printers]
        self.config.prune_progress_pins(valid)
        pinned = set(self.config.progress_serials())
        ordered = [printer for printer in self.printers if printer.serial in pinned]
        first = ordered[0] if ordered else None
        extras = {printer.serial: printer for printer in ordered[1:]}
        if getattr(self, "indicator", None) is not None:
            if first is None:
                self.indicator.set_label("", "")
            else:
                tel = self.telemetry.get(first.serial, Telemetry())
                suffix = f" {tel.progress}%" if tel.state in {PrinterState.PRINTING, PrinterState.PAUSED} else ""
                self.indicator.set_label(first.name + suffix, first.name + " 100%")
        for serial in set(existing) - set(extras):
            existing[serial].set_status(AppIndicator.IndicatorStatus.PASSIVE)
            del existing[serial]
        installed_icon = Path("/usr/share/icons/hicolor/scalable/apps/gantry.svg")
        local_icons = Path(__file__).resolve().parent.parent / "assets"
        icon = str(installed_icon) if installed_icon.exists() else str(local_icons / "gantry.svg")
        for serial, printer in extras.items():
            indicator = existing.get(serial)
            if indicator is None:
                indicator = AppIndicator.Indicator.new(
                    "gantry-progress-" + "".join(char if char.isalnum() else "-" for char in serial),
                    icon, AppIndicator.IndicatorCategory.APPLICATION_STATUS)
                popup = Gtk.Menu()
                details = Gtk.MenuItem(label=i18n.t("Details"))
                details.connect("activate", lambda *_, value=serial: self.open_details(value))
                popup.append(details); popup.show_all(); indicator.set_menu(popup)
                indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
                existing[serial] = indicator
            tel = self.telemetry.get(serial, Telemetry())
            suffix = f" {tel.progress}%" if tel.state in {PrinterState.PRINTING, PrinterState.PAUSED} else ""
            indicator.set_label(printer.name + suffix, f"{printer.name} 100%")
        self.progress_indicators = existing

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
        """Send a normalized/raw command through the printer's live transport."""
        connection = self.connections.get(serial)
        printer = next((p for p in self.printers if p.serial == serial), None)
        if printer is not None and printer.kind in {PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2}:
            method = getattr(connection, "send_method", None)
            if callable(method):
                try:
                    payload = json.loads(json_str)
                    if isinstance(payload, dict) and "method" in payload:
                        return bool(method(int(payload["method"]), payload.get("params") or {}))
                except (json.JSONDecodeError, TypeError, ValueError):
                    return False
                lowered = json_str.lower()
                if '"command":"pause"' in lowered: action = 129 if printer.kind == PrinterKind.ELEGOO_CC1 else 1021
                elif '"command":"resume"' in lowered: action = 131 if printer.kind == PrinterKind.ELEGOO_CC1 else 1023
                elif '"command":"stop"' in lowered: action = 130 if printer.kind == PrinterKind.ELEGOO_CC1 else 1022
                else: return False
                return bool(method(action, {}))
        if printer is not None and printer.kind == PrinterKind.ANYCUBIC_KOBRA_S1:
            action = getattr(connection, "send_action", None)
            if not callable(action): return False
            lowered = json_str.lower()
            if '"command":"pause"' in lowered: return bool(action("pause"))
            if '"command":"resume"' in lowered: return bool(action("resume"))
            if '"command":"stop"' in lowered: return bool(action("stop"))
            return False
        sender = getattr(connection, "send_command", None)
        return bool(sender(json_str)) if callable(sender) else False

    def send_gcode(self, serial: str, script: str) -> bool:
        """Run a G-code line on a Klipper printer via Moonraker."""
        connection = self.connections.get(serial)
        sender = getattr(connection, "send_gcode", None)
        return bool(sender(script)) if callable(sender) else False

    def set_chamber_light(self, serial: str, on: bool) -> None:
        printer = next((p for p in self.printers if p.serial == serial), None)
        from .overrides import overrides_for
        custom = overrides_for(self.config, serial).get("ledOn" if on else "ledOff")
        if custom:
            if printer is not None and printer.kind == PrinterKind.KLIPPER:
                self.send_gcode(serial, custom)
            else:
                self.send_command(serial, custom)
            return
        if printer is not None and printer.kind == PrinterKind.KLIPPER:
            self.send_gcode(serial, "SET_PIN PIN=caselight VALUE=1" if on else "SET_PIN PIN=caselight VALUE=0")
        elif printer is not None and printer.kind in {PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2}:
            connection = self.connections.get(serial)
            sender = getattr(connection, "send_method", None)
            if callable(sender):
                if printer.kind == PrinterKind.ELEGOO_CC1:
                    sender(403, {"LightStatus": {"SecondLight": 1 if on else 0}})
                else:
                    sender(1029, {"power": 1 if on else 0})
        elif printer is not None and printer.kind == PrinterKind.ANYCUBIC_KOBRA_S1:
            sender = getattr(self.connections.get(serial), "set_light", None)
            if callable(sender): sender(on)
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
            what = i18n.t("a script on this computer") if is_script else i18n.t("a printer command")
            body = i18n.t("Automation \"{0}\" wants to run {1}:\n\n{2}\n\nAllow and remember?").format(
                rule.get("name"), what, preview)
            dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                       message_type=Gtk.MessageType.WARNING, buttons=Gtk.ButtonsType.NONE,
                                       text=(i18n.t("Confirm automation")))
            dialog.format_secondary_text(body)
            dialog.add_button(i18n.t("Deny"), Gtk.ResponseType.CANCEL)
            dialog.add_button(i18n.t("Allow"), Gtk.ResponseType.OK)
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

    def open_advanced(self, serial: str) -> None:
        from .advanced import AdvancedDialog
        dialogs = getattr(self, "advanced_dialogs", {})
        existing = dialogs.get(serial)
        if existing is not None:
            existing.present(); return
        dialog = AdvancedDialog(self, serial)
        dialogs[serial] = dialog
        self.advanced_dialogs = dialogs
        dialog.set_modal(False)
        self.window._suppress_hide = True
        def destroyed(*_args: object) -> None:
            dialogs.pop(serial, None)
            self.window._suppress_hide = False
        dialog.connect("destroy", destroyed)
        def respond(_dialog: Gtk.Dialog, response: int) -> None:
            if response == Gtk.ResponseType.OK:
                dialog.save()
                self.reconnect_all()
                if self.detail_window is not None and self.detail_window.serial == serial:
                    self.open_details(serial)
            dialog.destroy()
        dialog.connect("response", respond)
        dialog.show_all()
        dialog.present()

    def open_fleet_stats(self) -> None:
        from .fleetstats import FleetStatsDialog
        dialog = FleetStatsDialog(self)
        dialog.run()
        dialog.destroy()

    def open_details(self, serial: str) -> None:
        from .details import DetailPanel
        tel = self.telemetry.get(serial, Telemetry())
        panel = DetailPanel(self, serial, on_back=self.window.show_fleet)
        panel.update(tel)
        self.detail_window = panel
        self.window.show_detail(panel)

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
        columns = 1 if compact else max(1, min(2, int(self.config.data.get("dashboard_columns", 2))))
        placements = place_cards([printer.serial for printer in self.printers], self.telemetry, columns, compact)
        for printer, placement in zip(self.printers, placements):
            card = (CompactPrinterRow(self, printer, self.expanded_compact_serial == printer.serial)
                    if compact else PrinterCard(self, printer))
            card.set_hexpand(True)
            card.set_vexpand(True)
            self.cards[printer.serial] = card
            telemetry = self.telemetry.get(printer.serial, Telemetry())
            self.window.grid.attach(card, placement.column, placement.row, placement.span, 1)
            if printer.serial in self.telemetry: card.update(self.telemetry[printer.serial])
        # Show the card widgets, but don't force the popover window open on every rebuild.
        self.window.update_header(); self.window.grid.show_all(); self.window.resize_for_content()

    @staticmethod
    def _needs_wide(telemetry: Telemetry) -> bool:
        return needs_wide(telemetry)

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
        existing = getattr(self, "printer_dialog", None)
        if existing is not None:
            existing.present(); return
        dialog = PrinterDialog(self, printer)
        self.printer_dialog = dialog
        self.window._suppress_hide = True
        def destroyed(*_args: object) -> None:
            self.printer_dialog = None
            self.window._suppress_hide = False
        dialog.connect("destroy", destroyed)
        def respond(_dialog: Gtk.Dialog, response: int) -> None:
            if response in (Gtk.ResponseType.CANCEL, Gtk.ResponseType.DELETE_EVENT):
                dialog.destroy(); return
            value = dialog.value()
            if not value: return
            updated, code = value
            try:
                try:
                    existing_code = self.secrets.get(printer.serial) if printer else None
                except SecretStoreError:
                    if updated.kind not in {PrinterKind.KLIPPER, PrinterKind.ELEGOO_CC1}: raise
                    existing_code = None
                credential = code or existing_code
                if updated.kind in {PrinterKind.BAMBU, PrinterKind.PRUSA, PrinterKind.ELEGOO_CC2} and not credential:
                    dialog.error.set_text(i18n.t("Access code / API key")); return
                if printer and printer.serial != updated.serial:
                    self.remove_printer(printer)
                if credential:
                    self.secrets.set(updated.serial, credential)
            except SecretStoreError:
                dialog.error.set_text(i18n.t("Could not store the code in the system keyring.")); return
            self.upsert_printer(updated)
            if printer is not None:
                self.config.set_progress_pinned(updated.serial, dialog.progress_check.get_active())
                self._refresh_progress_indicators()
            dialog.destroy(); self.reconnect_all(); return
        dialog.connect("response", respond)
        dialog.present()

    @staticmethod
    def _automatic_printer_name(name: str) -> bool:
        value = name.strip()
        if not value.lower().startswith("bambu "):
            return not value
        suffix = value[6:]
        return len(suffix) <= 6 and suffix.isalnum()

    def refresh_printer_names(self) -> None:
        targets = str(self.config.data.get("scan_targets", ""))

        def apply(values: list[Printer]) -> bool:
            changed = False
            by_serial = {value.serial: value for value in values}
            for current in self.printers:
                found = by_serial.get(current.serial)
                if found is None or not self._automatic_printer_name(current.name) \
                        or self._automatic_printer_name(found.name):
                    continue
                current.name = found.name
                if found.model != "Bambu Lab": current.model = found.model
                changed = True
            if changed:
                self.config.printers = self.printers
                self.rebuild_cards()
            return False

        def work() -> None:
            try: values = scan(targets)
            except Exception: return
            GLib.idle_add(apply, values)

        threading.Thread(target=work, name="gantry-refresh-names", daemon=True).start()

    def reconnect_and_refresh(self) -> None:
        self.reconnect_all()
        self.refresh_printer_names()

    def confirm_remove_printer(self, printer: Printer, parent: Gtk.Window | Gtk.Dialog | None = None) -> bool:
        pl = self.language == "pl"
        dialog = Gtk.MessageDialog(
            transient_for=parent or self.window, modal=True, message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.NONE,
            text=(i18n.t("Remove printer {0}?").format(printer.name)))
        dialog.format_secondary_text(i18n.t("This printer's saved access code and certificate pin will be removed."))
        dialog.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
        dialog.add_button(i18n.t("Remove"), Gtk.ResponseType.OK)
        result = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        if result: self.remove_printer(printer)
        return result

    def remove_printer(self, printer: Printer) -> None:
        connection = self.connections.pop(printer.serial, None)
        if connection: connection.stop()
        self.printers = [value for value in self.printers if value.serial != printer.serial]
        self.telemetry.pop(printer.serial, None)
        try: self.secrets.delete(printer.serial)
        except SecretStoreError: pass
        if printer.kind == PrinterKind.BAMBU: self.config.remove_pin(printer.serial)
        self.config.printers = self.printers
        self.config.prune_progress_pins([value.serial for value in self.printers])
        self.rebuild_cards(); self._refresh_progress_indicators()

    def reset_completed(self) -> None:
        """Tidy the fleet: drop the last job name from printers that are not printing/paused and rebuild,
        so finished/idle cards read clean (the macOS 'Wyczyść zakończone' button)."""
        for tel in self.telemetry.values():
            if tel.state not in (PrinterState.PRINTING, PrinterState.PAUSED):
                tel.job_name = None
        self.rebuild_cards()

    def reconnect_all(self) -> None:
        for connection in self.connections.values(): connection.stop()
        self.connections = {}
        for printer in self.printers:
            self._start_connection(printer)

    def reconnect_printer(self, serial: str) -> None:
        connection = self.connections.pop(serial, None)
        if connection: connection.stop()
        printer = next((value for value in self.printers if value.serial == serial), None)
        if printer is not None: self._start_connection(printer)

    def _start_connection(self, printer: Printer) -> None:
        try: code = self.secrets.get(printer.serial)
        except SecretStoreError: code = None
        callback = lambda event, value, serial=printer.serial: GLib.idle_add(self.on_event, serial, event, value)
        if printer.kind == PrinterKind.BAMBU:
            if not code: return
            connection = MqttConnection(printer, code, self.config, callback)
        elif printer.kind == PrinterKind.ELEGOO_CC1:
            from .elegoo import ElegooCC1Connection
            connection = ElegooCC1Connection(printer, callback)
        elif printer.kind == PrinterKind.ELEGOO_CC2:
            if not code: return
            from .elegoo import ElegooCC2Connection
            connection = ElegooCC2Connection(printer, code, callback)
        elif printer.kind == PrinterKind.ANYCUBIC_KOBRA_S1:
            from .anycubic import AnycubicS1Connection
            connection = AnycubicS1Connection(printer, callback)
        elif printer.kind == PrinterKind.PRUSA:
            if not code: return
            connection = HttpConnection(printer, code, callback)
        else:
            from .overrides import moonraker_objects, overrides_for
            objects = moonraker_objects(overrides_for(self.config, printer.serial)) \
                if printer.kind == PrinterKind.KLIPPER else None
            connection = HttpConnection(printer, code, callback, objects)
        self.connections[printer.serial] = connection; connection.start()

    def on_event(self, serial: str, event: str, value: object | None) -> bool:
        previous = self.telemetry.get(serial, Telemetry())
        if event == "telemetry" and isinstance(value, Telemetry):
            self.telemetry[serial] = value; self.connection_reasons.pop(serial, None)
        elif event == "disconnected":
            self.telemetry[serial] = Telemetry(state=PrinterState.OFFLINE)
            self.connection_reasons[serial] = str(value or (i18n.t("Disconnected")))
        current = self.telemetry[serial]
        if event == "telemetry":
            self._record_temperature(serial, current)
            self.insights.observe(serial, previous, current)
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
        self._refresh_progress_indicators()
        dock = getattr(self, "edge_dock", None)
        if dock is not None:
            dock.refresh()
        if quiet_hours_active(self.config): return False
        printer_name = next((p.name for p in self.printers if p.serial == serial), "Gantry")
        # Heads-up before the end. Armed once per print: it re-arms as soon as the remaining time is
        # back above the threshold (a new job) or the printer stops printing, so one job cannot nag.
        warned = getattr(self, "_finishing_soon_warned", None)
        if warned is None:
            warned = self._finishing_soon_warned = set()
        threshold = int(self.config.data.get("notify_finishing_soon_minutes", 10) or 10)
        remaining = current.remaining_minutes if current.remaining_minutes is not None else 10 ** 9
        if current.state == PrinterState.PRINTING and 0 < remaining <= threshold:
            if self.config.data.get("notify_finishing_soon", False) and serial not in warned:
                warned.add(serial)
                body = current.job_name or (i18n.t("The print is nearly done."))
                title = (f"Koniec za ~{remaining} min" if self.language == "pl"
                         else f"Finishing in ~{remaining} min")
                self.notify(printer_name, f"{title}: {body}")
                from . import telegram
                telegram.notify(self, printer_name, title, body)
        else:
            warned.discard(serial)
        if current.state != previous.state:
            if current.state == PrinterState.FINISHED:
                from . import telegram
                telegram.record_history(self, serial, printer_name, current.job_name or "")
            key = {PrinterState.FINISHED: "notify_finished", PrinterState.ERROR: "notify_error",
                   PrinterState.PAUSED: "notify_paused", PrinterState.OFFLINE: "notify_offline"}.get(current.state)
            if key and self.config.data.get(key):
                body = i18n.t(STATE_LABELS.get(current.state.value, current.state.value))
                if current.state == PrinterState.ERROR and current.hms_codes:
                    from .hms import description
                    body = description(current.hms_codes, serial, self.language) or body
                self.notify(printer_name, body)
                from . import telegram
                telegram.notify(self, printer_name, body, "")
            if event == "telemetry" and getattr(self, "physical_spools", None) is not None:
                from .consumption import on_finish
                on_finish(self, serial, previous, current)
        previous_remaining = {slot.slot_id: slot.remaining for slot in previous.ams_slots}
        # Only warn for a chipped (RFID/NFC) spool: a chipless spool has no reliable remain (issue #27).
        low = next((slot for slot in current.ams_slots if slot.remaining_weight_g is not None
                    and slot.remaining is not None and slot.remaining <= 10
                    and (previous_remaining.get(slot.slot_id) is None or previous_remaining[slot.slot_id] > 10)), None)
        if low and self.config.data.get("notify_low_filament"):
            body = i18n.t("Low filament: {0} ({1}%)").format(low.label, low.remaining)
            self.notify(printer_name, body)
            from . import telegram
            telegram.notify(self, printer_name, body, "")
        humidity_high = current.ams_humidity is not None and current.ams_humidity >= 4
        humidity_was_high = previous.ams_humidity is not None and previous.ams_humidity >= 4
        if humidity_high and not humidity_was_high and self.config.data.get("notify_humidity"):
            body =i18n.t("High AMS humidity")
            self.notify(printer_name, body)
            from . import telegram
            telegram.notify(self, printer_name, body, "")
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
                model={PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper", PrinterKind.PRUSA: "Prusa",
                       PrinterKind.SNAPMAKER: "Snapmaker", PrinterKind.ELEGOO_CC1: "Elegoo Centauri Carbon",
                       PrinterKind.ELEGOO_CC2: "Elegoo Centauri Carbon 2",
                       PrinterKind.ANYCUBIC_KOBRA_S1: "Anycubic Kobra S1"}[kind],
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
            title=i18n.t("Import printers from CSV"),
            transient_for=parent or self.window, action=Gtk.FileChooserAction.OPEN,
        )
        chooser.add_buttons(i18n.t("Cancel"), Gtk.ResponseType.CANCEL, "Importuj", Gtk.ResponseType.OK)
        csv_filter = Gtk.FileFilter(); csv_filter.set_name("CSV"); csv_filter.add_pattern("*.csv"); chooser.add_filter(csv_filter)
        response = chooser.run(); filename = chooser.get_filename(); chooser.destroy()
        if response != Gtk.ResponseType.OK or not filename: return
        try:
            count = self.import_records(parse_printer_csv(Path(filename).read_text(encoding="utf-8-sig")))
            message = i18n.t("Imported {0} printers.").format(count)
            kind = Gtk.MessageType.INFO
        except (OSError, UnicodeError, ValueError, SecretStoreError) as error:
            message = str(error); kind = Gtk.MessageType.ERROR
        dialog = Gtk.MessageDialog(transient_for=parent or self.window, modal=True, message_type=kind,
                                   buttons=Gtk.ButtonsType.OK, text=message)
        dialog.run(); dialog.destroy()

    def open_diagnostics(self) -> None:
        from .diagnostics import DiagnosticsDialog
        DiagnosticsDialog(self).present()

    def open_settings(self) -> None:
        existing = getattr(self, "settings_dialog", None)
        if existing is not None:
            existing.present(); return
        dialog = SettingsDialog(self)
        self.settings_dialog = dialog
        dialog.set_modal(False)
        self.window._suppress_hide = True
        def destroyed(*_args: object) -> None:
            self.settings_dialog = None
            self.window._suppress_hide = False
        dialog.connect("destroy", destroyed)
        def respond(_dialog: Gtk.Dialog, response: int) -> None:
            if response != Gtk.ResponseType.OK:
                dialog.destroy(); return
            if dialog.save():
                dialog.destroy(); return
            dialog.quiet_start.get_style_context().add_class("error"); dialog.quiet_end.get_style_context().add_class("error")
        dialog.connect("response", respond)
        dialog.show_all()
        dialog.present()

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
