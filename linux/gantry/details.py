"""Printer Details view for the Linux dashboard, the GTK counterpart of the macOS/Windows "Szczegóły"
panel: a rolling temperature graph (nozzle / bed / chamber), temperatures with their targets, fans
(part / aux / chamber), speed level and nozzle diameter, the AMS/filament modules and progress.

Opened from a card (the chart button or the menu). A tray-anchored frosted window like the Spoolbase
one, so it matches the dashboard rather than popping a plain dialog. gi is already pinned in app.py.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

from gi.repository import Gdk, GLib, Gtk  # type: ignore  # noqa: E402

from . import i18n
from .core import PrinterKind, PrinterState, Telemetry, TEMP_SYMBOLS, temp_state

def _filament_signature(groups: Any, *extra: Any) -> tuple:
    """Everything the AMS section draws, flattened into a comparable tuple. Telemetry arrives several
    times a second; rebuilding the widgets when nothing changed made the card resize and jump, so both
    views compare this first and skip the rebuild when it matches."""
    return (tuple(extra), tuple(
        (group.display_name, group.humidity, group.temperature, tuple(
            (slot.label, slot.material, slot.color, slot.remaining, slot.active,
             slot.remaining_weight_g)
            for slot in group.slots))
        for group in groups))


_SPEED_NAMES = {1: ("Cichy", "Silent"), 2: ("Standard", "Standard"),
                3: ("Sport", "Sport"), 4: ("Wariat", "Ludicrous")}
_STATES = {PrinterState.PRINTING: ("Drukuje", "Printing"), PrinterState.PAUSED: ("Pauza", "Paused"),
           PrinterState.FINISHED: ("Zakończono", "Finished"), PrinterState.ERROR: ("Błąd", "Error"),
           PrinterState.IDLE: ("Bezczynny", "Idle"), PrinterState.OFFLINE: ("Offline", "Offline")}


class TempGraph(Gtk.DrawingArea):
    """Draws the rolling nozzle/bed/chamber history from app.temp_history[serial]."""

    def __init__(self, app: Any, serial: str) -> None:
        super().__init__()
        self.app = app
        self.serial = serial
        self.set_size_request(-1, 132)
        self.connect("draw", self._on_draw)

    def _on_draw(self, _widget: Gtk.DrawingArea, cr: Any) -> bool:
        alloc = self.get_allocation()
        w, h = alloc.width, alloc.height
        cr.set_source_rgba(1, 1, 1, 0.04)
        _rounded(cr, 0, 0, w, h, 10)
        cr.fill()
        history = self.app.temp_history.get(self.serial, [])
        series = [(2, 1.0, 0.41, 0.34), (1, 1.0, 0.62, 0.20), (3, 0.62, 0.66, 0.72)]  # (index, r,g,b)
        values = [v for point in history for v in point[1:] if v is not None]
        top = max(values) if values else 100.0
        top = max(60.0, top * 1.15)
        pad = 8
        # horizontal grid
        cr.set_source_rgba(1, 1, 1, 0.06)
        cr.set_line_width(1)
        for frac in (0.25, 0.5, 0.75):
            y = pad + (h - 2 * pad) * frac
            cr.move_to(pad, y)
            cr.line_to(w - pad, y)
            cr.stroke()
        if len(history) < 2:
            return False
        n = len(history)
        for idx, r, g, b in series:
            cr.set_source_rgba(r, g, b, 0.95)
            cr.set_line_width(1.8)
            drawn = False
            for i, point in enumerate(history):
                value = point[idx]
                if value is None:
                    continue
                x = pad + (w - 2 * pad) * (i / (n - 1))
                y = pad + (h - 2 * pad) * (1 - min(value, top) / top)
                if drawn:
                    cr.line_to(x, y)
                else:
                    cr.move_to(x, y)
                    drawn = True
            cr.stroke()
        return False


class DetailWindow(Gtk.Window):
    def __init__(self, app: Any, serial: str) -> None:
        super().__init__()
        self.app = app
        self.serial = serial
        self._just_shown = False
        self._suppress_hide = False
        printer = next((p for p in app.printers if p.serial == serial), None)
        self.printer_name = printer.name if printer else serial

        rgba = self.get_screen().get_rgba_visual()
        if rgba is not None:
            self.set_visual(rgba)
        self.tray_mode = getattr(app.window, "tray_mode", False)
        if self.tray_mode:
            self.set_default_size(430, 620)
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
        else:
            self.set_title(self.printer_name)
            self.set_default_size(430, 660)
            self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._hide)
        self.connect("destroy", lambda *_: setattr(app, "detail_window", None))

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)

        header = Gtk.Box(spacing=8)
        header.get_style_context().add_class("header")
        back = Gtk.Button(label=("‹ Wróć" if self._pl() else "‹ Back"))
        back.set_relief(Gtk.ReliefStyle.NONE)
        back.get_style_context().add_class("cardmenu")
        back.connect("clicked", lambda *_: self.hide())
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        title = Gtk.Label(label=self.printer_name, xalign=0)
        title.get_style_context().add_class("title")
        self.subtitle = Gtk.Label(xalign=0)
        self.subtitle.get_style_context().add_class("subtitle")
        titles.pack_start(title, False, False, 0)
        titles.pack_start(self.subtitle, False, False, 0)
        header.pack_start(back, False, False, 0)
        header.pack_start(titles, True, True, 0)
        outer.pack_start(header, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        # Request the content's natural height instead of collapsing to zero (fixes an empty/clipped
        # body when the window is sized to content, and lets the offscreen preview capture everything).
        try:
            scroll.set_propagate_natural_height(True)
        except AttributeError:
            pass
        outer.pack_start(scroll, True, True, 0)
        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.body.get_style_context().add_class("detail-body")
        scroll.add(self.body)

        # Status line
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("status")
        self.body.pack_start(self.status, False, False, 0)
        self.progress = Gtk.ProgressBar(show_text=False)
        self.body.pack_start(self.progress, False, False, 0)
        self.meta = Gtk.Label(xalign=0)
        self.meta.get_style_context().add_class("meta")
        self.body.pack_start(self.meta, False, False, 0)

        # Temperature graph
        self.graph = TempGraph(app, serial)
        self.body.pack_start(self.graph, False, False, 0)

        # Dynamic tiles rebuilt on each update.
        self.temps = Gtk.Box(spacing=0, homogeneous=True)
        self.temps.get_style_context().add_class("temp-bento")
        self.body.pack_start(self.temps, False, False, 0)
        self.hw = Gtk.Box(spacing=0, homogeneous=True)
        self.hw.get_style_context().add_class("temp-bento")
        self.body.pack_start(self.hw, False, False, 0)
        self.ams = Gtk.Box(spacing=6)
        self._ams_signature: tuple | None = None
        self.body.pack_start(self.ams, False, False, 0)

        actions = Gtk.Box(spacing=8, homogeneous=True)
        autos = Gtk.Button(label=("Sterowanie i automatyzacje" if self._pl() else "Control and automations"))
        autos.connect("clicked", lambda *_: app.open_automations(serial))
        actions.pack_start(autos, True, True, 0)
        if printer is not None and printer.kind in (PrinterKind.BAMBU, PrinterKind.KLIPPER):
            cam = Gtk.Button(label=("Kamera na żywo" if self._pl() else "Live camera"))
            cam.connect("clicked", lambda *_: app.open_camera(serial))
            actions.pack_start(cam, True, True, 0)
        self.body.pack_start(actions, False, False, 4)

    # ---- data -----------------------------------------------------------------
    def _pl(self) -> bool:
        return self.app.language == "pl"

    def update(self, tel: Telemetry) -> None:
        pl = self._pl()
        state = _STATES.get(tel.state, (tel.state.value, tel.state.value))[0 if pl else 1]
        self.subtitle.set_text(f"{self.serial}")
        job = tel.job_name if (tel.state in {PrinterState.PRINTING, PrinterState.PAUSED} and tel.job_name) else "—"
        self.status.set_text(f"{state}  ·  {job}")
        self.progress.set_fraction(tel.progress / 100)
        if tel.remaining_minutes:
            mins = tel.remaining_minutes
            finish = (datetime.now() + timedelta(minutes=mins)).strftime("%H:%M")
            eta = f"{mins // 60}h {mins % 60}m · {finish}" if mins >= 60 else f"{mins}m · {finish}"
        else:
            eta = "—"
        layers = "—" if tel.current_layer is None else f"{tel.current_layer}/{tel.total_layers or '—'}"
        self.meta.set_text(f"{tel.progress}%   ·   ETA {eta}   ·   {'Warstwa' if pl else 'Layer'} {layers}")

        self._printing = tel.state == PrinterState.PRINTING
        self._errored = tel.state == PrinterState.ERROR
        self._fill_temps(tel, pl)
        self._fill_hardware(tel, pl)
        self._fill_filaments(tel, pl)
        self.graph.queue_draw()
        self.show_all()

    def _tile(self, name: str, value: str, cur: float | None = None, tgt: float | None = None,
              strong: bool = False) -> Gtk.Widget:
        zone = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        zone.get_style_context().add_class("temp-zone")
        label = Gtk.Label(label=name.upper(), xalign=0)
        label.get_style_context().add_class("temp-name")
        mono = bool(self.app.config.data.get("monochrome", False))
        text = value
        if not strong:
            # Temperature values follow state (design/kolorystyka.md §3): at-temp neutral metric (white
            # while holding during a print), cold/idle muted, heating warm, cooling cool, alarm red. In
            # monochrome mode a leading glyph carries the state instead of colour.
            st = temp_state(cur, tgt, getattr(self, "_printing", False),
                            getattr(self, "_errored", False) and tgt is not None)
            if mono:
                text = f"{TEMP_SYMBOLS[st]} {value}"
        val = Gtk.Label(label=text, xalign=0.5)
        vctx = val.get_style_context()
        vctx.add_class("temp-value")
        if strong:
            vctx.add_class("strong")   # hardware values (fans / speed / diameter) stay bright
        elif mono:
            vctx.add_class("mono")     # monochrome keeps every value grey (glyph shows the state)
        else:
            vctx.add_class(st)
        zone.pack_start(label, False, False, 0)
        zone.pack_start(val, False, False, 0)
        return zone

    def _fill_temps(self, tel: Telemetry, pl: bool) -> None:
        for child in self.temps.get_children():
            self.temps.remove(child)

        def fmt(cur: float | None, tgt: float | None) -> str:
            if cur is None:
                return "—"
            return f"{cur:.0f}/{tgt:.0f}°" if tgt else f"{cur:.0f}°"

        nozzles = tel.nozzles
        dual = any(n.position == "right" for n in nozzles)
        if dual:
            left = next((n for n in nozzles if n.position == "left"), nozzles[0])
            right = next((n for n in nozzles if n.position == "right"), None)
            rc, rt = (right.current, right.target) if right else (None, None)
            self.temps.pack_start(self._tile(i18n.t("Nozzle R"), fmt(rc, rt), rc, rt), True, True, 0)
            self.temps.pack_start(self._tile(i18n.t("Nozzle L"), fmt(left.current, left.target),
                                             left.current, left.target), True, True, 0)
        else:
            cur = nozzles[0].current if nozzles else tel.nozzle
            tgt = nozzles[0].target if nozzles else tel.nozzle_target
            self.temps.pack_start(self._tile(i18n.t("Nozzle"), fmt(cur, tgt), cur, tgt), True, True, 0)
        self.temps.pack_start(self._tile(i18n.t("Bed"), fmt(tel.bed, tel.bed_target),
                                         tel.bed, tel.bed_target), True, True, 0)
        self.temps.pack_start(self._tile(i18n.t("Chamber"), fmt(tel.chamber, None),
                                         tel.chamber, None), True, True, 0)

    def _fill_hardware(self, tel: Telemetry, pl: bool) -> None:
        for child in self.hw.get_children():
            self.hw.remove(child)
        fan = lambda v: "—" if v is None else f"{v}%"
        self.hw.pack_start(self._tile(i18n.t("Part fan"), fan(tel.part_fan), strong=True), True, True, 0)
        self.hw.pack_start(self._tile(i18n.t("Aux fan"), fan(tel.aux_fan), strong=True), True, True, 0)
        self.hw.pack_start(self._tile(i18n.t("Chamber fan"), fan(tel.chamber_fan), strong=True), True, True, 0)
        if tel.speed_level or tel.speed_percent is not None:
            name = _SPEED_NAMES.get(tel.speed_level or 0, ("", ""))[0 if pl else 1]
            pct = f"{tel.speed_percent}%" if tel.speed_percent is not None else ""
            self.hw.pack_start(self._tile(i18n.t("Speed"), (f"{name} {pct}").strip() or "—", strong=True), True, True, 0)
        if tel.nozzle_diameter:
            self.hw.pack_start(self._tile(i18n.t("Nozzle mm"), f"{tel.nozzle_diameter:.1f}", strong=True), True, True, 0)

    def _fill_filaments(self, tel: Telemetry, pl: bool) -> None:
        monochrome = bool(self.app.config.data.get("monochrome", False))
        signature = _filament_signature(tel.filament_groups, monochrome)
        if signature == self._ams_signature:
            return
        self._ams_signature = signature
        for child in self.ams.get_children():
            self.ams.remove(child)
        for group in tel.filament_groups:
            gbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
            gbox.get_style_context().add_class("ams-group")
            head = Gtk.Label(xalign=0)
            head.set_markup(f"<b>{GLib.markup_escape_text(group.display_name)}</b>")
            gbox.pack_start(head, False, False, 0)
            srow = Gtk.Box(spacing=4)
            for slot in group.slots:
                sbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
                swatch = Gtk.Label(label="")
                swatch.set_size_request(52, 34)
                ctx = swatch.get_style_context()
                ctx.add_class("ams")
                if slot.active:
                    ctx.add_class("active")
                present = slot.present
                color = (slot.color or "8E8E93FF").lstrip("#")[:6] if present else "5A5A5E"
                if monochrome:
                    from .app import _muted_hex
                    color = _muted_hex(color)
                try:
                    provider = Gtk.CssProvider()
                    provider.load_from_data((".ams { background-color: #%s; }" % color).encode())
                    ctx.add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
                except Exception:
                    pass
                caption = Gtk.Label(label=slot.label, xalign=0.5)
                caption.get_style_context().add_class("meta")
                sbox.pack_start(swatch, False, False, 0)
                sbox.pack_start(caption, False, False, 0)
                if present and slot.remaining is not None:
                    pct = Gtk.Label(label=f"{slot.remaining}%", xalign=0.5)
                    pct.get_style_context().add_class("meta")
                    sbox.pack_start(pct, False, False, 0)
                srow.pack_start(sbox, False, False, 0)
            gbox.pack_start(srow, False, False, 0)
            self.ams.pack_start(gbox, False, False, 0)

    # ---- show / hide ----------------------------------------------------------
    def present_panel(self) -> None:
        self.show_all()
        if self.tray_mode:
            self._position_top_right()
        self.present()
        self._just_shown = True
        GLib.timeout_add(300, self._clear_just_shown)

    def _clear_just_shown(self) -> bool:
        self._just_shown = False
        return False

    def _position_top_right(self) -> None:
        display = Gdk.Display.get_default()
        if display is None:
            return
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return
        area = monitor.get_workarea()
        width, _height = self.get_size()
        self.move(area.x + area.width - width - 8, area.y + 8)

    def _hide(self, *_args: object) -> bool:
        self.hide()
        return True

    def _on_focus_out(self, *_args: object) -> bool:
        if not self._just_shown and not self._suppress_hide:
            self.hide()
        return False


class PhaseStepper(Gtk.Box):
    def __init__(self, pl: bool) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.labels = Gtk.Box()
        self.prep = Gtk.Label(label=i18n.t("Prep"), xalign=0)
        self.printing = Gtk.Label(label=i18n.t("Printing"), xalign=0.5)
        self.done = Gtk.Label(label=i18n.t("Finished"), xalign=1)
        for label in (self.prep, self.printing, self.done):
            label.get_style_context().add_class("slot-id")
            self.labels.pack_start(label, True, True, 0)
        self.track = Gtk.ProgressBar(show_text=False)
        self.track.set_size_request(-1, 8)
        self.pack_start(self.labels, False, False, 0)
        self.pack_start(self.track, False, False, 0)

    def update(self, progress: int, state: PrinterState) -> None:
        self.track.set_fraction(max(0, min(100, progress)) / 100)
        active = 2 if state == PrinterState.FINISHED or progress >= 99 else (0 if progress < 2 else 1)
        for index, label in enumerate((self.prep, self.printing, self.done)):
            provider = Gtk.CssProvider()
            provider.load_from_data(("label { color: %s; font-weight: %s; }" %
                                     ("#f2f3f1" if index == active else "#6d716e",
                                      "600" if index == active else "400")).encode())
            label.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)


class DetailPanel(Gtk.Box):
    DEFAULT_ORDER = ["status", "recent", "maintenance", "stats", "camera", "ams", "temps", "fans", "control"]
    TITLES = {
        "camera": ("Kamera", "Camera"), "ams": ("Filamenty / AMS", "Filaments / AMS"),
        "temps": ("Temperatury", "Temperatures"),
        "fans": ("Wentylatory i prędkość", "Fans & speed"),
        "control": ("Sterowanie i automatyzacje", "Control & automations"),
        "recent": ("Ostatnie wydruki", "Recent prints"),
        "maintenance": ("Konserwacja", "Maintenance"),
        "stats": ("Statystyki", "Statistics"),
    }

    def __init__(self, app: Any, serial: str, on_back: Any) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.app, self.serial = app, serial
        self.get_style_context().add_class("detail-root")
        self.printer = next((p for p in app.printers if p.serial == serial), None)
        self.printer_name = self.printer.name if self.printer else serial
        self._camera_started = False

        header = Gtk.Box(spacing=7)
        back = Gtk.Button(label=i18n.t("‹ Back"))
        back.set_relief(Gtk.ReliefStyle.NONE); back.get_style_context().add_class("cardmenu")
        back.connect("clicked", lambda *_: on_back())
        self.state_dot = Gtk.Label(label="")
        self.state_dot.set_size_request(10, 10)
        self.state_label = Gtk.Label(xalign=1)
        self.state_label.get_style_context().add_class("status")
        header.pack_start(back, False, False, 0)
        header.pack_start(Gtk.Label(label=""), True, True, 0)
        header.pack_start(self.state_dot, False, False, 0)
        header.pack_start(self.state_label, False, False, 0)
        self.pack_start(header, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.pack_start(scroll, True, True, 0)
        self.card_stack = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.card_stack.set_border_width(2)
        scroll.add(self.card_stack)

        # Status card: large printer name / percent, file + layer, phase stepper and ETA.
        status, status_body = self._card("status", None)
        top = Gtk.Box(spacing=8)
        self.name = Gtk.Label(label=self.printer_name, xalign=0, ellipsize=2)
        self.name.get_style_context().add_class("title")
        self.percent = Gtk.Label(label="0%", xalign=1); self.percent.get_style_context().add_class("percent")
        top.pack_start(self.name, True, True, 0); top.pack_end(self.percent, False, False, 0)
        file_row = Gtk.Box(spacing=8)
        self.job = Gtk.Label(xalign=0, ellipsize=2); self.job.get_style_context().add_class("detail-value")
        self.layer = Gtk.Label(xalign=1); self.layer.get_style_context().add_class("metric")
        file_row.pack_start(self.job, True, True, 0); file_row.pack_end(self.layer, False, False, 0)
        self.phase = PhaseStepper(app.language == "pl")
        self.remaining = Gtk.Label(xalign=0); self.remaining.get_style_context().add_class("metric")
        for widget in (top, file_row, self.phase, self.remaining): status_body.pack_start(widget, False, False, 0)

        # Camera card embeds the same stream used by the standalone menu action.
        camera, camera_body = self._card("camera", self._title("camera"))
        from .camera import CameraView
        access_code = None
        if self.printer is not None and self.printer.kind == PrinterKind.BAMBU:
            try: access_code = app.secrets.get(serial)
            except Exception: access_code = None
        self.camera_body = camera_body
        self.camera_access_code = access_code
        self.camera = CameraView(app, serial, access_code)
        self.camera_body.pack_start(self.camera, False, False, 0)
        advanced = Gtk.Button(label=i18n.t("Advanced…"))
        advanced.set_halign(Gtk.Align.END)
        advanced.connect("clicked", lambda *_: app.open_advanced(serial))
        self.camera_body.pack_start(advanced, False, False, 0)

        ams, ams_body = self._card("ams", self._title("ams"))
        self.ams = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self._ams_signature: tuple | None = None
        ams_body.pack_start(self.ams, False, False, 0)

        recent, recent_body = self._card("recent", self._title("recent"))
        self.recent = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        recent_body.pack_start(self.recent, False, False, 0)
        all_prints = Gtk.Button(label=i18n.t("Show all"))
        all_prints.set_halign(Gtk.Align.START); all_prints.connect("clicked", self._show_history)
        recent_body.pack_start(all_prints, False, False, 0)

        maintenance, maintenance_body = self._card("maintenance", self._title("maintenance"))
        self.maintenance = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        maintenance_body.pack_start(self.maintenance, False, False, 0)
        open_maintenance = Gtk.Button(label=i18n.t("Open maintenance…"))
        open_maintenance.set_halign(Gtk.Align.START); open_maintenance.connect("clicked", self._open_maintenance)
        maintenance_body.pack_start(open_maintenance, False, False, 0)

        stats, stats_body = self._card("stats", self._title("stats"))
        self.stats = Gtk.Box(spacing=8, homogeneous=True)
        stats_body.pack_start(self.stats, False, False, 0)

        temps, temps_body = self._card("temps", self._title("temps"))
        self.graph = TempGraph(app, serial); self.graph.set_size_request(-1, 104)
        self.temps = Gtk.Box(spacing=8, homogeneous=True)
        temps_body.pack_start(self.graph, False, False, 0); temps_body.pack_start(self.temps, False, False, 0)

        fans, fans_body = self._card("fans", self._title("fans"))
        self.hardware = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        fans_body.pack_start(self.hardware, False, False, 0)

        control, control_body = self._card("control", self._title("control"))
        controls = Gtk.Box(spacing=6, homogeneous=True)
        light_on = Gtk.Button(label=i18n.t("Light on"))
        light_off = Gtk.Button(label=i18n.t("Light off"))
        autos = Gtk.Button(label=i18n.t("Automations…"))
        light_on.connect("clicked", lambda *_: app.set_chamber_light(serial, True))
        light_off.connect("clicked", lambda *_: app.set_chamber_light(serial, False))
        autos.connect("clicked", lambda *_: app.open_automations(serial))
        for button in (light_on, light_off, autos): controls.pack_start(button, True, True, 0)
        control_body.pack_start(controls, False, False, 0)

        supports_camera = self.printer is not None and self.printer.kind in {
            PrinterKind.BAMBU, PrinterKind.KLIPPER, PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2,
            PrinterKind.ANYCUBIC_KOBRA_S1}
        self.cards: dict[str, Gtk.Widget] = {"status": status, "recent": recent,
                                             "maintenance": maintenance, "stats": stats,
                                             "ams": ams, "temps": temps, "fans": fans}
        if supports_camera: self.cards["camera"] = camera
        if supports_camera and app.config.data.get("developer_mode", False): self.cards["control"] = control
        for card_id, card in self.cards.items(): self._make_draggable(card, card_id)

        self.customize = Gtk.Button(label=i18n.t("Customize"))
        self.customize.set_relief(Gtk.ReliefStyle.NONE); self.customize.get_style_context().add_class("cardmenu")
        self.customize.connect("clicked", self._customize)
        self._layout_cards()
        self.connect("map", self._start_camera)
        self.connect("destroy", lambda *_: self.camera.stop())

    def _title(self, card_id: str) -> str:
        values = self.TITLES[card_id]
        return values[0 if self.app.language == "pl" else 1]

    def _card(self, card_id: str, title: str | None) -> tuple[Gtk.Box, Gtk.Box]:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=7)
        card.get_style_context().add_class("detail-card")
        if title:
            heading = Gtk.Label(label=title.upper(), xalign=0); heading.get_style_context().add_class("detail-title")
            card.pack_start(heading, False, False, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.pack_start(body, False, False, 0)
        card._gantry_id = card_id  # type: ignore[attr-defined]
        return card, body

    def _order(self) -> list[str]:
        saved = self.app.config.data.get("detail_card_order", [])
        result = [value for value in saved if value in self.cards] if isinstance(saved, list) else []
        return result + [value for value in self.DEFAULT_ORDER if value in self.cards and value not in result]

    def _hidden(self) -> set[str]:
        values = self.app.config.data.get("detail_hidden_modules", [])
        return set(values) if isinstance(values, list) else set()

    def _layout_cards(self) -> None:
        for child in self.card_stack.get_children(): self.card_stack.remove(child)
        hidden = self._hidden()
        for card_id in self._order():
            if card_id not in hidden: self.card_stack.pack_start(self.cards[card_id], False, False, 0)
        self.card_stack.pack_start(self.customize, False, False, 0)
        self.card_stack.show_all()
        if "camera" in hidden: self.camera.stop()

    def _customize(self, button: Gtk.Button) -> None:
        menu = Gtk.Menu(); hidden = self._hidden()
        for card_id in ("recent", "maintenance", "stats", "camera", "ams", "temps", "fans", "control"):
            if card_id not in self.cards: continue
            item = Gtk.CheckMenuItem(label=self._title(card_id)); item.set_active(card_id not in hidden)
            item.connect("toggled", lambda value, key=card_id: self._toggle_module(key, value.get_active()))
            menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        reset = Gtk.MenuItem(label=i18n.t("Restore default layout"))
        reset.connect("activate", lambda *_: self._reset_layout()); menu.append(reset)
        menu.show_all()
        window = getattr(self.app, "window", None)
        if window is not None:
            window._suppress_hide = True
            menu.connect("deactivate", lambda *_: setattr(window, "_suppress_hide", False))
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_WEST, Gdk.Gravity.NORTH_WEST, None)

    def _toggle_module(self, card_id: str, visible: bool) -> None:
        hidden = self._hidden()
        if visible: hidden.discard(card_id)
        else: hidden.add(card_id)
        self.app.config.data["detail_hidden_modules"] = sorted(hidden); self.app.config.save()
        self._layout_cards()
        if card_id == "camera":
            if visible: self._replace_and_start_camera()
            else:
                self.camera.stop(); self._camera_started = False

    def _reset_layout(self) -> None:
        camera_was_hidden = "camera" in self._hidden()
        self.app.config.data["detail_hidden_modules"] = []
        self.app.config.data["detail_card_order"] = []
        self.app.config.save(); self._layout_cards()
        if camera_was_hidden and "camera" in self.cards: self._replace_and_start_camera()

    def _make_draggable(self, card: Gtk.Widget, card_id: str) -> None:
        target = Gtk.TargetEntry.new("application/x-gantry-detail-card", Gtk.TargetFlags.SAME_APP, 0)
        card.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [target], Gdk.DragAction.MOVE)
        card.drag_dest_set(Gtk.DestDefaults.ALL, [target], Gdk.DragAction.MOVE)
        card.connect("drag-data-get", lambda _w, _c, selection, _i, _t, key=card_id: selection.set_text(key, -1))
        card.connect("drag-data-received", lambda _w, context, x, _y, selection, _i, timestamp, key=card_id:
                     self._drop_card(context, x, selection, timestamp, key))

    def _drop_card(self, context: Gdk.DragContext, x: int, selection: Gtk.SelectionData,
                   timestamp: int, target: str) -> None:
        source = selection.get_text() or ""
        order = self._order()
        if source in order and target in order and source != target:
            order.remove(source); index = order.index(target)
            width = max(1, self.cards[target].get_allocated_width())
            order.insert(index + (1 if x >= width / 2 else 0), source)
            self.app.config.data["detail_card_order"] = order; self.app.config.save(); self._layout_cards()
        Gtk.drag_finish(context, True, True, timestamp)

    def _start_camera(self, *_args: Any) -> None:
        if self._camera_started or "camera" not in self.cards or "camera" in self._hidden(): return
        self._camera_started = True; self.camera.start()

    def _replace_and_start_camera(self) -> None:
        from .camera import CameraView
        self.camera.stop()
        self.camera_body.remove(self.camera)
        self.camera = CameraView(self.app, self.serial, self.camera_access_code)
        self.camera_body.pack_start(self.camera, False, False, 0)
        self.camera.show_all()
        self._camera_started = True
        self.camera.start()

    def deactivate(self) -> None:
        self.camera.stop()

    def update(self, tel: Telemetry) -> None:
        pl = self.app.language == "pl"
        state = _STATES.get(tel.state, (tel.state.value, tel.state.value))[0 if pl else 1]
        colors = {PrinterState.PRINTING: "#0a84ff", PrinterState.IDLE: "#30d158",
                  PrinterState.FINISHED: "#30d158", PrinterState.PAUSED: "#ff9f0a",
                  PrinterState.ERROR: "#ff453a", PrinterState.OFFLINE: "#8e8e93"}
        color = colors[tel.state]
        provider = Gtk.CssProvider(); provider.load_from_data(f"label {{ color: {color}; }}".encode())
        self.state_dot.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        dot_provider = Gtk.CssProvider(); dot_provider.load_from_data(f"label {{ background: {color}; border-radius: 5px; }}".encode())
        self.state_dot.get_style_context().add_provider(dot_provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self.state_label.set_text(state); self.state_label.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self.percent.set_text(f"{tel.progress}%"); self.phase.update(tel.progress, tel.state)
        self.job.set_text(tel.job_name or "")
        self.layer.set_text((f"Warstwa {tel.current_layer} / {tel.total_layers}" if pl else
                             f"Layer {tel.current_layer} / {tel.total_layers}")
                            if tel.current_layer is not None and tel.total_layers else "")
        if tel.remaining_minutes and tel.state in {PrinterState.PRINTING, PrinterState.PAUSED}:
            finish = (datetime.now() + timedelta(minutes=tel.remaining_minutes)).strftime("%H:%M")
            remaining = (f"{tel.remaining_minutes // 60}h {tel.remaining_minutes % 60}m"
                         if tel.remaining_minutes >= 60 else f"{tel.remaining_minutes}m")
            self.remaining.set_text(f"{remaining} · {finish}")
        else: self.remaining.set_text("")
        self._fill_temperatures(tel, pl); self._fill_hardware(tel, pl); self._fill_filaments(tel)
        self._fill_insights(pl)
        self.graph.queue_draw(); self.show_all()

    def _fill_insights(self, pl: bool) -> None:
        snap = self.app.insights.snapshot(self.serial, pl)
        self._clear(self.recent)
        recent = snap["history"][:3]
        if not recent:
            self.recent.pack_start(self._line(i18n.t("No recorded history.")), False, False, 0)
        for entry in recent:
            icon = "✓" if entry.get("result") == "completed" else "!" if entry.get("result") == "failed" else "×"
            minutes = int(float(entry.get("durationSeconds", 0)) / 60)
            duration = f"{minutes // 60}h {minutes % 60}m" if minutes >= 60 else f"{minutes}m"
            self.recent.pack_start(self._line(f"{icon}  {entry.get('job') or '—'} · {duration}"), False, False, 0)
        self._clear(self.maintenance)
        ordered = sorted(snap["tasks"], key=lambda task: (not task.urgent, not task.due, task.remaining_hours))[:2]
        for task in ordered:
            timing = (f"przekroczono o {task.overdue_hours:.0f} h" if pl else f"overdue by {task.overdue_hours:.0f} h") if task.due \
                else (f"za {task.remaining_hours:.0f} h druku" if pl else f"in {task.remaining_hours:.0f} print h")
            self.maintenance.pack_start(self._line(f"{'!' if task.urgent else '⚠' if task.due else '○'}  {task.title} · {timing}"), False, False, 0)
        self._clear(self.stats)
        success = "—" if snap["success"] is None else f"{snap['success']}%"
        for title, value in (((i18n.t("Print time")), f"{snap['total_hours']:.1f} h"),
                             ((i18n.t("Success")), success),
                             (("Filament"), f"{snap['consumed_grams']:.0f} g")):
            self.stats.pack_start(self._metric(title, value), True, True, 0)

    def _open_maintenance(self, *_args: object) -> None:
        if self.printer is None: return
        from .maintenance import MaintenanceDialog
        tel = self.app.telemetry.get(self.serial, Telemetry())
        MaintenanceDialog(self.app, self.printer, tel).present()

    def _show_history(self, *_args: object) -> None:
        snap = self.app.insights.snapshot(self.serial, self.app.language == "pl")
        rows = [f"{str(item.get('endedAt', ''))[:16].replace('T', ' ')} · {item.get('job') or '—'}"
                for item in snap["history"]]
        dialog = Gtk.MessageDialog(transient_for=self.get_toplevel(), modal=True,
                                   message_type=Gtk.MessageType.INFO, buttons=Gtk.ButtonsType.OK,
                                   text=i18n.t("Full history"))
        dialog.format_secondary_text("\n".join(rows[:100]) if rows else
                                     (i18n.t("No history.")))
        dialog.run(); dialog.destroy()

    @staticmethod
    def _line(text: str) -> Gtk.Label:
        label = Gtk.Label(label=text, xalign=0, ellipsize=2)
        label.get_style_context().add_class("metric")
        return label

    def _fill_temperatures(self, tel: Telemetry, pl: bool) -> None:
        self._clear(self.temps)
        nozzles = tel.nozzles; dual = any(n.position == "right" for n in nozzles)
        values: list[tuple[str, float | None, float | None]] = []
        if dual:
            left = next((n for n in nozzles if n.position == "left"), nozzles[0])
            right = next((n for n in nozzles if n.position == "right"), None)
            values.extend([("L", left.current, left.target), (i18n.t("R"), right.current if right else None, right.target if right else None)])
        else:
            nozzle = nozzles[0] if nozzles else None
            values.append((i18n.t("Nozzle"), nozzle.current if nozzle else tel.nozzle,
                           nozzle.target if nozzle else tel.nozzle_target))
        values.append((i18n.t("Bed"), tel.bed, tel.bed_target))
        if tel.chamber is not None: values.append((i18n.t("Chamber"), tel.chamber, None))
        for name, current, target in values:
            self.temps.pack_start(self._metric(name, self._temp(current, target)), True, True, 0)

    def _fill_hardware(self, tel: Telemetry, pl: bool) -> None:
        self._clear(self.hardware); fan = lambda value: "—" if value is None else f"{value}%"
        fan_row = Gtk.Box(spacing=8, homogeneous=True)
        for name, value in (("Part", fan(tel.part_fan)), ("Aux", fan(tel.aux_fan)), ("Chamber", fan(tel.chamber_fan))):
            fan_row.pack_start(self._metric(name, value), True, True, 0)
        self.hardware.pack_start(fan_row, False, False, 0)
        if tel.speed_level or tel.speed_percent is not None:
            speed = _SPEED_NAMES.get(tel.speed_level or 0, ("—", "—"))[0 if pl else 1]
            if tel.speed_percent is not None: speed += f" · {tel.speed_percent}%"
            self.hardware.pack_start(self._metric(i18n.t("Speed"), speed), False, False, 0)
        if tel.nozzle_diameter:
            self.hardware.pack_start(self._metric(i18n.t("Nozzle diameter"), f"⌀ {tel.nozzle_diameter:.1f} mm"), False, False, 0)

    def _fill_filaments(self, tel: Telemetry) -> None:
        signature = _filament_signature(tel.filament_groups)
        if signature == self._ams_signature:
            return
        self._ams_signature = signature
        self._clear(self.ams)
        for group in tel.filament_groups:
            title = Gtk.Label(label=group.display_name, xalign=0); title.get_style_context().add_class("detail-value")
            self.ams.pack_start(title, False, False, 0)
            slots = Gtk.Box(spacing=5, homogeneous=True)
            for slot in group.slots:
                text = slot.material or "—"
                if slot.remaining is not None: text += f" · {slot.remaining}%"
                chip = Gtk.Label(label=f"{slot.label}\n{text}"); chip.get_style_context().add_class("metric")
                slots.pack_start(chip, True, True, 0)
            self.ams.pack_start(slots, False, False, 0)

    @staticmethod
    def _clear(container: Gtk.Container) -> None:
        for child in container.get_children(): container.remove(child)

    @staticmethod
    def _metric(name: str, value: str) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        label = Gtk.Label(label=name.upper()); label.get_style_context().add_class("detail-title")
        data = Gtk.Label(label=value); data.get_style_context().add_class("detail-value")
        box.pack_start(label, False, False, 0); box.pack_start(data, False, False, 0)
        return box

    @staticmethod
    def _temp(current: float | None, target: float | None) -> str:
        if current is None: return "—"
        return f"{current:.0f}° / {target:.0f}°" if target else f"{current:.0f}° / —"


def _rounded(cr: Any, x: float, y: float, w: float, h: float, r: float) -> None:
    import math
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()
