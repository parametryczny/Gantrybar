from __future__ import annotations

from datetime import datetime
from typing import Any

from gi.repository import Gtk  # type: ignore


def _duration(seconds: float) -> str:
    minutes = int(seconds / 60)
    return f"{minutes // 60}h {minutes % 60}m" if minutes >= 60 else f"{minutes}m"


class MaintenanceDialog(Gtk.Dialog):
    def __init__(self, app: Any, printer: Any, telemetry: Any) -> None:
        super().__init__(title=(f"Konserwacja · {printer.name}" if app.language == "pl"
                               else f"Maintenance · {printer.name}"),
                         transient_for=app.window, modal=False)
        self.app, self.printer, self.telemetry = app, printer, telemetry
        self.pl = app.language == "pl"
        self.set_default_size(440, 540)
        self.add_button("Zamknij" if self.pl else "Close", Gtk.ResponseType.CLOSE)
        self.connect("response", lambda dialog, _response: dialog.destroy())
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.body.get_style_context().add_class("settings-root")
        self.scroll.add(self.body)
        self.get_content_area().pack_start(self.scroll, True, True, 0)
        self.rebuild()

    def present(self) -> None:
        self.show_all()
        super().present()

    def rebuild(self) -> None:
        for child in self.body.get_children():
            self.body.remove(child)
        snap = self.app.insights.snapshot(self.printer.serial, self.pl)
        title = Gtk.Label(label=(f"Konserwacja · {self.printer.name}" if self.pl
                                 else f"Maintenance · {self.printer.name}"), xalign=0)
        title.get_style_context().add_class("settings-title")
        nozzle = f"{self.telemetry.nozzle_diameter:.1f} mm" if self.telemetry.nozzle_diameter else "—"
        summary = Gtk.Label(label=(f"{snap['total_hours']:.1f} h druku · dysza {nozzle}" if self.pl
                                   else f"{snap['total_hours']:.1f} print h · nozzle {nozzle}"), xalign=0)
        summary.get_style_context().add_class("settings-hint")
        self.body.pack_start(title, False, False, 0); self.body.pack_start(summary, False, False, 0)
        for task in snap["tasks"]:
            self.body.pack_start(self._task(task), False, False, 0)

        recent_title = Gtk.Label(label="OSTATNIE WYDRUKI" if self.pl else "RECENT PRINTS", xalign=0)
        recent_title.get_style_context().add_class("settings-section")
        self.body.pack_start(recent_title, False, False, 4)
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
        footer = Gtk.Box(spacing=8)
        instructions = Gtk.Button(label="Instrukcje" if self.pl else "Instructions")
        instructions.connect("clicked", self._instructions)
        history = Gtk.Button(label="Pełna historia" if self.pl else "Full history")
        history.connect("clicked", self._history)
        footer.pack_start(instructions, False, False, 0); footer.pack_end(history, False, False, 0)
        self.body.pack_start(footer, False, False, 2)
        card = self.app.cards.get(self.printer.serial)
        if card is not None:
            card.update(self.app.telemetry.get(self.printer.serial, self.telemetry))
        detail = getattr(self.app, "detail_window", None)
        if detail is not None and getattr(detail, "serial", None) == self.printer.serial:
            detail.update(self.app.telemetry.get(self.printer.serial, self.telemetry))
        self.body.show_all()

    def _task(self, task: Any) -> Gtk.Widget:
        icon = "!" if task.urgent else "⚠" if task.due else "○"
        timing = ((f"Przekroczono o {task.overdue_hours:.0f} h" if self.pl else f"Overdue by {task.overdue_hours:.0f} h")
                  if task.due else (f"Za {task.remaining_hours:.0f} h druku" if self.pl else f"In {task.remaining_hours:.0f} print h"))
        heading = Gtk.Label(label=f"{icon}  {task.title}", xalign=0)
        heading.get_style_context().add_class("status")
        subtitle = self._label(timing)
        done = Gtk.Button(label="Wykonano" if self.pl else "Done")
        done.connect("clicked", lambda *_: (self.app.insights.complete(self.printer.serial, task.id), self.rebuild()))
        snooze = Gtk.Button(label="Przypomnij za 7 dni" if self.pl else "Remind in 7 days")
        snooze.connect("clicked", lambda *_: (self.app.insights.snooze(self.printer.serial, task.id), self.rebuild()))
        interval = Gtk.SpinButton.new_with_range(1, 5000, 10); interval.set_value(task.interval_hours)
        save = Gtk.Button(label="Ustaw" if self.pl else "Set")
        save.connect("clicked", lambda *_: (self.app.insights.set_interval(self.printer.serial, task.id, interval.get_value()), self.rebuild()))
        actions = Gtk.Box(spacing=6)
        actions.pack_start(done, False, False, 0); actions.pack_start(snooze, False, False, 0)
        actions.pack_end(save, False, False, 0); actions.pack_end(interval, False, False, 0)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        box.get_style_context().add_class("settings-card")
        box.pack_start(heading, False, False, 0); box.pack_start(subtitle, False, False, 0); box.pack_start(actions, False, False, 0)
        return box

    def _instructions(self, *_args: object) -> None:
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK,
                                   text="Instrukcje konserwacji" if self.pl else "Maintenance instructions")
        dialog.format_secondary_text(("Wyłącz i ostudź drukarkę. Oczyść prowadnice, użyj środka zalecanego przez producenta, "
                                      "sprawdź paski i dyszę. Instrukcja producenta ma zawsze pierwszeństwo."
                                      if self.pl else "Power off and cool the printer. Clean guide rods, use manufacturer-approved lubricant, "
                                      "then inspect belts and nozzle. The manufacturer guide always takes precedence."))
        dialog.run(); dialog.destroy()

    def _history(self, *_args: object) -> None:
        snap = self.app.insights.snapshot(self.printer.serial, self.pl)
        rows = []
        for entry in snap["history"]:
            ended = str(entry.get("endedAt", ""))[:16].replace("T", " ")
            rows.append(f"{ended} · {entry.get('job') or '—'} · {_duration(float(entry.get('durationSeconds', 0)))}")
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK,
                                   text="Pełna historia" if self.pl else "Full history")
        dialog.format_secondary_text("\n".join(rows[:100]) if rows else ("Brak historii." if self.pl else "No history."))
        dialog.run(); dialog.destroy()

    @staticmethod
    def _label(text: str) -> Gtk.Label:
        label = Gtk.Label(label=text, xalign=0, wrap=True)
        label.get_style_context().add_class("settings-hint")
        return label
