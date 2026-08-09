from __future__ import annotations

import argparse
import subprocess
import threading
from datetime import datetime
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
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
from .localization import catalog, normalize_language, stage_text, tr
from .mqtt import MqttConnection
from .storage import Config, SecretStore, SecretStoreError, autostart_enabled, set_autostart
from .studio import devices as studio_devices

def quiet_hours_active(config: Config, now: datetime | None = None) -> bool:
    if not config.data.get("quiet_hours_enabled", True): return False
    current = (now or datetime.now()).strftime("%H:%M")
    start = str(config.data.get("quiet_hours_start", "22:00"))
    end = str(config.data.get("quiet_hours_end", "07:00"))
    return start <= current < end if start < end else current >= start or current < end

def css_for(theme: str) -> bytes:
    if theme == "light":
        colors = ("#f2f2f7", "#1c1c1e", "#ffffff", "#d1d1d6", "#636366", "#f2f2f7", "#c7c7cc")
    else:
        colors = ("#18181a", "#f5f5f7", "#29292c", "#404044", "#a1a1a6", "#4a4a4e", "#b8b8bd")
    background, foreground, card, border, secondary, trough, job = colors
    return ("""
window { background: %(background)s; color: %(foreground)s; }
.header { padding: 20px 24px 14px; }
.title { font-size: 25px; font-weight: 700; }
.subtitle { color: %(secondary)s; font-size: 13px; }
.card { background: %(card)s; border: 1px solid %(border)s; border-radius: 18px; padding: 18px; }
.card.finished { background: #1e382d; border-color: #397b5a; }
.card.error { background: #3b2428; border-color: #d64b55; }
.printer-name { font-size: 20px; font-weight: 700; }
.job { color: %(job)s; font-weight: 600; }
.meta { color: %(secondary)s; font-size: 13px; }
.status { color: #0a9fff; font-weight: 700; }
.status.finished { color: #35d46a; }
.status.error { color: #ff5360; }
.ams { border-radius: 6px; border: 1px solid alpha(#ffffff, 0.12); }
.ams.active { border: 2px solid #ffffff; }
.ams-group { background: alpha(#ffffff, 0.05); border: 1px solid alpha(#ffffff, 0.10); border-radius: 10px; padding: 8px 10px; }
button { border-radius: 10px; padding: 7px 12px; }
entry { padding: 8px; border-radius: 8px; }
progressbar trough { min-height: 7px; border-radius: 5px; background: %(trough)s; }
progressbar progress { border-radius: 5px; background: #0a9fff; }
""" % {"background": background, "foreground": foreground, "card": card, "border": border,
         "secondary": secondary, "trough": trough, "job": job}).encode()


