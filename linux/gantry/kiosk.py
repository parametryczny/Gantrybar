from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, TypeVar

from gi.repository import Gdk, GLib, Gtk

from .app import Gantry, PrinterCard
from .core import Printer, PrinterKind, PrinterState, Telemetry
from .http_clients import HttpConnection
from .localization import catalog, normalize_language, tr
from .csvimport import parse_printer_csv, template_csv
from .mqtt import MqttConnection
from .storage import Config, SecretStore, SecretStoreError
from .webconfig import WebConfigServer, pairing_code


KIOSK_CSS = b"""
.kiosk-header { padding: 14px 18px; background: #1d1f22; border-bottom: 1px solid #3c3f44; }
.kiosk-brand { font-size: 24px; font-weight: 700; }
.kiosk-tag { color: #8f949c; font-size: 11px; }
.kiosk-summary { color: #b1b5bb; font-size: 14px; }
.kiosk-clock { font-size: 19px; font-weight: 700; }
.kiosk-alert { margin: 10px 14px 0; padding: 9px 12px; color: #ffd7da; background: #44272b; border: 1px solid #873e46; border-radius: 10px; }
.kiosk-footer { padding: 9px 16px; color: #9fa4ac; background: #1d1f22; border-top: 1px solid #3c3f44; font-size: 12px; }
.kiosk-card { border-radius: 14px; padding: 14px; }
.kiosk-card .printer-name { font-size: 18px; }
.kiosk-card .meta { font-size: 12px; }
"""

Result = TypeVar("Result")


