from __future__ import annotations

"""Edge dock: a narrow always-on-top strip pinned to a screen edge.

One progress ring per printer. Collapsed the strip is 22 points wide and carries only status colour
and ring fill; hovering expands it into a list with names, percentages and remaining time, and
clicking a row opens that printer's details. Mirrors the macOS EdgeDockWindowController.

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

from gi.repository import Gdk, GLib, Gtk, PangoCairo  # type: ignore

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

SHAPE = (0.031, 0.035, 0.043, 0.96)
PRINTING = (1.0, 0.407, 0.341)
PAUSED = (0.922, 0.710, 0.361)
ERROR = (1.0, 0.353, 0.306)
TEXT = (0.949, 0.953, 0.945)
SECONDARY = (0.655, 0.667, 0.651)
MUTED = (0.427, 0.443, 0.431)


def _escape(text: str) -> str:
    """Pango markup escaping, because a printer name is user-typed."""
    return GLib.markup_escape_text(text)


class EdgeDock:
    """Owns the strip window and keeps it in sync with the printer store."""

    def __init__(self, app: Any) -> None:
        self.app = app
        self.entries: list[dict[str, Any]] = []
        self.expanded = False

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
        self.area.connect("button-press-event", self._on_click)
        self.window.add(self.area)

    # ---------------------------------------------------------------- data

    def refresh(self) -> None:
        """Rebuilds from the store; hides the window when off or when nothing is left to show."""
        config = self.app.config.data
        if not bool(config.get("edge-dock-enabled", False)):
            self.window.hide()
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
        self.entries = entries
        if not entries:
            self.window.hide()
            return
        self._reposition()
        self.window.show_all()
        self.area.queue_draw()

    def _value_text(self, entry: dict[str, Any]) -> str:
        pl = self.app.language == "pl"
        state = entry["state"]
        if state in ("printing", "paused"):
            minutes = entry["remaining"]
            if isinstance(minutes, int) and minutes > 0:
                return f"{entry['progress']}% · {minutes // 60}:{minutes % 60:02d}"
            return f"{entry['progress']}%"
        if state == "finished":
            return "gotowe" if pl else "done"
        if state == "idle":
            return "bezcz." if pl else "idle"
        if state == "error":
            return "błąd" if pl else "error"
        return "brak" if pl else "offline"

    # ------------------------------------------------------------ geometry

    def _size(self) -> tuple[float, float]:
        count = max(len(self.entries), 1)
        if self.expanded:
            body = PAD_Y * 2 + count * ROW_HEIGHT + (count - 1) * ROW_GAP
            return self._expanded_width(), body + NOTCH * 2
        body = PAD_Y * 2 + count * RING + (count - 1) * COLLAPSED_GAP
        return COLLAPSED_WIDTH, body + NOTCH * 2

    def _expanded_width(self) -> float:
        layout = self.area.create_pango_layout("")
        widest = 0.0
        for entry in self.entries:
            layout.set_markup(f"<b>{_escape(entry['name'])}</b>")
            name = layout.get_pixel_size()[0]
            layout.set_text(self._value_text(entry), -1)
            widest = max(widest, name + layout.get_pixel_size()[0])
        content = EXPANDED_PAD_X * 2 + RING + EXPANDED_TEXT_GAP + widest + 14
        return min(max(content, 150.0), 260.0)

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
        y = geometry.y + (geometry.height - int(height)) // 2
        self.window.move(x, y)

    # ------------------------------------------------------------- drawing

    def _on_draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        width, height = self._size()
        left = str(self.app.config.data.get("edge-dock-edge", "right")) == "left"
        cr.set_operator(cairo.OPERATOR_SOURCE)   # clear the window to fully transparent first
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)

        cr.save()
        if left:
            cr.translate(width, 0)
            cr.scale(-1, 1)
        self._silhouette(cr, width, height)
        cr.set_source_rgba(*SHAPE)
        cr.fill()
        cr.restore()

        if self.expanded:
            self._draw_expanded(cr, width, left)
        else:
            self._draw_collapsed(cr, width)
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

    def _draw_collapsed(self, cr: Any, width: float) -> None:
        y = NOTCH + PAD_Y + RING / 2
        for entry in self.entries:
            self._ring(cr, width / 2, y, entry)
            y += RING + COLLAPSED_GAP

    def _draw_expanded(self, cr: Any, width: float, left: bool) -> None:
        top = NOTCH + PAD_Y
        ring_x = width - EXPANDED_PAD_X - RING / 2 if left else EXPANDED_PAD_X + RING / 2
        layout = self.area.create_pango_layout("")
        for entry in self.entries:
            center_y = top + ROW_HEIGHT / 2
            self._ring(cr, ring_x, center_y, entry)

            dim = entry["state"] in ("idle", "offline", "finished")
            colour = ERROR if entry["state"] in ("error", "offline") else (SECONDARY if dim else TEXT)
            text_left = ring_x + RING / 2 + EXPANDED_TEXT_GAP
            text_right = width - EXPANDED_PAD_X

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

            top += ROW_HEIGHT + ROW_GAP

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

    def _on_enter(self, *_args: object) -> bool:
        if not self.expanded:
            self.expanded = True
            self._reposition()
            self.area.queue_draw()
        return False

    def _on_leave(self, *_args: object) -> bool:
        if self.expanded:
            self.expanded = False
            self._reposition()
            self.area.queue_draw()
        return False

    def _on_click(self, _widget: Gtk.Widget, event: Any) -> bool:
        step = ROW_HEIGHT + ROW_GAP if self.expanded else RING + COLLAPSED_GAP
        offset = event.y - (NOTCH + PAD_Y)
        if offset < 0:
            return False
        index = int(offset // step)
        if 0 <= index < len(self.entries):
            opener = getattr(self.app, "open_details", None)
            if callable(opener):
                opener(self.entries[index]["serial"])
        return True
