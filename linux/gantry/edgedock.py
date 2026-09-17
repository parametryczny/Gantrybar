from __future__ import annotations

"""Edge dock: a narrow always-on-top strip pinned to a screen edge.

One progress ring per printer. Collapsed the strip is 22 points wide and carries only status colour
and ring fill; hovering expands it into a list with names, percentages and remaining time, and
clicking a row opens that printer's details. Mirrors the macOS EdgeDockWindowController.

Issue #34, as on macOS and Windows: the strip can be pinned open, and pinned or released with the pin
on the strip itself; and any printer can be given a live picture, shown whole with its caption under
it (dockcaptions, contract edgeDock.captions). The two are independent. A picture works on a strip that still folds, it is simply not drawn while folded,
and its stream keeps running so unfolding shows a live image at once instead of a reconnect.

The "grows out of the edge" look comes from the two concave fillets where the strip meets the screen:
the window is taller than the visible body by one fillet radius at each end, and the silhouette is
painted with cairo rather than being a rectangle with a background colour.

Always-on-top is not universally available on Wayland: X11 honours `set_keep_above`, and so do
wlroots compositors, but GNOME's Wayland session has no protocol for it and will let other windows
cover the strip. The rest of the behaviour is identical there.
"""

import math
import time
from typing import Any

import cairo

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, Pango, PangoCairo  # type: ignore

from . import dockcaptions as dc
from . import i18n
from .core import PrinterKind
from .dockplacement import (DISPLAY_CHANGE_DEBOUNCE_MS, INNER_EDGE_DWELL_MS, EdgeDockDisplay, format_frame,
                            is_inner_edge, parse_frame, place, resolve)

RING = 14.0
RING_STROKE = 2.0
COLLAPSED_WIDTH = 22.0
COLLAPSED_GAP = 8.0
PAD_Y = 8.0
NOTCH = 11.0
#: Band above the rows holding the pin, present whenever the strip is open.
PIN_ROW = 14.0
PIN_GAP = 10.0
#: Extra room under the last printer of an open strip, so its note clears the rounded bottom corner.
EXPANDED_BOTTOM_PAD = 8.0
PIN_GLYPH = 10.0
#: A picture that has not sent a frame for this long says "No picture"; before its first frame it says
#: "Connecting…" for this long.
PICTURE_SILENCE_S = 4.0
PICTURE_FIRST_FRAME_S = 12.0
#: Grace period before folding, long enough to outlast the leave event the strip's own resize emits.
COLLAPSE_DELAY_MS = 440

#: The pin, in a 16x16 design box, upright with the needle down: a flat head, a shaft, a flared collar
#: and the needle. The same points on macOS and Windows (contract edgeDock.pinControl).
PIN_POINTS = ((5.0, 1.5), (11.0, 1.5), (11.0, 3.0), (9.8, 3.0), (9.8, 7.0), (12.5, 9.5), (8.7, 9.5),
              (8.0, 15.0), (7.3, 9.5), (3.5, 9.5), (6.2, 7.0), (6.2, 3.0), (5.0, 3.0))
#: Released, the pin leans over; pinned, it stands straight in.
PIN_RELEASED_ANGLE = 45.0

SHAPE = (0.031, 0.035, 0.043, 0.96)
PRINTING = (1.0, 0.407, 0.341)
PAUSED = (0.922, 0.710, 0.361)
ERROR = (1.0, 0.353, 0.306)
TEXT = (0.949, 0.953, 0.945)
SECONDARY = (0.655, 0.667, 0.651)
MUTED = (0.427, 0.443, 0.431)
PICTURE_PLATE = (0.063, 0.086, 0.075)


def _escape(text: str) -> str:
    """Pango markup escaping, because a printer name is user-typed."""
    return GLib.markup_escape_text(text)


def pin_outline(cx: float, cy: float, size: float, angle_degrees: float) -> list[tuple[float, float]]:
    """The pin's points placed at (cx, cy), `size` wide, rotated clockwise on a y-down canvas."""
    scale = size / 16.0
    theta = math.radians(angle_degrees)
    cos, sin = math.cos(theta), math.sin(theta)
    points = []
    for x, y in PIN_POINTS:
        dx, dy = x - 8.0, y - 8.0
        points.append((cx + (dx * cos - dy * sin) * scale, cy + (dx * sin + dy * cos) * scale))
    return points


