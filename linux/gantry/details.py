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

from .core import PrinterKind, PrinterState, Telemetry, TEMP_SYMBOLS, temp_state

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
            self.temps.pack_start(self._tile("Dysza P" if pl else "Nozzle R", fmt(rc, rt), rc, rt), True, True, 0)
            self.temps.pack_start(self._tile("Dysza L" if pl else "Nozzle L", fmt(left.current, left.target),
                                             left.current, left.target), True, True, 0)
        else:
            cur = nozzles[0].current if nozzles else tel.nozzle
            tgt = nozzles[0].target if nozzles else tel.nozzle_target
            self.temps.pack_start(self._tile("Dysza" if pl else "Nozzle", fmt(cur, tgt), cur, tgt), True, True, 0)
        self.temps.pack_start(self._tile("Stół" if pl else "Bed", fmt(tel.bed, tel.bed_target),
                                         tel.bed, tel.bed_target), True, True, 0)
        self.temps.pack_start(self._tile("Komora" if pl else "Chamber", fmt(tel.chamber, None),
                                         tel.chamber, None), True, True, 0)

    def _fill_hardware(self, tel: Telemetry, pl: bool) -> None:
        for child in self.hw.get_children():
            self.hw.remove(child)
        fan = lambda v: "—" if v is None else f"{v}%"
        self.hw.pack_start(self._tile("Went. części" if pl else "Part fan", fan(tel.part_fan), strong=True), True, True, 0)
        self.hw.pack_start(self._tile("Went. aux" if pl else "Aux fan", fan(tel.aux_fan), strong=True), True, True, 0)
        self.hw.pack_start(self._tile("Went. komory" if pl else "Chamber fan", fan(tel.chamber_fan), strong=True), True, True, 0)
        if tel.speed_level or tel.speed_percent is not None:
            name = _SPEED_NAMES.get(tel.speed_level or 0, ("", ""))[0 if pl else 1]
            pct = f"{tel.speed_percent}%" if tel.speed_percent is not None else ""
            self.hw.pack_start(self._tile("Prędkość" if pl else "Speed", (f"{name} {pct}").strip() or "—", strong=True), True, True, 0)
        if tel.nozzle_diameter:
            self.hw.pack_start(self._tile("Dysza mm" if pl else "Nozzle mm", f"{tel.nozzle_diameter:.1f}", strong=True), True, True, 0)

    def _fill_filaments(self, tel: Telemetry, pl: bool) -> None:
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
                if bool(self.app.config.data.get("monochrome", False)):
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


def _rounded(cr: Any, x: float, y: float, w: float, h: float, r: float) -> None:
    import math
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()
