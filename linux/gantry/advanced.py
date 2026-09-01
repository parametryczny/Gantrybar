"""GTK editor for per-printer camera, light and Moonraker overrides."""
from __future__ import annotations

from typing import Any

from gi.repository import Gtk  # type: ignore

from .core import PrinterKind
from .overrides import FIELDS, overrides_for, set_overrides


class AdvancedDialog(Gtk.Dialog):
    def __init__(self, app: Any, serial: str) -> None:
        self.app, self.serial = app, serial
        self.printer = next((printer for printer in app.printers if printer.serial == serial), None)
        self.pl = app.language == "pl"
        name = self.printer.name if self.printer is not None else serial
        super().__init__(title=("Zaawansowane — " if self.pl else "Advanced — ") + name,
                         transient_for=app.window, modal=True)
        self.set_default_size(470, 510 if self._klipper else 310)
        self.add_button("Anuluj" if self.pl else "Cancel", Gtk.ResponseType.CANCEL)
        self.add_button("Zapisz" if self.pl else "Save", Gtk.ResponseType.OK)
        values = overrides_for(app.config, serial)
        self.fields: dict[str, Gtk.Entry] = {}
        root = self.get_content_area(); root.set_spacing(8); root.set_border_width(14)
        self._heading(root, "IP / host kamery (opcjonalnie)" if self.pl else "Camera IP / host (optional)")
        self._hint(root, "Użyj, gdy kamera jest pod innym adresem niż drukarka."
                   if self.pl else "Use when the camera is reachable at a different address than the printer.")
        self._field(root, "cameraHost", "", values)
        self._heading(root, "Własne komendy światła" if self.pl else "Custom light commands")
        self._hint(root, ("Klipper: linia G-code. Puste pola zachowują SET_PIN PIN=caselight."
                          if self._klipper and self.pl else
                          "Klipper: a G-code line. Empty fields keep SET_PIN PIN=caselight."
                          if self._klipper else
                          "Bambu: surowy JSON MQTT. Puste pola zachowują komendę domyślną."
                          if self.pl else "Bambu: raw MQTT JSON. Empty fields keep the default command."))
        self._field(root, "ledOn", "Wł.:" if self.pl else "On:", values)
        self._field(root, "ledOff", "Wył.:" if self.pl else "Off:", values)
        if self._klipper:
            self._heading(root, "Nazwy obiektów Klipper" if self.pl else "Klipper object names")
            self._hint(root, "Puste = extruder / heater_bed / automatyczna komora / fan."
                       if self.pl else "Empty = extruder / heater_bed / automatic chamber / fan.")
            for key, polish, english in (("nozzleObject", "Dysza:", "Nozzle:"),
                                         ("bedObject", "Stół:", "Bed:"),
                                         ("chamberObject", "Komora:", "Chamber:"),
                                         ("fanObject", "Wentylator:", "Fan:")):
                self._field(root, key, polish if self.pl else english, values)
        self.show_all()

    @property
    def _klipper(self) -> bool:
        return self.printer is not None and self.printer.kind == PrinterKind.KLIPPER

    def _heading(self, root: Gtk.Box, text: str) -> None:
        label = Gtk.Label(label=text, xalign=0); label.get_style_context().add_class("settings-section")
        label.set_margin_top(7); root.pack_start(label, False, False, 0)

    @staticmethod
    def _hint(root: Gtk.Box, text: str) -> None:
        label = Gtk.Label(label=text, xalign=0, wrap=True); label.get_style_context().add_class("settings-hint")
        root.pack_start(label, False, False, 0)

    def _field(self, root: Gtk.Box, key: str, label: str, values: dict[str, str]) -> None:
        row = Gtk.Box(spacing=8)
        if label:
            caption = Gtk.Label(label=label, xalign=1); caption.set_size_request(82, -1)
            row.pack_start(caption, False, False, 0)
        entry = Gtk.Entry(text=values.get(key, "")); row.pack_start(entry, True, True, 0)
        self.fields[key] = entry; root.pack_start(row, False, False, 0)

    def save(self) -> None:
        values = {key: field.get_text() for key, field in self.fields.items() if key in FIELDS}
        set_overrides(self.app.config, self.serial, values)