class KioskDashboard(Gtk.Window):
    def __init__(self, app: "KioskGantry") -> None:
        super().__init__(title=tr(app.language, "web_title"))
        self.app = app
        self.set_decorated(False)
        self.connect("delete-event", lambda *_args: True)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(root)

        header = Gtk.Box(spacing=16)
        header.get_style_context().add_class("kiosk-header")
        branding = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        brand = Gtk.Label(label="GANTRY", xalign=0); brand.get_style_context().add_class("kiosk-brand")
        self.tag = Gtk.Label(xalign=0); self.tag.get_style_context().add_class("kiosk-tag")
        branding.pack_start(brand, False, False, 0); branding.pack_start(self.tag, False, False, 0)
        self.summary = Gtk.Label(xalign=0); self.summary.get_style_context().add_class("kiosk-summary")
        self.clock = Gtk.Label(xalign=1); self.clock.get_style_context().add_class("kiosk-clock")
        self.settings_button = Gtk.Button()
        self.settings_button.connect("clicked", lambda _button: app.open_kiosk_menu())
        header.pack_start(branding, False, False, 0)
        header.pack_start(self.summary, True, True, 8)
        header.pack_start(self.clock, False, False, 0)
        header.pack_start(self.settings_button, False, False, 0)
        root.pack_start(header, False, False, 0)

        self.alert = Gtk.Label(xalign=0)
        self.alert.get_style_context().add_class("kiosk-alert")
        self.alert.set_no_show_all(True)
        root.pack_start(self.alert, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.grid = Gtk.Grid(column_spacing=10, row_spacing=10, margin=14)
        self.grid.set_column_homogeneous(True)
        self.grid.set_row_homogeneous(True)
        scroll.add(self.grid)
        root.pack_start(scroll, True, True, 0)

        footer = Gtk.Box(spacing=18)
        footer.get_style_context().add_class("kiosk-footer")
        self.remote = Gtk.Label(xalign=0)
        self.freshness = Gtk.Label(xalign=1)
        footer.pack_start(self.remote, True, True, 0)
        footer.pack_start(self.freshness, False, False, 0)
        root.pack_end(footer, False, False, 0)

        self.localize()
        self._update_clock()
        GLib.timeout_add_seconds(1, self._update_clock)

    def _update_clock(self) -> bool:
        now = datetime.now()
        self.clock.set_text(now.strftime("%H:%M  •  %d.%m.%Y"))
        return True

    def localize(self) -> None:
        self.tag.set_text(tr(self.app.language, "workshop_tag"))
        self.settings_button.set_label("⚙  " + tr(self.app.language, "configuration"))
        self.freshness.set_text(tr(self.app.language, "monitoring_active"))

    def update_header(self) -> None:
        values = list(self.app.telemetry.values())
        online = sum(value.state != PrinterState.OFFLINE for value in values)
        printing = sum(value.state in {PrinterState.PRINTING, PrinterState.PAUSED} for value in values)
        errors = [printer for printer in self.app.printers
                  if self.app.telemetry.get(printer.serial, Telemetry()).state == PrinterState.ERROR]
        error_text = tr(self.app.language, "kiosk_errors", count=len(errors)) if errors else ""
        self.summary.set_text(tr(self.app.language, "kiosk_summary", printers=len(self.app.printers),
                                 online=online, printing=printing, errors=error_text))
        if errors:
            names = ", ".join(printer.name for printer in errors[:3])
            self.alert.set_text(tr(self.app.language, "attention", names=names))
            self.alert.set_no_show_all(False); self.alert.show()
        else:
            self.alert.hide(); self.alert.set_no_show_all(True)
        server = self.app.web_config
        if server.error:
            self.remote.set_text(tr(self.app.language, "remote_unavailable"))
        else:
            formatted = f"{server.code[:3]} {server.code[3:]}"
            self.remote.set_text(tr(self.app.language, "remote_footer", url=server.url, code=formatted))


class KioskPrinterCard(PrinterCard):
    def __init__(self, app: "KioskGantry", printer: Printer) -> None:
        super().__init__(app, printer)
        self.get_style_context().add_class("kiosk-card")
        self.set_size_request(220, 175)


class KioskMenuDialog(Gtk.Dialog):
    def __init__(self, app: "KioskGantry") -> None:
        super().__init__(title=tr(app.language, "web_title"), transient_for=app.window, modal=True)
        self.app = app
        self.set_default_size(480, 330)
        self.close_button = self.add_button(tr(app.language, "close"), Gtk.ResponseType.CLOSE)
        box = self.get_content_area(); box.set_spacing(12); box.set_border_width(20)
        self.title_label = Gtk.Label(xalign=0)
        self.title_label.get_style_context().add_class("title"); box.pack_start(self.title_label, False, False, 0)
        self.remote = Gtk.Label(xalign=0)
        if app.web_config.error:
            self.remote.set_text(tr(app.language, "web_unavailable"))
        else:
            code = f"{app.web_config.code[:3]} {app.web_config.code[3:]}"
            self.remote.set_markup(tr(app.language, "computer_pairing", url=app.web_config.url, code=code))
        box.pack_start(self.remote, False, False, 0)
        actions = Gtk.Grid(column_spacing=10, row_spacing=10)
        self.add_action = Gtk.Button(); self.add_action.connect("clicked", lambda _button: self._run_and_return(app.open_printer_dialog))
        self.settings_action = Gtk.Button(); self.settings_action.connect("clicked", lambda _button: self._run_and_return(app.open_settings))
        self.import_action = Gtk.Button(); self.import_action.connect("clicked", lambda _button: self._run_and_return(app.import_csv_on_screen))
        self.template_action = Gtk.Button(); self.template_action.connect("clicked", lambda _button: self._run_and_return(app.save_csv_template))
        self.reconnect_action = Gtk.Button(); self.reconnect_action.connect("clicked", lambda _button: app.reconnect_all())
        self.rotate_action = Gtk.Button(); self.rotate_action.connect("clicked", lambda _button: self._rotate(self.remote))
        actions.attach(self.add_action, 0, 0, 1, 1); actions.attach(self.settings_action, 1, 0, 1, 1)
        actions.attach(self.import_action, 0, 1, 1, 1); actions.attach(self.template_action, 1, 1, 1, 1)
        actions.attach(self.reconnect_action, 0, 2, 1, 1); actions.attach(self.rotate_action, 1, 2, 1, 1)
        box.pack_start(actions, True, True, 0)
        self.hint = Gtk.Label(xalign=0)
        self.hint.get_style_context().add_class("meta"); box.pack_end(self.hint, False, False, 0)
        self.localize()
        self.show_all()

    def _run_and_return(self, action: Callable[[], None]) -> None:
        self.hide(); action(); self.localize(); self.show_all(); self.present()

    def localize(self) -> None:
        self.close_button.set_label(tr(self.app.language, "close"))
        self.title_label.set_text(tr(self.app.language, "screen_configuration"))
        self.add_action.set_label("＋  " + tr(self.app.language, "add"))
        self.settings_action.set_label("⚙  " + tr(self.app.language, "settings"))
        self.import_action.set_label("⇩  " + tr(self.app.language, "import_csv"))
        self.template_action.set_label(tr(self.app.language, "csv_template_documents"))
        self.reconnect_action.set_label("↻  " + tr(self.app.language, "reconnect"))
        self.rotate_action.set_label(tr(self.app.language, "new_pairing_code"))
        self.hint.set_text(tr(self.app.language, "ssh_hint"))
        if self.app.web_config.error:
            self.remote.set_text(tr(self.app.language, "web_unavailable"))
        else:
            code = f"{self.app.web_config.code[:3]} {self.app.web_config.code[3:]}"
            self.remote.set_markup(tr(self.app.language, "computer_pairing", url=self.app.web_config.url, code=code))

    def _rotate(self, label: Gtk.Label) -> None:
        self.app.web_config.code = pairing_code()
        self.app.web_config.sessions.clear()
        code = f"{self.app.web_config.code[:3]} {self.app.web_config.code[3:]}"
        label.set_markup(tr(self.app.language, "computer_pairing", url=self.app.web_config.url, code=code))
        self.app.window.update_header()


class KioskGantry(Gantry):
    def __init__(self) -> None:
        self.config, self.secrets = Config(), SecretStore()
        self.config.data["theme"] = "dark"
        self.language = normalize_language(str(self.config.data.get("language", "en"))); self.text = catalog(self.language)
        self.printers = self.config.printers
        self.telemetry = {printer.serial: Telemetry() for printer in self.printers}
        self.connections: dict[str, MqttConnection | HttpConnection] = {}
        self.cards: dict[str, KioskPrinterCard] = {}
        self.expanded_compact_serial: str | None = None
        self.web_config = WebConfigServer(
            self._remote_snapshot, self._remote_add, self._remote_remove, self._remote_import,
            language_provider=lambda: self.language,
        )
        self.window = KioskDashboard(self)
        self.apply_theme()
        self._apply_kiosk_theme()
        self.rebuild_cards()
        self.web_config.start()
        self.window.update_header()
        self.reconnect_all()
        self.window.show_all()
        self.window.fullscreen()

    def _tray(self) -> None:
        return

    def _apply_kiosk_theme(self) -> None:
        provider = Gtk.CssProvider(); provider.load_from_data(KIOSK_CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)

    def show(self) -> None:
        self.window.show_all(); self.window.fullscreen(); self.window.present()

    def rebuild_cards(self) -> None:
        self.window.localize()
        for child in self.window.grid.get_children(): self.window.grid.remove(child)
        self.cards = {}
        count = len(self.printers)
        columns = 2 if count <= 4 else 3 if count <= 6 else 4 if count <= 12 else 5
        for index, printer in enumerate(self.printers):
            card = KioskPrinterCard(self, printer)
            self.cards[printer.serial] = card
            row, column = divmod(index, columns)
            self.window.grid.attach(card, column, row, 1, 1)
            card.update(self.telemetry.get(printer.serial, Telemetry()))
        self.window.update_header(); self.window.show_all()

    def open_kiosk_menu(self) -> None:
        dialog = KioskMenuDialog(self)
        dialog.run(); dialog.destroy(); self.window.fullscreen()

    def _on_ui(self, action: Callable[[], Result], timeout: float = 15) -> tuple[bool, Result | str]:
        finished = threading.Event()
        result: list[Result | Exception] = []
        def run() -> bool:
            try: result.append(action())
            except Exception as error: result.append(error)
            finished.set(); return False
        GLib.idle_add(run)
        if not finished.wait(timeout):
            return False, tr(self.language, "operation_timeout")
        if not result or isinstance(result[0], Exception):
            return False, str(result[0]) if result else tr(self.language, "unknown_error")
        return True, result[0]

    def _remote_snapshot(self) -> dict[str, Any]:
        ok, value = self._on_ui(lambda: {
            "printers": [self._remote_printer(printer) for printer in self.printers]
        })
        return value if ok and isinstance(value, dict) else {"printers": []}

    def _remote_printer(self, printer: Printer) -> dict[str, Any]:
        telemetry = self.telemetry.get(printer.serial, Telemetry())
        return {
            "serial": printer.serial, "name": printer.name, "host": printer.host,
            "port": printer.port, "kind": printer.kind.value,
            "state": telemetry.state.value, "progress": telemetry.progress,
            "job": telemetry.job_name or "—", "remaining": telemetry.remaining_minutes,
            "layer": telemetry.current_layer, "layers": telemetry.total_layers,
            "nozzle": telemetry.nozzle, "nozzle_target": telemetry.nozzle_target,
            "bed": telemetry.bed, "bed_target": telemetry.bed_target,
            "ams": [{"label": slot.label, "color": slot.color[:6], "active": slot.active}
                    for slot in telemetry.ams_slots],
        }

    def _remote_add(self, values: dict[str, Any]) -> tuple[bool, str]:
        def add() -> str:
            kind = PrinterKind(str(values.get("kind", "bambu")))
            printer = Printer(serial=str(values["serial"]), name=str(values["name"]),
                              host=str(values["host"]), port=int(values["port"]), kind=kind,
                              model={PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper", PrinterKind.PRUSA: "Prusa"}[kind])
            if values.get("code"):
                self.secrets.set(printer.serial, str(values["code"]))
            self.upsert_printer(printer); self.reconnect_all()
            return tr(self.language, "printer_added")
        ok, value = self._on_ui(add, timeout=30)
        if not ok:
            message = tr(self.language, "secret_error") if "secret" in str(value).lower() else str(value)
            return False, message
        return True, str(value)

    def _import_records(self, records: list[dict[str, Any]]) -> str:
        previous_codes: dict[str, str | None] = {}
        written: list[str] = []
        try:
            for record in records:
                serial = str(record["serial"])
                if record.get("code"):
                    previous_codes[serial] = self.secrets.get(serial)
                    self.secrets.set(serial, str(record["code"]))
                    written.append(serial)
        except Exception:
            for serial in written:
                old = previous_codes.get(serial)
                try:
                    if old:
                        self.secrets.set(serial, old)
                    else:
                        self.secrets.delete(serial)
                except SecretStoreError:
                    pass
            raise
        by_serial = {printer.serial: printer for printer in self.printers}
        for record in records:
            kind = PrinterKind(str(record.get("kind", "bambu")))
            printer = Printer(serial=str(record["serial"]), name=str(record["name"]),
                              host=str(record["host"]), port=int(record["port"]), kind=kind,
                              model={PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper", PrinterKind.PRUSA: "Prusa"}[kind])
            by_serial[printer.serial] = printer
            self.telemetry.setdefault(printer.serial, Telemetry())
        self.printers = list(by_serial.values())
        self.config.printers = self.printers
        self.rebuild_cards(); self.reconnect_all()
        return tr(self.language, "imported_delete_csv", count=len(records))

    def _remote_import(self, records: list[dict[str, Any]]) -> tuple[bool, str]:
        ok, value = self._on_ui(lambda: self._import_records(records), timeout=60)
        return ok, str(value)

    def import_csv_on_screen(self, parent: Gtk.Window | Gtk.Dialog | None = None) -> None:
        chooser = Gtk.FileChooserDialog(
            title=tr(self.language, "import_csv_title"), transient_for=parent or self.window,
            action=Gtk.FileChooserAction.OPEN,
        )
        chooser.add_buttons(tr(self.language, "cancel"), Gtk.ResponseType.CANCEL, tr(self.language, "import_csv"), Gtk.ResponseType.OK)
        csv_filter = Gtk.FileFilter(); csv_filter.set_name(tr(self.language, "csv_files")); csv_filter.add_pattern("*.csv")
        chooser.add_filter(csv_filter)
        response = chooser.run(); filename = chooser.get_filename(); chooser.destroy()
        if response != Gtk.ResponseType.OK or not filename:
            return
        try:
            records = parse_printer_csv(Path(filename).read_text(encoding="utf-8-sig"), language=self.language)
            message = self._import_records(records)
            self._message(tr(self.language, "import_complete"), message, Gtk.MessageType.INFO)
        except (OSError, UnicodeError, ValueError, SecretStoreError) as error:
            message = tr(self.language, "secret_error") if isinstance(error, SecretStoreError) else str(error)
            self._message(tr(self.language, "import_failed"), message, Gtk.MessageType.ERROR)

    def save_csv_template(self) -> None:
        chooser = Gtk.FileChooserDialog(
            title=tr(self.language, "save_template_title"), transient_for=self.window,
            action=Gtk.FileChooserAction.SAVE,
        )
        chooser.add_buttons(tr(self.language, "cancel"), Gtk.ResponseType.CANCEL, tr(self.language, "save"), Gtk.ResponseType.OK)
        chooser.set_current_name("Gantry-printers-template.csv")
        documents = Path.home() / "Documents"
        if documents.exists(): chooser.set_current_folder(str(documents))
        chooser.set_do_overwrite_confirmation(True)
        response = chooser.run(); filename = chooser.get_filename(); chooser.destroy()
        if response != Gtk.ResponseType.OK or not filename:
            return
        try:
            Path(filename).write_text("\ufeff" + template_csv(), encoding="utf-8")
            self._message(tr(self.language, "template_saved"), filename, Gtk.MessageType.INFO)
        except OSError as error:
            self._message(tr(self.language, "template_save_failed"), str(error), Gtk.MessageType.ERROR)

    def _message(self, title: str, body: str, kind: Gtk.MessageType) -> None:
        dialog = Gtk.MessageDialog(
            transient_for=self.window, modal=True, message_type=kind,
            buttons=Gtk.ButtonsType.OK, text=title,
        )
        dialog.format_secondary_text(body); dialog.run(); dialog.destroy()

    def _remote_remove(self, serial: str) -> tuple[bool, str]:
        def remove() -> str:
            printer = next((item for item in self.printers if item.serial == serial), None)
            if not printer: raise ValueError(tr(self.language, "printer_not_found"))
            self.remove_printer(printer)
            return tr(self.language, "printer_removed")
        ok, value = self._on_ui(remove)
        return ok, str(value)

    def quit(self) -> None:
        self.web_config.stop()
        super().quit()
