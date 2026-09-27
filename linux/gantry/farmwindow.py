from __future__ import annotations

"""Farm window: sliced 3MF files, sending to Bambu Lab printers with an explicit start, and the queue that
hands copies to printers marked with an empty bed. Mirrors the macOS Farm window.

gi is already pinned in app.py.
"""

from typing import Any

from gi.repository import GdkPixbuf, GLib, Gtk  # type: ignore

from . import i18n
from .core import STATE_LABELS, PrinterKind, PrinterState
from .farm import FarmError, FarmStore, slot_index
from .panelwindow import panel_header


def _label(text: str, css: str = "settings-hint", bold: bool = False) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=0, wrap=True)
    label.get_style_context().add_class("settings-version" if bold else css)
    return label


def _section(text: str) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=0)
    label.get_style_context().add_class("settings-section")
    return label


def _card(child: Gtk.Widget) -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    box.get_style_context().add_class("settings-card")
    box.pack_start(child, True, True, 0)
    return box


def _scroll(child: Gtk.Widget) -> Gtk.ScrolledWindow:
    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.add(child)
    return scroll


class FarmWindow(Gtk.Window):
    _current: "FarmWindow | None" = None

    @classmethod
    def show_for(cls, app: Any) -> None:
        if app.farm is None:
            app.farm = FarmStore(app, on_main=lambda job: GLib.idle_add(lambda: (job(), False)[1]))
        if cls._current is not None:
            cls._current.present()
            return
        cls._current = FarmWindow(app)
        cls._current.show_all()
        cls._current.present()

    def __init__(self, app: Any) -> None:
        super().__init__(title="Farma")
        panel_header(self, "Farma")
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_default_size(1080, 700)
        self.app, self.farm = app, app.farm
        self.selected: str | None = None
        self.plate_index = 1
        self.copies = 1
        self.targets: dict[str, Gtk.CheckButton] = {}
        self.mappings: dict[str, dict[int, Gtk.ComboBoxText]] = {}
        self.progress_labels: dict[str, Gtk.Label] = {}

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.get_style_context().add_class("settings-root")
        root.pack_start(_label("Wybierz plik i drukarki. Wyślij teraz — rozpocznij druk, gdy stół będzie gotowy. Albo dodaj do kolejki."),
                        False, False, 0)
        columns = Gtk.Box(spacing=10)
        self.library = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.details = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.destinations = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        left, middle, right = _card(_scroll(self.library)), _card(_scroll(self.details)), _card(_scroll(self.destinations))
        left.set_size_request(220, -1)
        right.set_size_request(300, -1)
        columns.pack_start(left, False, False, 0)
        columns.pack_start(middle, True, True, 0)
        columns.pack_start(right, False, False, 0)
        root.pack_start(columns, True, True, 0)

        actions = Gtk.Box(spacing=8)
        for text, callback in (("＋ Dodaj pliki…", self._choose_files),):
            button = Gtk.Button(label=text); button.connect("clicked", lambda *_a, c=callback: c())
            actions.pack_start(button, False, False, 0)
        actions.pack_start(_label("Pliki 3MF: Bambu Studio → Plik → Eksportuj → Eksportuj pociętą płytę"), False, False, 0)
        for text, callback in (("Wyślij do zaznaczonych", self._send_selected), ("Odśwież AMS", self._refresh_details)):
            button = Gtk.Button(label=text); button.connect("clicked", lambda *_a, c=callback: c())
            actions.pack_end(button, False, False, 0)
        root.pack_start(actions, False, False, 0)

        self.history = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        history = _card(_scroll(self.history))
        history.set_size_request(-1, 220)
        root.pack_start(history, False, False, 0)
        self.notice = _label("")
        root.pack_start(self.notice, False, False, 0)
        self.add(root)

        self.farm.listeners.append(self._changed)
        self.connect("destroy", self._destroyed)
        self._refresh_files(); self._refresh_details(); self._refresh_history()

    def _destroyed(self, *_args: Any) -> None:
        if self._changed in self.farm.listeners:
            self.farm.listeners.remove(self._changed)
        FarmWindow._current = None

    def _changed(self) -> None:
        self.notice.set_text(self.farm.notice)
        for job_id, value in self.farm.progress.items():
            label = self.progress_labels.get(job_id)
            if label is not None:
                label.set_text(f"Wysyłanie: {int(value * 100)}%")
        if not self.farm.progress:
            self._refresh_history()

    @staticmethod
    def _clear(box: Gtk.Box) -> None:
        for child in box.get_children():
            box.remove(child)

    # ------------------------------------------------------------ files

    def _choose_files(self) -> None:
        chooser = Gtk.FileChooserDialog(title="Dodaj pliki 3MF", transient_for=self, action=Gtk.FileChooserAction.OPEN)
        chooser.add_buttons("Anuluj", Gtk.ResponseType.CANCEL, "Dodaj", Gtk.ResponseType.ACCEPT)
        chooser.set_select_multiple(True)
        pattern = Gtk.FileFilter(); pattern.set_name("3MF"); pattern.add_pattern("*.3mf"); pattern.add_pattern("*.3MF")
        chooser.add_filter(pattern)
        paths = chooser.get_filenames() if chooser.run() == Gtk.ResponseType.ACCEPT else []
        chooser.destroy()
        for path in paths:
            self.farm.import_file(path)
        if self.farm.files:
            self.selected = self.farm.files[-1]["id"]
            self.plate_index = self.farm.files[-1]["plates"][0]["index"]
        self._refresh_files(); self._refresh_details()

    def _refresh_files(self) -> None:
        self._clear(self.library)
        self.library.pack_start(_section("PLIKI"), False, False, 0)
        if self.selected is None and self.farm.files:
            self.selected = self.farm.files[0]["id"]
        for file in self.farm.files:
            button = Gtk.Button(label=("● " if file["id"] == self.selected else "") + file["name"])
            button.get_child().set_ellipsize(3)   # Pango.EllipsizeMode.END
            button.set_tooltip_text(file["name"])
            button.connect("clicked", lambda _b, f=file: self._select(f))
            self.library.pack_start(button, False, False, 0)
            self.library.pack_start(_label(f"Płyty: {len(file['plates'])} · {file['bytes'] / 1048576:.1f} MB"), False, False, 0)
        if not self.farm.files:
            self.library.pack_start(_label("Dodaj plik z Bambu Studio:\nPlik → Eksportuj → Eksportuj pociętą płytę."), False, False, 0)
        self.library.show_all()

    def _select(self, file: dict[str, Any]) -> None:
        self.selected = file["id"]
        self.plate_index = file["plates"][0]["index"] if file["plates"] else 1
        self._refresh_files(); self._refresh_details()

    def _selection(self) -> tuple[dict[str, Any], dict[str, Any]] | None:
        file = next((f for f in self.farm.files if f["id"] == self.selected), None)
        if file is None or not file["plates"]:
            return None
        plate = next((p for p in file["plates"] if p["index"] == self.plate_index), file["plates"][0])
        return file, plate

    # ------------------------------------------------------------ plate and printers

    def _refresh_details(self) -> None:
        self._clear(self.details); self._clear(self.destinations)
        self.targets, self.mappings = {}, {}
        self.details.pack_start(_section("PODGLĄD PŁYTY"), False, False, 0)
        selection = self._selection()
        if selection is None:
            self.details.pack_start(_label("Dodaj pocięty plik 3MF, aby zobaczyć płytę, materiały i czas druku."), False, False, 0)
            self.details.show_all(); self.destinations.show_all()
            return
        file, plate = selection
        self.plate_index = plate["index"]
        self.details.pack_start(_label(file["name"], bold=True), False, False, 0)
        plates = Gtk.ComboBoxText()
        for p in file["plates"]:
            plates.append(str(p["index"]), f"Płyta {p['index']}")
        plates.set_active_id(str(plate["index"]))
        plates.connect("changed", lambda combo: self._change_plate(int(combo.get_active_id() or "1")))
        self.details.pack_start(plates, False, False, 0)
        preview = self.farm.preview_path(file["id"], plate["index"])
        if preview.exists():
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(preview), -1, 170, True)
                self.details.pack_start(Gtk.Image.new_from_pixbuf(pixbuf), False, False, 0)
            except GLib.Error:
                self.details.pack_start(_label("Plik nie zawiera miniatury tej płyty."), False, False, 0)
        else:
            self.details.pack_start(_label("Plik nie zawiera miniatury tej płyty."), False, False, 0)
        if plate.get("seconds") is not None:
            seconds = plate["seconds"]
            self.details.pack_start(_label(f"Czas według slicera: {seconds // 3600} h {seconds % 3600 // 60} min"), False, False, 0)
        nozzle = f"{plate['nozzle']} mm" if plate.get("nozzle") is not None else "nie podano"
        self.details.pack_start(_label(f"Profil: {plate.get('printerModel') or 'nie podano'} · dysza: {nozzle}"), False, False, 0)
        for f in plate.get("filaments", []):
            self.details.pack_start(_label(f"Filament {f['id']}: {f['material']} · {f['color']} · {f['grams']:.1f} g"), False, False, 0)

        self.details.pack_start(_section("KOLEJKA"), False, False, 0)
        row = Gtk.Box(spacing=8)
        row.pack_start(Gtk.Label(label="Kopie:"), False, False, 0)
        spin = Gtk.SpinButton.new_with_range(1, 99, 1)
        spin.set_value(self.copies)
        spin.connect("value-changed", lambda s: setattr(self, "copies", int(s.get_value())))
        row.pack_start(spin, False, False, 0)
        enqueue = Gtk.Button(label="Dodaj do kolejki…")
        enqueue.connect("clicked", lambda *_: self._confirm_enqueue())
        row.pack_start(enqueue, False, False, 0)
        self.details.pack_start(row, False, False, 0)
        self.details.pack_start(_label("Kolejka wysyła kopie na drukarki oznaczone „Stół pusty”, z pasującym materiałem i kolorem w AMS, i sama uruchamia druk."),
                                False, False, 0)

        self.destinations.pack_start(_section("DRUKARKI"), False, False, 0)
        bambu = [p for p in self.app.printers if p.kind == PrinterKind.BAMBU]
        for printer in bambu:
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            check = Gtk.CheckButton(label=printer.name)
            self.targets[printer.serial] = check
            box.pack_start(check, False, False, 0)
            telemetry = self.app.telemetry.get(printer.serial)
            state = telemetry.state.value if telemetry is not None else "offline"
            box.pack_start(_label(i18n.t(STATE_LABELS.get("ready" if state == "idle" else state, state))), False, False, 0)
            arm = Gtk.CheckButton(label="Stół pusty — kolejka może startować")
            arm.set_active(printer.serial in self.farm.armed)
            arm.connect("toggled", self._toggle_arm, printer.serial)
            box.pack_start(arm, False, False, 0)
            choices: dict[int, Gtk.ComboBoxText] = {}
            for f in plate.get("filaments", []):
                box.pack_start(_label(f"Filament {f['id']} · {f['material']}"), False, False, 0)
                combo = Gtk.ComboBoxText()
                combo.append("-2", "Wybierz źródło…")
                if len(plate["filaments"]) == 1:
                    combo.append("-1", "Szpula zewnętrzna")
                for slot in (telemetry.ams_slots if telemetry is not None else []):
                    index = slot_index(slot.slot_id)
                    if index is not None and slot.material != "—":
                        combo.append(str(index), f"{slot.label} · {slot.material} · {slot.color[:6]}")
                combo.set_active_id("-2")
                choices[f["id"]] = combo
                box.pack_start(combo, False, False, 0)
            self.mappings[printer.serial] = choices
            self.destinations.pack_start(_card(box), False, False, 0)
        if not bambu:
            self.destinations.pack_start(_label("Dodaj drukarkę Bambu Lab w Gantry."), False, False, 0)
        self.details.show_all(); self.destinations.show_all()

    def _change_plate(self, index: int) -> None:
        if index != self.plate_index:
            self.plate_index = index
            GLib.idle_add(lambda: (self._refresh_details(), False)[1])

    def _toggle_arm(self, button: Gtk.CheckButton, serial: str) -> None:
        if button.get_active():
            try:
                self.farm.arm(serial)
            except FarmError as error:
                button.handler_block_by_func(self._toggle_arm)
                button.set_active(False)
                button.handler_unblock_by_func(self._toggle_arm)
                self.notice.set_text(str(error))
        else:
            self.farm.disarm(serial)

    def _send_selected(self) -> None:
        selection = self._selection()
        if selection is None:
            return
        file, plate = selection
        targets = [p for p in self.app.printers if self.targets.get(p.serial) and self.targets[p.serial].get_active()]
        if not targets:
            self.notice.set_text("Zaznacz co najmniej jedną drukarkę.")
            return
        plans = []
        for printer in targets:
            options = self.mappings.get(printer.serial, {})
            if any(combo.get_active_id() == "-2" for combo in options.values()):
                self.notice.set_text(f"Wybierz źródła filamentów dla {printer.name}.")
                return
            filaments = plate.get("filaments", [])
            mapping = [-1] * (max((f["id"] for f in filaments), default=0))
            for f in filaments:
                mapping[f["id"] - 1] = int(options[f["id"]].get_active_id() or "-1") if f["id"] in options else -1
            if all(value == -1 for value in mapping):
                mapping = []
            plans.append((printer, mapping))
        errors = []
        for printer, mapping in plans:
            try:
                self.farm.upload_to(file, plate, printer, mapping)
            except FarmError as error:
                errors.append(f"{printer.name}: {error}")
        self.notice.set_text("\n".join(errors) if errors else f"Rozpoczęto wysyłanie do {len(plans)} drukarek. Druk uruchomisz osobno.")

    def _confirm(self, title: str, detail: str, action: str, checks: list[str]) -> bool:
        dialog = Gtk.Dialog(title=title, transient_for=self, modal=True)
        dialog.add_button("Anuluj", Gtk.ResponseType.CANCEL)
        ok = dialog.add_button(action, Gtk.ResponseType.OK)
        box = dialog.get_content_area()
        box.set_spacing(8); box.set_margin_top(12); box.set_margin_bottom(8); box.set_margin_start(16); box.set_margin_end(16)
        box.pack_start(_label(title, bold=True), False, False, 0)
        box.pack_start(_label(detail), False, False, 0)
        boxes = [Gtk.CheckButton(label=text) for text in checks]
        for check in boxes:
            box.pack_start(check, False, False, 0)
            check.connect("toggled", lambda *_: ok.set_sensitive(all(c.get_active() for c in boxes)))
        ok.set_sensitive(not boxes)
        dialog.show_all()
        result = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        return result

    def _confirm_enqueue(self) -> None:
        selection = self._selection()
        if selection is None:
            return
        file, plate = selection
        targets = [p for p in self.app.printers if p.kind == PrinterKind.BAMBU and self.targets.get(p.serial) and self.targets[p.serial].get_active()]
        where = "dowolna drukarka Bambu Lab" if not targets else "tylko: " + ", ".join(p.name for p in targets)
        if not self._confirm(f"Dodać do kolejki {self.copies} × {file['name']}?",
                             f"Płyta {plate['index']} · {where}\nKopia trafi na drukarkę dopiero, gdy oznaczysz jej stół jako pusty, a w AMS będzie ten sam materiał w podobnym kolorze. Druk startuje wtedy sam.",
                             "Dodaj do kolejki", ["Profil pliku i dysza pasują do tych drukarek"]):
            return
        try:
            self.farm.enqueue(file, plate, self.copies, [p.serial for p in targets])
        except FarmError as error:
            self.notice.set_text(str(error))

    # ------------------------------------------------------------ queue and jobs

    def _refresh_history(self) -> None:
        self._clear(self.history)
        self.progress_labels = {}
        if self.farm.queue:
            self.history.pack_start(_section(f"KOLEJKA · {sum(item['copies'] for item in self.farm.queue)} SZT."), False, False, 0)
            names = {p.serial: p.name for p in self.app.printers}
            for position, item in enumerate(self.farm.queue):
                where = ", ".join(names.get(s, s) for s in item.get("printers") or []) or "dowolna drukarka"
                row = Gtk.Box(spacing=6)
                row.pack_start(_label(f"{position + 1}. {item['fileName']} · płyta {item['plate']['index']} × {item['copies']} · {where}", bold=True),
                               True, True, 0)
                up = Gtk.Button(label="↑"); up.set_sensitive(position > 0)
                up.connect("clicked", lambda _b, i=item["id"]: self.farm.move_up(i))
                remove = Gtk.Button(label="Usuń")
                remove.connect("clicked", lambda _b, i=item["id"]: self.farm.remove_from_queue(i))
                row.pack_end(remove, False, False, 0); row.pack_end(up, False, False, 0)
                self.history.pack_start(_card(row), False, False, 0)
        self.history.pack_start(_section("TRANSFERY I WYDRUKI"), False, False, 0)
        if not self.farm.jobs:
            self.history.pack_start(_label("Tutaj pojawią się wysłane pliki i potwierdzenia uruchomienia."), False, False, 0)
        for job in self.farm.jobs[:100]:
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            box.pack_start(_label(f"{job['printerName']} · {job['fileName']} · płyta {job['plate']['index']}", bold=True), False, False, 0)
            message = _label(job["message"])
            self.progress_labels[job["id"]] = message
            box.pack_start(message, False, False, 0)
            buttons = Gtk.Box(spacing=6)
            if job["state"] == "uploaded":
                button = Gtk.Button(label="Rozpocznij druk…"); button.connect("clicked", lambda _b, j=job: self._confirm_start(j))
                buttons.pack_start(button, False, False, 0)
            if job["state"] == "uploading":
                button = Gtk.Button(label="Anuluj transfer"); button.connect("clicked", lambda _b, j=job: self.farm.cancel(j["id"]))
                buttons.pack_start(button, False, False, 0)
            if job["state"] == "uncertain":
                button = Gtk.Button(label="Sprawdziłem drukarkę…"); button.connect("clicked", lambda _b, j=job: self._confirm_resolve(j))
                buttons.pack_start(button, False, False, 0)
            if buttons.get_children():
                box.pack_start(buttons, False, False, 0)
            self.history.pack_start(_card(box), False, False, 0)
        self.history.show_all()

    def _confirm_start(self, job: dict[str, Any]) -> None:
        reason = self.farm.block_reason(job)
        if reason:
            self.notice.set_text(reason)
            return
        if not self._confirm(f"Rozpocząć druk na {job['printerName']}?",
                             f"{job['fileName']} · płyta {job['plate']['index']}\nPrzed startem sprawdź materiał oraz profil modelu i dyszy. Poziomowanie stołu: włączone.",
                             "Rozpocznij druk", ["Stół jest pusty i przygotowany", "Profil pliku, dysza i materiał pasują do drukarki"]):
            return
        try:
            self.farm.start(job["id"], True, True)
        except FarmError as error:
            self.notice.set_text(str(error))

    def _confirm_resolve(self, job: dict[str, Any]) -> None:
        if self._confirm("Zamknąć niepotwierdzone zadanie?",
                         f"Potwierdź, że sprawdziłeś stan {job['printerName']}. Nie wyślemy ponownie polecenia startu.",
                         "Sprawdziłem — zamknij zadanie", []):
            self.farm.resolve(job["id"])