def connected_displays() -> list[EdgeDockDisplay]:
    """Every monitor GDK reports. The id is the manufacturer and model, which GDK keeps across a re-plug;
    two identical monitors share it and are told apart by their saved frame."""
    display = Gdk.Display.get_default()
    if display is None:
        return []
    result: list[EdgeDockDisplay] = []
    for index in range(display.get_n_monitors()):
        monitor = display.get_monitor(index)
        if monitor is None:
            continue
        geometry, workarea, scale = monitor.get_geometry(), monitor.get_workarea(), monitor.get_scale_factor()
        manufacturer, model = monitor.get_manufacturer() or "", monitor.get_model() or ""
        name = " ".join(part for part in (manufacturer, model) if part) or i18n.t("Display {0}").format(index + 1)
        result.append(EdgeDockDisplay(
            id=f"{manufacturer}|{model}" if manufacturer or model else f"monitor-{index}", name=name,
            pixel_width=geometry.width * scale, pixel_height=geometry.height * scale,
            frame=(geometry.x, geometry.y, geometry.width, geometry.height),
            workarea=(workarea.x, workarea.y, workarea.width, workarea.height),
            is_primary=bool(monitor.is_primary())))
    return result


def choose_display(config: dict[str, Any], ident: str) -> None:
    """Saves a display choice with the frame and name that find it again and name it while it is unplugged.
    An empty id goes back to the main display; an id no longer connected changes nothing."""
    if ident == str(config.get("edge-dock-display", "")):
        return
    if not ident:
        for key in ("edge-dock-display", "edge-dock-display-frame", "edge-dock-display-name"):
            config[key] = ""
        return
    display = next((d for d in connected_displays() if d.id == ident), None)
    if display is None:
        return
    config["edge-dock-display"] = display.id
    config["edge-dock-display-frame"] = format_frame(display.frame)
    config["edge-dock-display-name"] = display.name


class _PangoMeasure:
    """dockcaptions.Measure over Pango, in the strip's logical points."""

    def __init__(self, area: Gtk.Widget) -> None:
        self.layout = area.create_pango_layout("")
        base = area.get_style_context().get_font(Gtk.StateFlags.NORMAL)
        self.name_font = self._font(base, dc.NAME_SIZE, Pango.Weight.SEMIBOLD)
        self.value_font = self._font(base, dc.VALUE_SIZE, Pango.Weight.NORMAL)
        self.status_font = self._font(base, dc.STATUS_SIZE, Pango.Weight.NORMAL)
        self.name_line = float(self.use(self.name_font, "Ag").get_pixel_size()[1])
        self.value_line = float(self.use(self.value_font, "0").get_pixel_size()[1])

    @staticmethod
    def _font(base: Any, size: float, weight: Any) -> Any:
        font = base.copy()
        font.set_absolute_size(size * Pango.SCALE)
        font.set_weight(weight)
        return font

    def use(self, font: Any, text: str, width: float | None = None) -> Any:
        layout = self.layout
        layout.set_font_description(font)
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_width(-1 if width is None else int(width * Pango.SCALE))
        layout.set_text(text, -1)
        return layout

    def name_width(self, text: str) -> float:
        return float(self.use(self.name_font, text).get_pixel_size()[0])

    def value_width(self, text: str) -> float:
        return float(self.use(self.value_font, text).get_pixel_size()[0])

    def name_height(self, text: str, width: float) -> float:
        return float(self.use(self.name_font, text, width).get_pixel_size()[1])