class PrinterCard(Gtk.Frame):
    def __init__(self, app: "Gantry", printer: Printer) -> None:
        super().__init__()
        self.app, self.printer = app, printer
        self.get_style_context().add_class("card")
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(self.box)
        top = Gtk.Box(spacing=8)
        self.name = Gtk.Label(label=printer.name, xalign=0)
        self.name.get_style_context().add_class("printer-name")
        self.kind = Gtk.Label(label={PrinterKind.BAMBU: "Bambu", PrinterKind.KLIPPER: "Klipper", PrinterKind.PRUSA: "Prusa"}[printer.kind])
        self.kind.get_style_context().add_class("meta")
        self.status = Gtk.Label(xalign=1)
        self.status.get_style_context().add_class("status")
        menu = Gtk.Button(label="•••")
        menu.connect("clicked", self._show_menu)
        top.pack_start(self.name, True, True, 0)
        top.pack_start(self.kind, False, False, 0)
        top.pack_start(self.status, False, False, 0)
        top.pack_start(menu, False, False, 0)
        self.box.pack_start(top, False, False, 0)
        self.job = Gtk.Label(label="—", xalign=0, ellipsize=Pango.EllipsizeMode.END)
        self.job.get_style_context().add_class("job")
        self.box.pack_start(self.job, False, False, 0)
        progress_row = Gtk.Box(spacing=12)
        self.progress = Gtk.ProgressBar(show_text=False)
        self.percent = Gtk.Label(label="0%")
        progress_row.pack_start(self.progress, True, True, 0)
        progress_row.pack_start(self.percent, False, False, 0)
        self.box.pack_start(progress_row, False, False, 0)
        self.meta = Gtk.Label(xalign=0)
        self.meta.get_style_context().add_class("meta")
        self.box.pack_start(self.meta, False, False, 0)
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
        slicers = installed_slicers()
        bambu_studio = next((slicer for slicer in slicers if slicer.name == "Bambu Studio"), None)
        if self.printer.kind == PrinterKind.BAMBU and bambu_studio:
            camera = Gtk.MenuItem(label=tr(self.app.language, "camera"))
            camera.connect("activate", lambda *_: open_desktop_app(bambu_studio))
            menu.append(camera)
        for slicer in slicers:
            label = tr(self.app.language, "open_in", name=slicer.name)
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
        for widget in (self.job, self.progress.get_parent(), self.meta, self.ams):
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
        if telemetry.state in {PrinterState.PRINTING, PrinterState.PAUSED}:
            status = stage_text(self.app.language, telemetry.stage) or status
        if reason:
            if "certificate-changed" in reason:
                status = labels["certificate"]
            elif "access-code-rejected" in reason:
                status = labels["rejected"]
            elif "moonraker-objects-not-found" in reason:
                status = labels["moonraker_missing"]
            elif reason in {"connection-closed", "incomplete-mqtt-packet", "incomplete-mqtt-body"}:
                status = labels["offline"]
        self.status.set_text(status)
        context = self.status.get_style_context()
        card_context = self.get_style_context()
        for name in ("finished", "error"):
            context.remove_class(name)
            card_context.remove_class(name)
        if telemetry.state == PrinterState.FINISHED:
            context.add_class("finished"); card_context.add_class("finished")
        elif telemetry.state == PrinterState.ERROR:
            context.add_class("error"); card_context.add_class("error")
        self.job.set_text(telemetry.job_name or "—")
        self.progress.set_fraction(telemetry.progress / 100)
        self.percent.set_text(f"{telemetry.progress}%")
        eta = "—" if telemetry.remaining_minutes is None else f"{telemetry.remaining_minutes // 60}h {telemetry.remaining_minutes % 60}m"
        layers = "—" if telemetry.current_layer is None else f"{telemetry.current_layer}/{telemetry.total_layers or '—'}"
        def fmt(cur: float | None, tgt: float | None) -> str:
            if cur is None:
                return "—"
            return f"{cur:.0f}/{tgt:.0f}°" if tgt else f"{cur:.0f}°"

        # Nozzle(s) with explicit L/P (pl) or L/R (en) for dual-nozzle printers, plus chamber when real.
        nozzles = telemetry.nozzles
        dual = any(n.position == "right" for n in nozzles)
        parts = [f"◷ {eta}", f"▤ {layers}"]
        if dual:
            left = next((n for n in nozzles if n.position == "left"), nozzles[0])
            right = next((n for n in nozzles if n.position == "right"), None)
            right_label = "P" if self.app.language == "pl" else "R"
            parts.append(f"L {fmt(left.current, left.target)}")
            parts.append(f"{right_label} {fmt(right.current, right.target) if right else '—'}")
        else:
            cur = nozzles[0].current if nozzles else telemetry.nozzle
            tgt = nozzles[0].target if nozzles else telemetry.nozzle_target
            parts.append(f"♨ {fmt(cur, tgt)}")
        parts.append(f"▣ {fmt(telemetry.bed, telemetry.bed_target)}")
        if telemetry.chamber is not None:
            parts.append(f"⌂ {telemetry.chamber:.0f}°")
        self.meta.set_text("    ".join(parts))

        # Physical filament modules as side-by-side groups (name + per-module humidity/temp, then slots).
        for child in self.ams.get_children():
            self.ams.remove(child)
        for group in telemetry.filament_groups:
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
            for slot in group.slots:
                sbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
                swatch = Gtk.Label(label="")
                swatch.set_size_request(28 if not group.external else 40, 30)
                swatch.get_style_context().add_class("ams")
                present = slot.present
                color = (slot.color or "8E8E93FF").lstrip("#")[:6] if present else "5A5A5E"
                try:
                    rgba = Gdk.RGBA(); rgba.parse(f"#{color}")
                    swatch.override_background_color(Gtk.StateFlags.NORMAL, rgba)
                except ValueError:
                    pass
                if slot.active:
                    swatch.get_style_context().add_class("active")
                caption = Gtk.Label(xalign=0.5)
                caption.get_style_context().add_class("meta")
                caption.set_markup(f"<b>{GLib.markup_escape_text(slot.label)}</b>" if slot.active else GLib.markup_escape_text(slot.label))
                sbox.pack_start(swatch, False, False, 0)
                sbox.pack_start(caption, False, False, 0)
                srow.pack_start(sbox, False, False, 0)
            gbox.pack_start(srow, False, False, 0)
            self.ams.pack_start(gbox, False, False, 0)
        self.ams.show_all()


