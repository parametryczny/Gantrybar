from __future__ import annotations

"""Edge dock: a narrow always-on-top strip pinned to a screen edge.

One progress ring per printer. Collapsed the strip is 22 points wide and carries only status colour
and ring fill; hovering expands it into a list with names, percentages and remaining time, and
clicking a row opens that printer's details. Mirrors the macOS EdgeDockWindowController.

Issue #34, as on macOS and Windows: the strip can be pinned open, and pinned or released with the pin
on the strip itself; and any printer can be given a live picture hung directly under its own row. The
two are independent. A picture works on a strip that still folds, it is simply not drawn while folded,
and its stream keeps running so unfolding shows a live image at once instead of a reconnect.

The "grows out of the edge" look comes from the two concave fillets where the strip meets the screen:
the window is taller than the visible body by one fillet radius at each end, and the silhouette is
painted with cairo rather than being a rectangle with a background colour.

Always-on-top is not universally available on Wayland: X11 honours `set_keep_above`, and so do
wlroots compositors, but GNOME's Wayland session has no protocol for it and will let other windows
cover the strip. The rest of the behaviour is identical there.
"""

import math
from typing import Any

import cairo

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, PangoCairo  # type: ignore

from . import i18n
from .core import PrinterKind

RING = 14.0
RING_STROKE = 2.0
COLLAPSED_WIDTH = 22.0
COLLAPSED_GAP = 8.0
ROW_HEIGHT = 20.0
ROW_GAP = 2.0
PAD_Y = 8.0
NOTCH = 11.0
EXPANDED_PAD_X = 11.0
EXPANDED_TEXT_GAP = 8.0
#: Band above the rows holding the pin, present whenever the strip is open.
PIN_ROW = 14.0
PIN_GAP = 4.0
PIN_GLYPH = 10.0
CAMERA_GAP = 8.0
CAMERA_RADIUS = 8.0
#: A 16:9 picture this narrow is already a squint; below this the strip is not worth the pixels.
CAMERA_MIN_STRIP_WIDTH = 236.0
CAMERA_MAX_STRIP_WIDTH = 300.0
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
PICTURE_PLATE = (0.082, 0.090, 0.102)


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