class EdgeDock:
    """Owns the strip window and keeps it in sync with the printer store."""

    def __init__(self, app: Any) -> None:
        self.app = app
        self.entries: list[dict[str, Any]] = []
        self.hovering = False
        self._inside = False
        self._collapse_source: int | None = None
        #: On an edge shared with another monitor the pointer crosses the strip on its way over, so there
        #: the strip unfolds only after the pointer has stayed a moment. An outer edge unfolds at once.
        self._inner_edge = False
        self._dwell_source: int | None = None
        self._display_change_source: int | None = None
        self._pin_hovered = False
        self._pin_hit: tuple[float, float, float, float] | None = None
        self._row_hits: list[tuple[float, float, str]] = []
        # Pictures take no clicks: a click on one is not a click on its printer's tile.
        self._picture_hits: list[tuple[float, float, float, float]] = []
        #: One stream per printer the user ticked, its latest frame, when that frame arrived and when the
        #: stream started. Keyed by serial.
        self.camera_views: dict[str, Any] = {}
        self.camera_frames: dict[str, Any] = {}
        self.camera_frame_times: dict[str, float] = {}
        self.camera_started: dict[str, float] = {}
        self._status_source: int | None = None
        self._picture_statuses: tuple[Any, ...] = ()
        #: Height of the chosen monitor's work area, so the open strip can fit itself to it.
        self._available_height = float("inf")
        self._plan_cache: tuple[Any, dc.Plan] | None = None
        self._measure_cache: _PangoMeasure | None = None

        self.window = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.window.set_app_paintable(True)
        self.window.set_decorated(False)
        self.window.set_skip_taskbar_hint(True)
        self.window.set_skip_pager_hint(True)
        self.window.set_keep_above(True)
        self.window.set_accept_focus(False)
        self.window.set_focus_on_map(False)
        self.window.stick()

        screen = self.window.get_screen()
        visual = screen.get_rgba_visual() if screen is not None else None
        if visual is not None:
            self.window.set_visual(visual)
        if screen is not None:
            screen.connect("monitors-changed", self._on_monitors_changed)

        self.area = Gtk.DrawingArea()
        self.area.add_events(Gdk.EventMask.POINTER_MOTION_MASK
                             | Gdk.EventMask.ENTER_NOTIFY_MASK
                             | Gdk.EventMask.LEAVE_NOTIFY_MASK
                             | Gdk.EventMask.BUTTON_PRESS_MASK)
        self.area.connect("draw", self._on_draw)
        self.area.connect("enter-notify-event", self._on_enter)
        self.area.connect("leave-notify-event", self._on_leave)
        self.area.connect("motion-notify-event", self._on_motion)
        self.area.connect("button-press-event", self._on_click)
        self.window.add(self.area)

    # ---------------------------------------------------------------- state

    @property
    def pinned(self) -> bool:
        return bool(self.app.config.data.get("edge-dock-pinned", False))

    @property
    def expanded(self) -> bool:
        """Pinned means permanently unfolded: hover stops being what decides the width."""
        return self.hovering or self.pinned

    # ---------------------------------------------------------------- data

    def refresh(self) -> None:
        """Rebuilds from the store; hides the window when off or when nothing is left to show."""
        config = self.app.config.data
        if not bool(config.get("edge-dock-enabled", False)):
            self.hide()
            return
        hidden = set(str(config.get("edge-dock-hidden", "")).split("\n")) - {""}
        only_printing = bool(config.get("edge-dock-only-printing", False))
        entries: list[dict[str, Any]] = []
        for printer in self.app.printers:
            if printer.serial in hidden:
                continue
            telemetry = self.app.telemetry.get(printer.serial)
            state = getattr(telemetry, "state", "offline") if telemetry else "offline"
            if only_printing and state not in ("printing", "paused"):
                continue
            entries.append({
                "serial": printer.serial,
                "name": printer.name,
                "state": state,
                "progress": int(getattr(telemetry, "progress", 0) or 0) if telemetry else 0,
                "remaining": getattr(telemetry, "remaining_minutes", None) if telemetry else None,
            })
        if not entries:
            self.entries = entries
            self.hide()
            return
        self.entries = entries
        self._sync_cameras()
        for entry in entries:
            entry["camera"] = self._camera_state(entry["serial"])
        # Printers with a live picture first, the rest under them, each group in fleet order.
        entries = [entry for entry in entries if entry["camera"] == dc.LIVE] + \
                  [entry for entry in entries if entry["camera"] != dc.LIVE]
        self.entries = entries
        # Telemetry arrives several times a second and usually says the same thing the strip already
        # draws. Repositioning and redrawing an identical strip is pure waste, so it is skipped.
        signature = (tuple(tuple(sorted(entry.items())) for entry in entries),
                     self._scale(), str(config.get("edge-dock-edge", "right")),
                     str(config.get("edge-dock-row", "middle")), str(config.get("edge-dock-display", "")), self.expanded,
                     tuple(sorted(self.camera_views)))
        if signature == getattr(self, "_drawn_signature", None) and self.window.get_visible():
            return
        self._drawn_signature = signature
        self._reposition()
        self.window.show_all()
        self.area.queue_draw()

    def hide(self) -> None:
        """Taking the strip off screen must also take the streams down; an invisible camera would keep
        decoding frames and holding the printer's single stream slot."""
        self._detach_cameras()
        self._drawn_signature = None
        self.window.hide()

    def _detach_cameras(self) -> None:
        for view in self.camera_views.values():
            view.frame_sink = None
            view.stop()
        self.camera_views = {}
        self.camera_frames = {}
        self.camera_frame_times = {}
        self.camera_started = {}

    def _camera_state(self, serial: str) -> str:
        from . import edition
        from .camera import supports_camera
        if not edition.HAS_EXTRAS:
            return dc.HIDDEN
        if serial in self.camera_views:
            return dc.LIVE
        kind = next((printer.kind for printer in self.app.printers if printer.serial == serial), None)
        return dc.PREVIEW_OFF if supports_camera(kind) else dc.NO_CAMERA

    def _sync_cameras(self) -> None:
        """Starts and drops streams so the running set matches what the user ticked. Membership is the
        only thing compared, so a telemetry refresh never restarts a live stream, and folding the strip
        does not either. The cost, as on macOS: a ticked printer streams for as long as the strip is on
        screen, which on a Bambu machine occupies its only camera slot."""
        from .camera import CameraView, supports_camera
        config = self.app.config.data
        wanted: set[str] = set()
        if bool(config.get("edge-dock-camera", False)):
            kinds = {printer.serial: printer.kind for printer in self.app.printers}
            candidates = [entry for entry in self.entries if supports_camera(kinds.get(entry["serial"]))]
            chosen = set(str(config.get("edge-dock-camera-serials", "")).split("\n")) - {""}
            picked = {entry["serial"] for entry in candidates if entry["serial"] in chosen}
            # Nothing ticked yet: follow the print that is actually running, so switching the camera on
            # does something instead of nothing. Ticking printers replaces this entirely.
            if picked:
                wanted = picked
            else:
                active = self._active_print(candidates)
                wanted = {active} if active else set()
        if wanted == set(self.camera_views):
            return
        for serial in [serial for serial in self.camera_views if serial not in wanted]:
            view = self.camera_views.pop(serial)
            view.frame_sink = None
            view.stop()
            self.camera_frames.pop(serial, None)
            self.camera_frame_times.pop(serial, None)
            self.camera_started.pop(serial, None)
        kinds = {printer.serial: printer.kind for printer in self.app.printers}
        for serial in wanted - set(self.camera_views):
            access_code = None
            if kinds.get(serial) == PrinterKind.BAMBU:
                try:
                    access_code = self.app.secrets.get(serial)
                except Exception:
                    access_code = None
            view = CameraView(self.app, serial, access_code)
            view.frame_sink = lambda pixbuf, target=serial: self._on_frame(target, pixbuf)
            self.camera_views[serial] = view
            self.camera_started[serial] = time.monotonic()
            view.start()
        if self.camera_views and self._status_source is None:
            self._status_source = GLib.timeout_add(1000, self._picture_status_tick)

    @staticmethod
    def _active_print(candidates: list[dict[str, Any]]) -> str | None:
        """Printing beats paused, and a single candidate is simply that one. Several idle machines give
        nothing, because picking one of them silently would be a guess rather than an answer."""
        for state in ("printing", "paused"):
            for entry in candidates:
                if entry["state"] == state:
                    return entry["serial"]
        return candidates[0]["serial"] if len(candidates) == 1 else None

    def _on_frame(self, serial: str, pixbuf: Any) -> None:
        if serial not in self.camera_views:
            return
        self.camera_frames[serial] = pixbuf
        self.camera_frame_times[serial] = time.monotonic()
        if self.expanded and self.window.get_visible():
            self.area.queue_draw()

    def _picture_status(self, serial: str) -> str | None:
        """None while frames flow; otherwise the few words the plate shows."""
        now = time.monotonic()
        last = self.camera_frame_times.get(serial)
        if last is None:
            started = self.camera_started.get(serial, now)
            return "Connecting…" if now - started < PICTURE_FIRST_FRAME_S else "No picture"
        return "No picture" if now - last > PICTURE_SILENCE_S else None

    def _picture_status_tick(self) -> bool:
        """A camera that goes quiet sends nothing to redraw on, so the strip looks once a second."""
        if not self.camera_views:
            self._status_source = None
            self._picture_statuses = ()
            return False
        statuses = tuple((serial, self._picture_status(serial)) for serial in sorted(self.camera_views))
        if statuses != self._picture_statuses:
            self._picture_statuses = statuses
            if self.expanded and self.window.get_visible():
                self.area.queue_draw()
        return True

    def _value_text(self, entry: dict[str, Any]) -> str:
        state = entry["state"]
        if state in ("printing", "paused"):
            minutes = entry["remaining"]
            if isinstance(minutes, int) and minutes > 0:
                return f"{entry['progress']}% · {minutes // 60}:{minutes % 60:02d}"
            return f"{entry['progress']}%"
        if state == "finished":
            return i18n.t("done")
        if state == "idle":
            return i18n.t("idle")
        if state == "error":
            return i18n.t("error")
        return i18n.t("offline")

    # ------------------------------------------------------------ geometry

    def _measure(self) -> _PangoMeasure:
        if self._measure_cache is None:
            self._measure_cache = _PangoMeasure(self.area)
        return self._measure_cache

    def _captions(self) -> list[dc.Caption]:
        return [dc.Caption(name=entry["name"], value=self._value_text(entry),
                           camera=entry.get("camera", dc.HIDDEN), has_picture=entry["serial"] in self.camera_views)
                for entry in self.entries]

    def _chrome(self) -> float:
        """Everything around the column in an open strip, plus the margin kept free on the display."""
        return NOTCH * 2 + PAD_Y * 2 + EXPANDED_BOTTOM_PAD + PIN_ROW + PIN_GAP + dc.SCREEN_MARGIN * 2

    def _plan(self, width: float) -> dc.Plan:
        captions = self._captions()
        limit = self._available_height / self._scale() - self._chrome()
        key = (tuple(captions), width, limit, self.app.language)
        if self._plan_cache is not None and self._plan_cache[0] == key:
            return self._plan_cache[1]
        result = dc.fitted_plan(captions, width, self._measure(), limit)
        self._plan_cache = (key, result)
        return result

    def _size(self) -> tuple[float, float]:
        scale = self._scale()
        count = max(len(self.entries), 1)
        if self.expanded:
            width = self._expanded_width()
            rows = self._plan(width).height if self.entries else dc.CAPTION_MIN_HEIGHT
            body = PAD_Y * 2 + EXPANDED_BOTTOM_PAD + PIN_ROW + PIN_GAP + rows
            return width * scale, (body + NOTCH * 2) * scale
        body = PAD_Y * 2 + count * RING + (count - 1) * COLLAPSED_GAP
        return COLLAPSED_WIDTH * scale, (body + NOTCH * 2) * scale

    def _scale(self) -> float:
        value = round(int(self.app.config.data.get("edge-dock-scale-percent", 100)) / 5) * 5
        return max(1.0, min(1.5, value / 100))

    def _expanded_width(self) -> float:
        # Measuring every caption through Pango is the most expensive thing the strip does, and _size()
        # is asked for it on every draw and every reposition. The answer only changes when the rows,
        # the language or the pictures do, so it is kept until then.
        captions = self._captions()
        key = (tuple(captions), self.app.language)
        cached = getattr(self, "_expanded_width_cache", None)
        if cached is not None and cached[0] == key:
            return cached[1]
        width = dc.strip_width(captions, self._measure())
        self._expanded_width_cache = (key, width)
        return width

    def _reposition(self) -> None:
        # The chosen monitor, flush with its side, at the chosen height. It used to be the primary monitor,
        # centred, with no way to put the strip anywhere else.
        config = self.app.config.data
        displays = connected_displays()
        resolved = resolve(displays, str(config.get("edge-dock-display", "")),
                           parse_frame(str(config.get("edge-dock-display-frame", ""))))
        if resolved is not None:
            self._available_height = float(resolved[0].workarea[3])
        width, height = self._size()
        self.window.resize(int(width), int(height))
        self.area.set_size_request(int(width), int(height))
        if resolved is None:
            return
        chosen, matched = resolved
        self._remember_display(chosen, matched)
        left = str(config.get("edge-dock-edge", "right")) == "left"
        self._inner_edge = is_inner_edge(chosen, left, displays)
        x, y = place(chosen.frame, chosen.workarea, left, str(config.get("edge-dock-row", "middle")), width, height)
        self.window.move(int(round(x)), int(round(y)))

    def _remember_display(self, display: EdgeDockDisplay, matched: bool) -> None:
        """A chosen monitor found under a new id, or at a new size, is saved as it is now. The fallback to the
        main monitor writes nothing: the choice stays for when the monitor returns."""
        config = self.app.config.data
        if not matched or not str(config.get("edge-dock-display", "")):
            return
        frame = format_frame(display.frame)
        if config.get("edge-dock-display") == display.id and config.get("edge-dock-display-frame") == frame:
            return
        config["edge-dock-display"] = display.id
        config["edge-dock-display-frame"] = frame
        self.app.config.save()

    def _on_monitors_changed(self, *_args: object) -> None:
        """A plug or a TV waking up posts a burst of these while the monitor list is still settling."""
        if self._display_change_source is not None:
            GLib.source_remove(self._display_change_source)
        self._display_change_source = GLib.timeout_add(DISPLAY_CHANGE_DEBOUNCE_MS, self._displays_settled)

    def _displays_settled(self) -> bool:
        self._display_change_source = None
        self._drawn_signature = None
        self.refresh()
        tray = getattr(self.app, "_tray", None)
        if callable(tray):
            tray()   # the tray's monitor list
        return False

    # ------------------------------------------------------------- drawing

    def _on_draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        width, height = self._size()
        scale = self._scale()
        logical_width, logical_height = width / scale, height / scale
        left = str(self.app.config.data.get("edge-dock-edge", "right")) == "left"
        cr.set_operator(cairo.OPERATOR_SOURCE)   # clear the window to fully transparent first
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)

        cr.save()
        cr.scale(scale, scale)
        if left:
            # The silhouette is drawn flush against the right edge; the left edge is its mirror image.
            cr.translate(logical_width, 0)
            cr.scale(-1, 1)
        self._silhouette(cr, logical_width, logical_height)
        cr.set_source_rgba(*SHAPE)
        cr.fill()
        cr.restore()

        cr.save(); cr.scale(scale, scale)
        self._row_hits = []
        self._picture_hits = []
        self._pin_hit = None
        if self.expanded:
            self._draw_expanded(cr, logical_width, left)
        else:
            self._draw_collapsed(cr, logical_width)
        cr.restore()
        return False

    @staticmethod
    def _silhouette(cr: Any, w: float, h: float) -> None:
        """Rounded body flush against the edge, plus a concave fillet at each end."""
        r = min(NOTCH, w)
        body = min(w / 2, 12.0)
        top, bottom = r, h - r
        cr.new_path()
        cr.move_to(w, 0)
        cr.arc(w - r, 0, r, 0, math.pi / 2)                       # concave, top
        cr.line_to(body, top)
        # Counter-clockwise: a clockwise arc between the same angles sweeps three quarters of a turn and
        # bites a disc out of the corner instead of rounding it.
        cr.arc_negative(body, top + body, body, -math.pi / 2, -math.pi)     # convex, top-left
        cr.line_to(0, bottom - body)
        cr.arc_negative(body, bottom - body, body, math.pi, math.pi / 2)    # convex, bottom-left
        cr.line_to(w - r, bottom)
        cr.arc(w - r, h, r, -math.pi / 2, 0)                      # concave, bottom
        cr.close_path()

    @staticmethod
    def _rounded(cr: Any, x: float, y: float, w: float, h: float, r: float) -> None:
        r = min(r, w / 2, h / 2)
        cr.new_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def _draw_collapsed(self, cr: Any, width: float) -> None:
        step = RING + COLLAPSED_GAP
        y = NOTCH + PAD_Y + RING / 2
        for entry in self.entries:
            self._ring(cr, width / 2, y, entry)
            self._row_hits.append((y - step / 2, y + step / 2, entry["serial"]))
            y += step

    def _draw_expanded(self, cr: Any, width: float, left: bool) -> None:
        # The ring stays beside the physical screen edge while the text unfolds inward, as on macOS and
        # Windows, at the end of each caption.
        ring_x = dc.INSET_X + RING / 2 if left else width - dc.INSET_X - RING / 2
        top = NOTCH + PAD_Y
        # The pin sits in the ring column above the first printer, so it can never collide with a name.
        self._draw_pin(cr, ring_x, top + PIN_ROW / 2)
        content_top = top + PIN_ROW + PIN_GAP
        plan = self._plan(width)
        bottom_limit = content_top + plan.height
        measure = self._measure()
        gap = dc.PRINTER_GAP
        for index, (entry, row) in enumerate(zip(self.entries, plan.rows)):
            caption_top = content_top + row.caption_top
            # A strip cut at the display's height draws only what is inside it.
            if caption_top + row.caption_height > bottom_limit + 1:
                break
            block_top = content_top + row.block_top
            if row.picture_height > 0:
                picture_left = (width - row.picture_width) / 2
                self._picture(cr, picture_left, block_top, row.picture_width, row.picture_height, entry["serial"], measure)
                self._picture_hits.append((picture_left, block_top, row.picture_width, row.picture_height))
            self._caption(cr, entry, row, caption_top, width, left, ring_x, measure)
            if row.note:
                self._note(cr, entry, row, caption_top + row.caption_height, width, left, measure)
            # The caption, its note and the room around its hairline open the printer; its picture does
            # not, because _on_click checks the pictures first.
            hit_top = block_top - (gap if index else 0.0)
            self._row_hits.append((hit_top, block_top + row.block_height + gap + 1, entry["serial"]))
            if index < len(plan.rows) - 1:
                cr.set_source_rgba(1, 1, 1, dc.SEPARATOR_ALPHA)
                cr.rectangle(dc.INSET_X, round(block_top + row.block_height + gap), max(0.0, width - dc.INSET_X * 2), 1)
                cr.fill()

    def _caption(self, cr: Any, entry: dict[str, Any], row: dc.Row, top: float, width: float, left: bool,
                 ring_x: float, measure: _PangoMeasure) -> None:
        """Name on the leading side, then the percentage and time, then the ring. A name that does not fit
        beside its metrics wraps, and the metrics move to the line under it."""
        center_y = top + row.caption_height / 2
        self._ring(cr, ring_x, center_y, entry)
        dim = entry["state"] in ("idle", "offline", "finished")
        colour = ERROR if entry["state"] in ("error", "offline") else (SECONDARY if dim else TEXT)
        text_left = dc.INSET_X + (dc.RING_SPAN if left else 0.0)
        text_right = width - dc.INSET_X - (0.0 if left else dc.RING_SPAN)
        value = self._value_text(entry)
        if row.wraps:
            block = row.name_height + dc.WRAPPED_LINE_GAP + measure.value_line
            y = center_y - block / 2
            layout = measure.use(measure.name_font, entry["name"], text_right - text_left)
            cr.set_source_rgb(*colour)
            cr.move_to(text_left, y)
            PangoCairo.show_layout(cr, layout)
            layout = measure.use(measure.value_font, value)
            cr.set_source_rgb(*SECONDARY)
            cr.move_to(text_left, y + row.name_height + dc.WRAPPED_LINE_GAP)
            PangoCairo.show_layout(cr, layout)
            return
        layout = measure.use(measure.value_font, value)
        value_w, value_h = layout.get_pixel_size()
        cr.set_source_rgb(*SECONDARY)
        cr.move_to(text_right - value_w, center_y - value_h / 2)
        PangoCairo.show_layout(cr, layout)
        layout = measure.use(measure.name_font, entry["name"])
        name_h = layout.get_pixel_size()[1]
        cr.set_source_rgb(*colour)
        cr.move_to(text_left, center_y - name_h / 2)
        PangoCairo.show_layout(cr, layout)

    def _note(self, cr: Any, entry: dict[str, Any], row: dc.Row, top: float, width: float, left: bool,
              measure: _PangoMeasure) -> None:
        """The line under a caption without a picture: a camera glyph, struck through when the printer has
        none, and a few words."""
        x = dc.INSET_X + (dc.RING_SPAN if left else 0.0)
        center_y = top + dc.STATUS_ROW / 2 - 1
        unit = dc.STATUS_ICON / 12
        oy = center_y - dc.STATUS_ICON / 2
        cr.set_source_rgb(*SECONDARY)
        cr.set_line_width(1.1 * unit)
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        bx, by, bw, bh = dc.CAMERA_GLYPH_BODY
        self._rounded(cr, x + bx * unit, oy + by * unit, bw * unit, bh * unit, 1.5 * unit)
        cr.stroke()
        cr.new_path()
        lens = dc.CAMERA_GLYPH_LENS
        cr.move_to(x + lens[0][0] * unit, oy + lens[0][1] * unit)
        for px, py in lens[1:]:
            cr.line_to(x + px * unit, oy + py * unit)
        cr.close_path()
        cr.stroke()
        if row.note == dc.NOTES[dc.NO_CAMERA]:
            (sx, sy), (ex, ey) = dc.CAMERA_GLYPH_STRIKE
            cr.move_to(x + sx * unit, oy + sy * unit)
            cr.line_to(x + ex * unit, oy + ey * unit)
            cr.stroke()
        cr.set_line_cap(cairo.LINE_CAP_BUTT)
        layout = measure.use(measure.status_font, i18n.t(row.note or ""))
        text_h = layout.get_pixel_size()[1]
        cr.move_to(x + dc.STATUS_ICON + dc.CAPTION_INNER_GAP, center_y - text_h / 2)
        PangoCairo.show_layout(cr, layout)
        cr.new_path()

    def _picture(self, cr: Any, x: float, y: float, w: float, h: float, serial: str, measure: _PangoMeasure) -> None:
        """One live frame, shown whole in a 16:9 rounded rectangle: never cropped or stretched. A dark plate
        until the first frame, and a dimmed plate saying "No picture" when frames stop arriving."""
        cr.save()
        self._rounded(cr, x, y, w, h, dc.PICTURE_RADIUS)
        cr.clip()
        cr.set_source_rgb(*PICTURE_PLATE)
        cr.paint()
        pixbuf = self.camera_frames.get(serial)
        if pixbuf is not None:
            pw, ph = pixbuf.get_width(), pixbuf.get_height()
            if pw > 0 and ph > 0:
                factor = min(w / pw, h / ph)
                cr.save()
                cr.translate(x + (w - pw * factor) / 2, y + (h - ph * factor) / 2)
                cr.scale(factor, factor)
                Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
                cr.paint()
                cr.restore()
        status = self._picture_status(serial)
        if status is not None:
            if pixbuf is not None:
                cr.set_source_rgba(0, 0, 0, 0.62)
                cr.paint()
            layout = measure.use(measure.status_font, i18n.t(status))
            text_w, text_h = layout.get_pixel_size()
            cr.set_source_rgb(0.89, 0.91, 0.89)
            cr.move_to(x + (w - text_w) / 2, y + (h - text_h) / 2)
            PangoCairo.show_layout(cr, layout)
        cr.new_path()
        cr.restore()

    def _draw_pin(self, cr: Any, cx: float, cy: float) -> None:
        """Pin and release, on the strip itself. Released: a faint disc and a hollow pin leaning over.
        Pinned: a brighter disc and a solid pin standing straight in. Hover lifts the disc either way."""
        pinned = self.pinned
        disc_alpha = (0.18 if pinned else 0.06) + (0.08 if self._pin_hovered else 0.0)
        cr.set_source_rgba(1, 1, 1, disc_alpha)
        cr.arc(cx, cy, PIN_ROW / 2, 0, 2 * math.pi)
        cr.fill()
        points = pin_outline(cx, cy, PIN_GLYPH, 0.0 if pinned else PIN_RELEASED_ANGLE)
        cr.new_path()
        cr.move_to(*points[0])
        for point in points[1:]:
            cr.line_to(*point)
        cr.close_path()
        if pinned:
            cr.set_source_rgb(*TEXT)
            cr.fill()
        else:
            cr.set_source_rgb(*SECONDARY)
            cr.set_line_width(1.3 * PIN_GLYPH / 16)
            cr.set_line_join(cairo.LINE_JOIN_ROUND)
            cr.stroke()
        slack = 3.0
        self._pin_hit = (cx - PIN_ROW / 2 - slack, cy - PIN_ROW / 2 - slack,
                         PIN_ROW + 2 * slack, PIN_ROW + 2 * slack)

    def _ring(self, cr: Any, cx: float, cy: float, entry: dict[str, Any]) -> None:
        """A dim track plus an arc from twelve o'clock; error and offline draw a dot instead, so a
        dead printer never looks like a stalled one."""
        radius = (RING - RING_STROKE) / 2
        cr.new_path()   # text leaves a current point behind, and an arc would draw a line from it
        cr.set_line_width(RING_STROKE)
        state = entry["state"]
        if state in ("error", "offline"):
            cr.set_source_rgba(*ERROR, 0.3)
            cr.arc(cx, cy, radius, 0, 2 * math.pi)
            cr.stroke()
            cr.set_source_rgb(*ERROR)
            cr.arc(cx, cy, 2, 0, 2 * math.pi)
            cr.fill()
            return

        cr.set_source_rgba(1, 1, 1, 0.16)
        cr.arc(cx, cy, radius, 0, 2 * math.pi)
        cr.stroke()
        if state not in ("printing", "paused"):
            return
        fraction = min(max(entry["progress"] / 100.0, 0.0), 1.0)
        if fraction <= 0:
            return
        cr.set_source_rgb(*(PAUSED if state == "paused" else PRINTING))
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.arc(cx, cy, radius, -math.pi / 2, -math.pi / 2 + 2 * math.pi * fraction)
        cr.stroke()
        cr.set_line_cap(cairo.LINE_CAP_BUTT)

    # --------------------------------------------------------- interaction

    def _relayout(self) -> None:
        self._drawn_signature = None
        self._reposition()
        self.area.queue_draw()

    def _on_enter(self, *_args: object) -> bool:
        self._inside = True
        if self._collapse_source is not None:
            GLib.source_remove(self._collapse_source)
            self._collapse_source = None
        if not self.hovering:
            if self._inner_edge and not self.pinned:
                if self._dwell_source is not None:
                    GLib.source_remove(self._dwell_source)
                self._dwell_source = GLib.timeout_add(INNER_EDGE_DWELL_MS, self._unfold_if_still_inside)
                return False
            self._begin_hover()
        return False

    def _unfold_if_still_inside(self) -> bool:
        """Still over the strip after the dwell: a stop, not a pass on the way to the next monitor."""
        self._dwell_source = None
        if self._inside and not self.hovering:
            self._begin_hover()
        return False

    def _begin_hover(self) -> None:
        self.hovering = True
        if not self.pinned:   # a pinned strip is already open
            self._relayout()

    def _on_leave(self, *_args: object) -> bool:
        """Folding waits a moment. The strip resizes under the pointer as it opens, and a window that
        moves out from under the cursor emits a leave event although the user has not moved; folding at
        once would put the edge back under the cursor and open it again."""
        self._inside = False
        if self._dwell_source is not None:
            GLib.source_remove(self._dwell_source)
            self._dwell_source = None
        if self._pin_hovered:
            self._pin_hovered = False
            self.area.queue_draw()
        if self._collapse_source is not None:
            GLib.source_remove(self._collapse_source)
        self._collapse_source = GLib.timeout_add(COLLAPSE_DELAY_MS, self._collapse_if_left)
        return False

    def _collapse_if_left(self) -> bool:
        self._collapse_source = None
        if self._inside or not self.hovering:
            return False
        self.hovering = False
        if not self.pinned:
            self._relayout()
        return False

    def _logical(self, event: Any) -> tuple[float, float]:
        scale = self._scale()
        return event.x / scale, event.y / scale

    def _over_pin(self, x: float, y: float) -> bool:
        if self._pin_hit is None:
            return False
        left, top, width, height = self._pin_hit
        return left <= x <= left + width and top <= y <= top + height

    def _on_motion(self, _widget: Gtk.Widget, event: Any) -> bool:
        over = self._over_pin(*self._logical(event))
        if over != self._pin_hovered:
            self._pin_hovered = over
            self.area.queue_draw()
        return False

    def _on_click(self, _widget: Gtk.Widget, event: Any) -> bool:
        x, y = self._logical(event)
        # The pin wins over the row beneath it.
        if self._over_pin(x, y):
            self.toggle_pinned()
            return True
        if any(left <= x < left + w and top <= y < top + h for left, top, w, h in self._picture_hits):
            return True
        for top, bottom, serial in self._row_hits:
            if top <= y < bottom:
                opener = getattr(self.app, "open_details", None)
                if callable(opener):
                    opener(serial)
                return True
        return True

    def toggle_pinned(self) -> None:
        pinned = not self.pinned
        self.app.config.data["edge-dock-pinned"] = pinned
        save = getattr(self.app.config, "save", None)
        if callable(save):
            save()
        # An open settings dialog would otherwise save its stale check box straight back over this.
        dialog = getattr(self.app, "settings_dialog", None)
        check = getattr(dialog, "dock_pinned", None)
        if check is not None:
            check.set_active(pinned)
        self._relayout()