class Dashboard(Gtk.Window):
    def __init__(self, app: "Gantry") -> None:
        super().__init__(title="Gantry")
        self.app = app
        self.set_default_size(920, 720)
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
        self.grid = Gtk.Grid(column_spacing=16, row_spacing=16, margin=22)
        scroll.add(self.grid); root.pack_start(scroll, True, True, 0)

    def _hide(self, *_args: object) -> bool:
        self.hide(); return True

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
        for value, label in (("bambu", "Bambu Lab"), ("klipper", "Klipper / Moonraker"), ("prusa", "Prusa / PrusaLink")):
            self.kind.append(value, label)
        self.kind.set_active_id((printer.kind if printer else PrinterKind.BAMBU).value)
        self.kind.connect("changed", lambda _combo: self._apply_kind())
        box.pack_start(self.kind, False, False, 0)
        csv_button = Gtk.Button(label=tr(app.language, "import_many_csv"))
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
            box.pack_start(row, False, False, 0)
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
        defaults = {PrinterKind.BAMBU: 8883, PrinterKind.KLIPPER: 7125, PrinterKind.PRUSA: 80}
        if not self.printer or self.printer.kind != kind:
            self.fields["port"].set_text(str(defaults[kind]))
        if kind == PrinterKind.BAMBU:
            self.code_label.set_text(self.app.text["code"].split(" /")[0])
            self.info.set_text(tr(self.app.language, "bambu_info"))
        elif kind == PrinterKind.KLIPPER:
            self.code_label.set_text(self.app.text["api_optional"])
            self.info.set_text(tr(self.app.language, "klipper_info"))
        else:
            self.code_label.set_text(tr(self.app.language, "prusa_api_key"))
            self.info.set_text(tr(self.app.language, "prusa_info"))

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
        model = {PrinterKind.BAMBU: "Bambu Lab", PrinterKind.KLIPPER: "Klipper", PrinterKind.PRUSA: "Prusa"}[kind]
        return Printer(serial, values["name"], values["host"], model=model, port=port, kind=kind), values["code"]