class EdgeDock:
    """Owns the strip window and keeps it in sync with the printer store."""

    def __init__(self, app: Any) -> None:
        self.app = app
        self.entries: list[dict[str, Any]] = []
        self.hovering = False
        self._inside = False
        self._collapse_source: int | None = None
        self._pin_hovered = False
        self._pin_hit: tuple[float, float, float, float] | None = None
        self._row_hits: list[tuple[float, float, str]] = []
        #: One stream per printer the user ticked, and its latest frame. Keyed by serial.
        self.camera_views: dict[str, Any] = {}
        self.camera_frames: dict[str, Any] = {}

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
        # Telemetry arrives several times a second and usually says the same thing the strip already
        # draws. Repositioning and redrawing an identical strip is pure waste, so it is skipped.
        signature = (tuple(tuple(sorted(entry.items())) for entry in entries),
                     self._scale(), str(config.get("edge-dock-edge", "right")), self.expanded,
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
            view.start()

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
        if self.expanded and self.window.get_visible():
            self.area.queue_draw()

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

    def _has_picture(self, entry: dict[str, Any]) -> bool:
        return entry["serial"] in self.camera_views

    @staticmethod
    def _camera_width(strip_width: float) -> float:
        return max(0.0, strip_width - EXPANDED_PAD_X * 2)

    def _rows_height(self, strip_width: float) -> float:
        """Height of the open strip's rows, pictures included. The same arithmetic the drawing walks."""
        if not self.entries:
            return ROW_HEIGHT
        picture = round(self._camera_width(strip_width) * 9 / 16)
        height = 0.0
        for index, entry in enumerate(self.entries):
            height += ROW_HEIGHT
            if self._has_picture(entry) and picture > 0:
                height += CAMERA_GAP + picture
            if index < len(self.entries) - 1:
                height += ROW_GAP
        return height

    def _size(self) -> tuple[float, float]:
        scale = self._scale()
        count = max(len(self.entries), 1)
        if self.expanded:
            width = self._expanded_width()
            body = PAD_Y * 2 + PIN_ROW + PIN_GAP + self._rows_height(width)
            return width * scale, (body + NOTCH * 2) * scale
        body = PAD_Y * 2 + count * RING + (count - 1) * COLLAPSED_GAP
        return COLLAPSED_WIDTH * scale, (body + NOTCH * 2) * scale

    def _scale(self) -> float:
        value = round(int(self.app.config.data.get("edge-dock-scale-percent", 100)) / 5) * 5
        return max(1.0, min(1.5, value / 100))

    def _expanded_width(self) -> float:
        # Measuring every row through Pango is the most expensive thing the strip does, and _size()
        # is asked for it on every draw and every reposition. The answer only changes when the rows,
        # the language or the pictures do, so it is kept until then.
        pictures = any(self._has_picture(entry) for entry in self.entries)
        key = (tuple((entry["name"], self._value_text(entry)) for entry in self.entries),
               self.app.language, pictures)
        cached = getattr(self, "_expanded_width_cache", None)
        if cached is not None and cached[0] == key:
            return cached[1]
        layout = self.area.create_pango_layout("")
        widest = 0.0
        for entry in self.entries:
            layout.set_markup(f"<b>{_escape(entry['name'])}</b>")
            name = layout.get_pixel_size()[0]
            layout.set_text(self._value_text(entry), -1)
            widest = max(widest, name + layout.get_pixel_size()[0])
        content = EXPANDED_PAD_X * 2 + RING + EXPANDED_TEXT_GAP + widest + 14
        # With a picture the strip stops being sized by its longest printer name: the image needs a
        # usable width of its own, so it raises the floor and lifts the ceiling.
        minimum = CAMERA_MIN_STRIP_WIDTH if pictures else 150.0
        maximum = CAMERA_MAX_STRIP_WIDTH if pictures else 260.0
        width = min(max(content, minimum), maximum)
        self._expanded_width_cache = (key, width)
        return width

    def _reposition(self) -> None:
        width, height = self._size()
        self.window.resize(int(width), int(height))
        self.area.set_size_request(int(width), int(height))
        display = Gdk.Display.get_default()
        if display is None:
            return
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return
        geometry = monitor.get_geometry()
        left = str(self.app.config.data.get("edge-dock-edge", "right")) == "left"
        x = geometry.x if left else geometry.x + geometry.width - int(width)
        y = geometry.y + max(0, (geometry.height - int(height)) // 2)
        self.window.move(x, y)

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
        cr.arc(body, top + body, body, -math.pi / 2, math.pi)     # convex, top-left
        cr.line_to(0, bottom - body)
        cr.arc(body, bottom - body, body, math.pi, math.pi / 2)   # convex, bottom-left
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
        # Windows. It used to sit on the inner side of a right-edge strip and run the text off it on a
        # left-edge one.
        ring_x = EXPANDED_PAD_X + RING / 2 if left else width - EXPANDED_PAD_X - RING / 2
        top = NOTCH + PAD_Y
        # The pin sits in the ring column above the first row, so it can never collide with a name.
        self._draw_pin(cr, ring_x, top + PIN_ROW / 2)
        top += PIN_ROW + PIN_GAP

        picture_width = self._camera_width(width)
        picture_height = round(picture_width * 9 / 16)
        layout = self.area.create_pango_layout("")
        for entry in self.entries:
            row_top = top
            center_y = top + ROW_HEIGHT / 2
            self._ring(cr, ring_x, center_y, entry)

            dim = entry["state"] in ("idle", "offline", "finished")
            colour = ERROR if entry["state"] in ("error", "offline") else (SECONDARY if dim else TEXT)
            text_left = ring_x + RING / 2 + EXPANDED_TEXT_GAP if left else EXPANDED_PAD_X
            text_right = width - EXPANDED_PAD_X if left else ring_x - RING / 2 - EXPANDED_TEXT_GAP

            layout.set_text(self._value_text(entry), -1)
            value_w, value_h = layout.get_pixel_size()
            cr.set_source_rgb(*MUTED)
            cr.move_to(text_right - value_w, center_y - value_h / 2)
            PangoCairo.show_layout(cr, layout)

            layout.set_markup(f"<b>{_escape(entry['name'])}</b>")
            name_w, name_h = layout.get_pixel_size()
            available = max(0.0, text_right - value_w - 8 - text_left)
            cr.save()
            cr.rectangle(text_left, center_y - name_h / 2, available, name_h)
            cr.clip()
            cr.set_source_rgb(*colour)
            cr.move_to(text_left, center_y - name_h / 2)
            PangoCairo.show_layout(cr, layout)
            cr.restore()
            top += ROW_HEIGHT

            # The picture hangs directly under its own row, so which machine it shows needs no caption.
            if self._has_picture(entry) and picture_width > 0:
                top += CAMERA_GAP
                self._picture(cr, (width - picture_width) / 2, top, picture_width, picture_height,
                              self.camera_frames.get(entry["serial"]))
                top += picture_height

            # A click on the row, or in the gap below it, opens that printer; a click on its picture
            # does not, because the picture is not part of the hit area.
            self._row_hits.append((row_top, row_top + ROW_HEIGHT + ROW_GAP, entry["serial"]))
            top += ROW_GAP

    def _picture(self, cr: Any, x: float, y: float, w: float, h: float, pixbuf: Any) -> None:
        """One live frame, cropped to fill a 16:9 rounded rectangle. A dark plate until the first frame
        arrives, so the space reads as a picture loading rather than as a hole in the strip."""
        cr.save()
        self._rounded(cr, x, y, w, h, CAMERA_RADIUS)
        cr.clip()
        cr.set_source_rgb(*PICTURE_PLATE)
        cr.paint()
        if pixbuf is not None:
            pw, ph = pixbuf.get_width(), pixbuf.get_height()
            if pw > 0 and ph > 0:
                factor = max(w / pw, h / ph)
                cr.translate(x + (w - pw * factor) / 2, y + (h - ph * factor) / 2)
                cr.scale(factor, factor)
                Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
                cr.paint()
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
            self.hovering = True
            if not self.pinned:   # a pinned strip is already open
                self._relayout()
        return False

    def _on_leave(self, *_args: object) -> bool:
        """Folding waits a moment. The strip resizes under the pointer as it opens, and a window that
        moves out from under the cursor emits a leave event although the user has not moved; folding at
        once would put the edge back under the cursor and open it again."""
        self._inside = False
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
