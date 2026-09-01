from __future__ import annotations

from typing import Any

from gi.repository import Gtk  # type: ignore


def _duration(seconds: float) -> str:
    minutes = int(seconds / 60)
    return f"{minutes // 60}h {minutes % 60}m" if minutes >= 60 else f"{minutes}m"


class MaintenancePanel(Gtk.Frame):
    """Large maintenance card displayed in Gantry's own overlay, not as another OS window."""

    def __init__(self, app: Any, printer: Any, telemetry: Any, close: Any) -> None:
        super().__init__()
        self.app, self.printer, self.telemetry, self.close = app, printer, telemetry, close
        self.pl = app.language == "pl"
        self.set_shadow_type(Gtk.ShadowType.NONE)
        self.set_size_request(520, 680)
        self.set_halign(Gtk.Align.CENTER); self.set_valign(Gtk.Align.CENTER)
        self.get_style_context().add_class("maintenance-panel")
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.body.set_border_width(18)
        self.scroll.add(self.body); self.add(self.scroll)
        self.rebuild()

    def rebuild(self) -> None:
        for child in self.body.get_children():
            self.body.remove(child)
        snap = self.app.insights.snapshot(self.printer.serial, self.pl)

        header = Gtk.Box(spacing=8)
        title = Gtk.Label(label=(f"Konserwacja · {self.printer.name}" if self.pl
                                 else f"Maintenance · {self.printer.name}"), xalign=0)
        title.get_style_context().add_class("settings-title")
        instructions = Gtk.Button(label="Instrukcje" if self.pl else "Instructions")
        instructions.connect("clicked", self._instructions)
        close = Gtk.Button(label="×"); close.set_relief(Gtk.ReliefStyle.NONE)
        close.set_tooltip_text("Zamknij" if self.pl else "Close")
        close.connect("clicked", lambda *_: self.close())
        header.pack_start(title, True, True, 0); header.pack_start(instructions, False, False, 0); header.pack_start(close, False, False, 0)
        self.body.pack_start(header, False, False, 0)
        nozzle = f"{self.telemetry.nozzle_diameter:.1f} mm" if self.telemetry.nozzle_diameter else "—"
        summary = self._label(f"{snap['total_hours']:.1f} " +
                              (f"h druku · dysza {nozzle}" if self.pl else f"print h · nozzle {nozzle}"))
        self.body.pack_start(summary, False, False, 0)

        alerts = self._alerts()
        if alerts:
            self.body.pack_start(self._section("UWAGI DRUKARKI" if self.pl else "PRINTER ALERTS"), False, False, 4)
            for message, code in alerts:
                self.body.pack_start(self._alert(message, code), False, False, 0)

        for task in snap["tasks"]:
            self.body.pack_start(self._task(task), False, False, 0)

        self.body.pack_start(self._section("OSTATNIE WYDRUKI" if self.pl else "RECENT PRINTS"), False, False, 4)
        recent = snap["history"][:3]
        if not recent:
            self.body.pack_start(self._label("Brak zapisanej historii." if self.pl else "No recorded history."), False, False, 0)
        for entry in recent:
            icon = "✓" if entry.get("result") == "completed" else "!" if entry.get("result") == "failed" else "×"
            name = str(entry.get("job") or ("Bez nazwy" if self.pl else "Untitled"))
            self.body.pack_start(self._label(f"{icon}  {name} · {_duration(float(entry.get('durationSeconds', 0)))}"), False, False, 0)
        success = "—" if snap["success"] is None else f"{snap['success']}%"
        stats = (f"STATYSTYKI · {snap['completed']} zakończonych · {success} skuteczności · {snap['consumed_grams']:.0f} g"
                 if self.pl else f"STATISTICS · {snap['completed']} completed · {success} success · {snap['consumed_grams']:.0f} g")
        self.body.pack_start(self._label(stats), False, False, 4)
        self._refresh_parent_views()
        self.show_all()

    def _alerts(self) -> list[tuple[str, str | None]]:
        from .hms import actionable_codes, description
        codes = actionable_codes(self.telemetry.hms_codes, self.printer.serial, self.app.language)
        if codes:
            return [(description([code], self.printer.serial, self.app.language) or f"HMS {code}", code) for code in codes]
        if getattr(self.telemetry, "error_code", 0):
            return [(f"Kod błędu: 0x{self.telemetry.error_code:X}" if self.pl else f"Error code: 0x{self.telemetry.error_code:X}", None)]
        from .core import PrinterState
        if self.telemetry.state == PrinterState.ERROR:
            return [("Drukarka zgłosiła błąd" if self.pl else "Printer reported an error", None)]
        return []

    def _alert(self, message: str, code: str | None) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        box.get_style_context().add_class("printer-alert-card")
        heading = Gtk.Label(label=f"!  {message}", xalign=0, wrap=True)
        heading.get_style_context().add_class("status")
        box.pack_start(heading, False, False, 0)
        if code: box.pack_start(self._label(code), False, False, 0)
        return box

    def _task(self, task: Any) -> Gtk.Widget:
        icon = "!" if task.urgent else "⚠" if task.due else "○"
        timing = ((f"Przekroczono o {task.overdue_hours:.0f} h" if self.pl else f"Overdue by {task.overdue_hours:.0f} h")
                  if task.due else (f"Za {task.remaining_hours:.0f} h druku" if self.pl else f"In {task.remaining_hours:.0f} print h"))
        heading = Gtk.Label(label=f"{icon}  {task.title}", xalign=0)
        heading.get_style_context().add_class("status")
        done = Gtk.Button(label="Wykonano" if self.pl else "Done")
        done.connect("clicked", lambda *_: (self.app.insights.complete(self.printer.serial, task.id), self.rebuild()))
        snooze = Gtk.Button(label="Przypomnij za 7 dni" if self.pl else "Remind in 7 days")
        snooze.connect("clicked", lambda *_: (self.app.insights.snooze(self.printer.serial, task.id), self.rebuild()))
        interval = Gtk.SpinButton.new_with_range(1, 5000, 10)
        interval.set_value(task.interval_hours); interval.set_numeric(True); interval.set_width_chars(4)
        interval.set_alignment(0.5)
        save = Gtk.Button(label="Ustaw" if self.pl else "Set")
        save.connect("clicked", lambda *_: (self.app.insights.set_interval(self.printer.serial, task.id, interval.get_value()), self.rebuild()))
        actions = Gtk.Grid(column_spacing=6)
        actions.attach(done, 0, 0, 1, 1); actions.attach(snooze, 1, 0, 1, 1)
        spacer = Gtk.Box(); spacer.set_hexpand(True); actions.attach(spacer, 2, 0, 1, 1)
        actions.attach(Gtk.Label(label="Co" if self.pl else "Every"), 3, 0, 1, 1)
        actions.attach(interval, 4, 0, 1, 1); actions.attach(Gtk.Label(label="h"), 5, 0, 1, 1); actions.attach(save, 6, 0, 1, 1)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        box.get_style_context().add_class("settings-card")
        box.pack_start(heading, False, False, 0); box.pack_start(self._label(timing), False, False, 0); box.pack_start(actions, False, False, 0)
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
                                   text="Instrukcje konserwacji" if self.pl else "Maintenance instructions")
        dialog.format_secondary_text(("Wyłącz i ostudź drukarkę. Oczyść prowadnice, użyj środka zalecanego przez producenta, sprawdź paski i dyszę. Instrukcja producenta ma zawsze pierwszeństwo."
                                      if self.pl else "Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, then inspect belts and nozzle. The manufacturer guide always takes precedence."))
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