class SettingsDialog(Gtk.Dialog):
    def __init__(self, app: "Gantry") -> None:
        super().__init__(title=app.text["settings"], transient_for=app.window, modal=True)
        self.app = app; self.add_button(app.text["cancel"], Gtk.ResponseType.CANCEL); self.add_button(app.text["save"], Gtk.ResponseType.OK)
        self.set_default_size(520, 420)
        box = self.get_content_area(); box.set_spacing(12); box.set_border_width(20)
        self.language = Gtk.ComboBoxText(); self.language.append("pl", "Polski"); self.language.append("en", "English"); self.language.append("de", "Deutsch"); self.language.set_active_id(app.language)
        self.theme = Gtk.ComboBoxText(); self.theme.append("dark", app.text["dark"]); self.theme.append("light", app.text["light"]); self.theme.set_active_id(str(app.config.data.get("theme", "dark")))
        for label, widget in ((app.text["language"], self.language), (app.text["theme"], self.theme)):
            box.pack_start(Gtk.Label(label=label, xalign=0), False, False, 0); box.pack_start(widget, False, False, 0)
        self.autostart = Gtk.CheckButton(label=app.text["autostart"]); self.autostart.set_active(autostart_enabled()); box.pack_start(self.autostart, False, False, 0)
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
        self.app.config.data.update(language=self.language.get_active_id(), theme=self.theme.get_active_id())
        self.app.config.data.update(quiet_hours_enabled=self.quiet.get_active(),
                                    quiet_hours_start=self.quiet_start.get_text().strip(),
                                    quiet_hours_end=self.quiet_end.get_text().strip())
        for key, widget in self.notices.items(): self.app.config.data[key] = widget.get_active()
        self.app.config.save(); set_autostart(self.autostart.get_active()); return True


