from __future__ import annotations

from typing import Any

from gi.repository import Gtk, Pango  # type: ignore

from . import i18n


def _duration(seconds: float) -> str:
    minutes = int(seconds / 60)
    return f"{minutes // 60}h {minutes % 60}m" if minutes >= 60 else f"{minutes}m"


class MaintenancePanel(Gtk.Frame):
    """Compact maintenance card displayed in Gantry's own overlay."""

    def __init__(self, app: Any, printer: Any, telemetry: Any, close: Any) -> None:
        super().__init__()
        self.app, self.printer, self.telemetry, self.close = app, printer, telemetry, close
        self.pl = app.language == "pl"
        self.set_shadow_type(Gtk.ShadowType.NONE)
        self.set_size_request(470, 560)
        self.set_halign(Gtk.Align.CENTER); self.set_valign(Gtk.Align.CENTER)
        self.get_style_context().add_class("maintenance-panel")
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.body.set_border_width(16)
        self.add(self.body)
        self.rebuild()

    def rebuild(self) -> None:
        for child in self.body.get_children():
            self.body.remove(child)
        snap = self.app.insights.snapshot(self.printer.serial, self.pl)

        header = Gtk.Box(spacing=8)
        title = Gtk.Label(label=(f"Konserwacja · {self.printer.name}" if self.pl
                                 else f"Maintenance · {self.printer.name}"), xalign=0)
        title.get_style_context().add_class("maintenance-title")
        instructions = Gtk.Button(label=i18n.t("Instructions"))
        instructions.connect("clicked", self._instructions)
        close = Gtk.Button(label="×"); close.set_relief(Gtk.ReliefStyle.NONE)
        close.set_tooltip_text(i18n.t("Close"))
        close.connect("clicked", lambda *_: self.close())
        header.pack_start(title, True, True, 0); header.pack_start(instructions, False, False, 0); header.pack_start(close, False, False, 0)
        self.body.pack_start(header, False, False, 0)
        nozzle = f"{self.telemetry.nozzle_diameter:.1f} mm" if self.telemetry.nozzle_diameter else "—"
        summary = self._label(f"{snap['total_hours']:.1f} " +
                              (i18n.t("print h · nozzle {0}").format(nozzle)))
        self.body.pack_start(summary, False, False, 0)

        alerts = self._alerts()
        if alerts:
            self.body.pack_start(self._section(i18n.t("PRINTER ALERTS")), False, False, 4)
            self.body.pack_start(self._alert_list(alerts), False, False, 0)

        tasks = Gtk.Grid(column_homogeneous=True, column_spacing=7, row_spacing=7)
        for index, task in enumerate(snap["tasks"]):
            card = self._task(task)
            card.set_hexpand(True)
            tasks.attach(card, index % 2, index // 2, 1, 1)
        self.body.pack_start(tasks, False, False, 0)

        history = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        history.get_style_context().add_class("maintenance-footer-card")
        history.pack_start(self._section(i18n.t("RECENT PRINTS")), False, False, 0)
        recent = snap["history"][:3]
        if not recent:
            history.pack_start(self._label(i18n.t("No recorded history.")), False, False, 0)
        for entry in recent:
            icon = "✓" if entry.get("result") == "completed" else "!" if entry.get("result") == "failed" else "×"
            name = str(entry.get("job") or (i18n.t("Untitled")))
            row = Gtk.Label(label=f"{icon}  {name} · {_duration(float(entry.get('durationSeconds', 0)))}",
                            xalign=0, ellipsize=Pango.EllipsizeMode.END)
            row.get_style_context().add_class("maintenance-history")
            history.pack_start(row, False, False, 0)
        success = "—" if snap["success"] is None else f"{snap['success']}%"
        stats = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        stats.get_style_context().add_class("maintenance-footer-card")
        stats.pack_start(self._section(i18n.t("STATISTICS")), False, False, 0)
        metrics = Gtk.Box(spacing=4, homogeneous=True)
        metrics.pack_start(self._metric(str(snap["completed"]),i18n.t("completed")), True, True, 0)
        metrics.pack_start(self._metric(success,i18n.t("success")), True, True, 0)
        metrics.pack_start(self._metric(f"{snap['consumed_grams']:.0f} g", "filament"), True, True, 0)
        stats.pack_start(metrics, True, True, 0)
        footer = Gtk.Grid(column_homogeneous=True, column_spacing=7)
        footer.attach(history, 0, 0, 1, 1); footer.attach(stats, 1, 0, 1, 1)
        self.body.pack_start(footer, False, False, 0)
        self._refresh_parent_views()
        self.show_all()

    def _alerts(self) -> list[tuple[str, str | None]]:
        from .hms import actionable_codes, description
        codes = actionable_codes(self.telemetry.hms_codes, self.printer.serial, self.app.language)
        if codes:
            return [(description([code], self.printer.serial, self.app.language) or f"HMS {code}", code) for code in codes]
        if getattr(self.telemetry, "error_code", 0):
            return [(i18n.t("Error code: 0x{0:X}").format(self.telemetry.error_code), None)]
        from .core import PrinterState
        if self.telemetry.state == PrinterState.ERROR:
            return [(i18n.t("Printer reported an error"), None)]
        return []

    def _alert(self, message: str, code: str | None) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        heading = Gtk.Label(label=f"!  {message}", xalign=0, wrap=True)
        heading.set_max_width_chars(52)
        heading.set_lines(2)
        heading.get_style_context().add_class("maintenance-alert-title")
        box.pack_start(heading, False, False, 0)
        if code: box.pack_start(self._label(code), False, False, 0)
        return box

    def _alert_list(self, alerts: list[tuple[str, str | None]]) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        box.get_style_context().add_class("printer-alert-card")
        for index, (message, code) in enumerate(alerts):
            if index:
                separator = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
                separator.get_style_context().add_class("maintenance-alert-separator")
                box.pack_start(separator, False, False, 0)
            row = self._alert(message, code)
            row.get_style_context().add_class("maintenance-alert-row")
            box.pack_start(row, False, False, 0)
        return box

    def _task(self, task: Any) -> Gtk.Widget:
        icon = "!" if task.urgent else "⚠" if task.due else "○"
        timing = ((i18n.t("Overdue by {0:.0f} h").format(task.overdue_hours))
                  if task.due else (i18n.t("In {0:.0f} print h").format(task.remaining_hours)))
        if self.pl:
            timing = timing.replace(" druku", "")
        heading = Gtk.Box(spacing=5)
        task_title = Gtk.Label(label=f"{icon}  {task.title}", xalign=0, ellipsize=Pango.EllipsizeMode.END)
        task_title.get_style_context().add_class("maintenance-task-title")
        timing_label = Gtk.Label(label=timing, xalign=1)
        timing_label.get_style_context().add_class("maintenance-task-time")
        heading.pack_start(task_title, True, True, 0); heading.pack_start(timing_label, False, False, 0)
        done = Gtk.Button(label=i18n.t("Done"))
        done.connect("clicked", lambda *_: (self.app.insights.complete(self.printer.serial, task.id), self.rebuild()))
        snooze = Gtk.Button(label="7d")
        snooze.set_tooltip_text(i18n.t("Remind in 7 days"))
        snooze.connect("clicked", lambda *_: (self.app.insights.snooze(self.printer.serial, task.id), self.rebuild()))
        interval = Gtk.Entry()
        interval.set_text(str(round(task.interval_hours)))
        interval.set_width_chars(3); interval.set_max_width_chars(4)
        interval.set_size_request(36, 26)
        interval.set_alignment(0.5)
        save = Gtk.Button(label="✎")
        save.set_tooltip_text(i18n.t("Set interval"))

        def save_interval(*_args: object) -> None:
            try:
                value = float(interval.get_text().replace(",", "."))
            except ValueError:
                return
            if value >= 1:
                self.app.insights.set_interval(self.printer.serial, task.id, value)
                self.rebuild()

        save.connect("clicked", save_interval)
        interval_box = Gtk.Box(spacing=2)
        interval_box.pack_start(interval, False, False, 0)
        hour = Gtk.Label(label="h"); hour.get_style_context().add_class("maintenance-task-time")
        interval_box.pack_start(hour, False, False, 0); interval_box.pack_start(save, False, False, 0)
        actions = Gtk.Box(spacing=4)
        actions.get_style_context().add_class("maintenance-actions")
        actions.pack_start(done, True, True, 0); actions.pack_start(snooze, False, False, 0); actions.pack_start(interval_box, False, False, 0)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        box.get_style_context().add_class("maintenance-task")
        box.pack_start(heading, False, False, 0); box.pack_start(actions, False, False, 0)
        return box

    @staticmethod
    def _metric(value: str, caption: str) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        number = Gtk.Label(label=value); number.get_style_context().add_class("maintenance-stat-value")
        hint = Gtk.Label(label=caption); hint.get_style_context().add_class("maintenance-stat-label")
        box.pack_start(number, False, False, 0); box.pack_start(hint, False, False, 0)
        return box

    def _refresh_parent_views(self) -> None:
        card = self.app.cards.get(self.printer.serial)
        if card is not None: card.update(self.app.telemetry.get(self.printer.serial, self.telemetry))
        detail = getattr(self.app, "detail_panel", None)
        if detail is not None and getattr(detail, "serial", None) == self.printer.serial:
            detail.update(self.app.telemetry.get(self.printer.serial, self.telemetry))

    def _instructions(self, *_args: object) -> None:
        dialog = Gtk.MessageDialog(transient_for=self.app.window, modal=True, message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK,
                                   text=i18n.t("Maintenance instructions"))
        dialog.format_secondary_text((i18n.t("Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide always takes precedence.")))
        dialog.run(); dialog.destroy()

    @staticmethod
    def _label(value: str) -> Gtk.Label:
        label = Gtk.Label(label=value, xalign=0, wrap=True); label.get_style_context().add_class("settings-hint"); return label

    @staticmethod
    def _section(value: str) -> Gtk.Label:
        label = Gtk.Label(label=value, xalign=0); label.get_style_context().add_class("settings-section"); return label


class MaintenanceDialog:
    """Compatibility entry point used by details/cards; presentation stays in the main window."""
    def __init__(self, app: Any, printer: Any, telemetry: Any) -> None:
        self.app, self.printer, self.telemetry = app, printer, telemetry

    def present(self) -> None:
        self.app.window.show_maintenance(self.printer, self.telemetry)