class Gantry:
    def __init__(self, background: bool = False) -> None:
        self.config, self.secrets = Config(), SecretStore()
        self.language = normalize_language(str(self.config.data.get("language", "en"))); self.text = catalog(self.language)
        self.printers = self.config.printers
        self.telemetry = {printer.serial: Telemetry() for printer in self.printers}
        self.connections: dict[str, MqttConnection | HttpConnection] = {}; self.cards: dict[str, PrinterCard] = {}
        self.expanded_compact_serial: str | None = None
        self.window = Dashboard(self); self.apply_theme(); self.rebuild_cards(); self._tray()
        self.reconnect_all()
        if not background or AppIndicator is None: self.window.show_all()

    def apply_theme(self) -> None:
        settings = Gtk.Settings.get_default(); settings.set_property("gtk-application-prefer-dark-theme", self.config.data.get("theme") == "dark")
        provider = Gtk.CssProvider(); provider.load_from_data(css_for(str(self.config.data.get("theme", "dark")))); Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def _tray(self) -> None:
        if getattr(self, "indicator", None) is not None:
            self.indicator.set_status(AppIndicator.IndicatorStatus.PASSIVE)
        menu = Gtk.Menu()
        for label, callback in (("Gantry", lambda *_: self.show()), (self.text["scan"], lambda *_: self.scan_and_import()),
                                (self.text["add"], lambda *_: self.open_printer_dialog())):
            item = Gtk.MenuItem(label=label); item.connect("activate", callback); menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        quiet = Gtk.CheckMenuItem(label=self.text["quiet"]); quiet.set_active(bool(self.config.data.get("quiet_hours_enabled", True)))
        quiet.connect("toggled", lambda item: self._toggle_quiet(item.get_active())); menu.append(quiet)
        legend = Gtk.MenuItem(label=tr(self.language, "legend"))
        legend_menu = Gtk.Menu()
        for key in ("legend_blue", "legend_green", "legend_red", "legend_gray"):
            item = Gtk.MenuItem(label=tr(self.language, key)); item.set_sensitive(False); legend_menu.append(item)
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

    def show(self) -> None:
        self.window.show_all(); self.window.present()

    def rebuild_cards(self) -> None:
        for child in self.window.grid.get_children(): self.window.grid.remove(child)
        self.cards = {}
        compact = self.is_compact()
        columns = 3 if len(self.printers) > 8 else 2
        for index, printer in enumerate(self.printers):
            card = PrinterCard(self, printer)
            card.set_compact(compact, self.expanded_compact_serial == printer.serial)
            self.cards[printer.serial] = card
            row, column = divmod(index, columns)
            span = columns if index == len(self.printers) - 1 and len(self.printers) % columns == 1 else 1
            self.window.grid.attach(card, column, row, span, 1)
            if printer.serial in self.telemetry: card.update(self.telemetry[printer.serial])
        self.window.update_header(); self.window.show_all()

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
        if card := self.cards.get(serial): card.update(current, str(value) if event == "disconnected" else None)
        self.window.update_header()
        if quiet_hours_active(self.config): return False
        printer_name = next((p.name for p in self.printers if p.serial == serial), "Gantry")
        if current.state != previous.state:
            key = {PrinterState.FINISHED: "notify_finished", PrinterState.ERROR: "notify_error",
                   PrinterState.PAUSED: "notify_paused", PrinterState.OFFLINE: "notify_offline"}.get(current.state)
            if key and self.config.data.get(key): self.notify(printer_name, self.text[current.state.value])
        previous_remaining = {slot.slot_id: slot.remaining for slot in previous.ams_slots}
        low = next((slot for slot in current.ams_slots if slot.remaining is not None and slot.remaining <= 10
                    and (previous_remaining.get(slot.slot_id) is None or previous_remaining[slot.slot_id] > 10)), None)
        if low and self.config.data.get("notify_low_filament"):
            body = tr(self.language, "low_filament_body", slot=low.label, percent=low.remaining)
            self.notify(printer_name, body)
        humidity_high = current.ams_humidity is not None and current.ams_humidity >= 4
        humidity_was_high = previous.ams_humidity is not None and previous.ams_humidity >= 4
        if humidity_high and not humidity_was_high and self.config.data.get("notify_humidity"):
            body = tr(self.language, "humidity_notice")
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
        chooser = Gtk.FileChooserDialog(
            title=tr(self.language, "import_csv_title"),
            transient_for=parent or self.window, action=Gtk.FileChooserAction.OPEN,
        )
        chooser.add_buttons(self.text["cancel"], Gtk.ResponseType.CANCEL, tr(self.language, "import_csv"), Gtk.ResponseType.OK)
        csv_filter = Gtk.FileFilter(); csv_filter.set_name("CSV"); csv_filter.add_pattern("*.csv"); chooser.add_filter(csv_filter)
        response = chooser.run(); filename = chooser.get_filename(); chooser.destroy()
        if response != Gtk.ResponseType.OK or not filename: return
        try:
            count = self.import_records(parse_printer_csv(Path(filename).read_text(encoding="utf-8-sig"), language=self.language))
            message = tr(self.language, "imported_count", count=count)
            kind = Gtk.MessageType.INFO
        except (OSError, UnicodeError, ValueError, SecretStoreError) as error:
            message = self.text["secret_error"] if isinstance(error, SecretStoreError) else str(error)
            kind = Gtk.MessageType.ERROR
        dialog = Gtk.MessageDialog(transient_for=parent or self.window, modal=True, message_type=kind,
                                   buttons=Gtk.ButtonsType.OK, text=message)
        dialog.run(); dialog.destroy()

    def open_settings(self) -> None:
        dialog = SettingsDialog(self)
        while True:
            response = dialog.run()
            if response != Gtk.ResponseType.OK:
                dialog.destroy(); return
            if dialog.save():
                dialog.destroy(); self.language = normalize_language(str(self.config.data.get("language", "en"))); self.text = catalog(self.language); self.apply_theme(); self.rebuild_cards(); self._tray(); return
            dialog.quiet_start.get_style_context().add_class("error"); dialog.quiet_end.get_style_context().add_class("error")

    def quit(self) -> None:
        for connection in self.connections.values(): connection.stop()
        Gtk.main_quit()


def main() -> int:
    parser = argparse.ArgumentParser(prog="gantry")
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--kiosk", action="store_true", help="full-screen Raspberry Pi workshop dashboard")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args()
    if args.version:
        print(f"Gantry {__version__}"); return 0
    if args.kiosk:
        from .kiosk import KioskGantry
        KioskGantry()
    else:
        Gantry(background=args.background)
    Gtk.main(); return 0


if __name__ == "__main__":
    raise SystemExit(main())
