from __future__ import annotations

"""The emergency power-off question as a panic panel. Mirrors the macOS EmergencyPanel:

* a dark card with a red glow bleeding in from the top and a thin warning-stripe band,
* the siren from design/emergency-siren.svg with a glossy dome, blinking rays and a pulsing halo,
* the printers it will hit as chips,
* one big red button (Enter) and a quiet way out (Esc).

gi is already pinned in app.py.
"""

import math
import time
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from . import i18n

RED = (0.898, 0.282, 0.302)
RED_DEEP = (0.62, 0.12, 0.14)
RAY = (1.0, 0.33, 0.29)
CARD = (0.086, 0.078, 0.082)
_RAYS = (((10, 50), (24, 56)), ((24, 18), (35, 31)), ((64, 4), (64, 19)), ((104, 18), (93, 31)), ((118, 50), (104, 56)))
RADIUS = 24

_CSS = b"""
.ge-title { color: #ffffff; font-size: 21px; font-weight: 800; letter-spacing: -0.2px; }
.ge-detail { color: rgba(255,255,255,0.62); font-size: 13px; }
.ge-chip { background-color: rgba(255,255,255,0.07); border: 1px solid rgba(255,255,255,0.10);
           border-radius: 999px; padding: 4px 11px; color: #f2f2f2; font-size: 12px; font-weight: 600; }
.ge-kicker { color: #ff6b62; font-size: 11px; font-weight: 800; letter-spacing: 2px; }
.ge-hint { color: rgba(255,255,255,0.38); font-size: 11px; }
button.ge-panic { background-image: linear-gradient(to bottom, #ff5a52, #d93036); color: #ffffff; border-radius: 14px;
                  border: 1px solid rgba(255,255,255,0.18); font-size: 17px; font-weight: 800; min-height: 56px;
                  box-shadow: 0 8px 24px rgba(229,72,77,0.45), inset 0 1px rgba(255,255,255,0.35); text-shadow: none; }
button.ge-panic:hover { background-image: linear-gradient(to bottom, #ff6a62, #e23a40); }
button.ge-panic:active { background-image: linear-gradient(to bottom, #d93036, #b3262b); }
button.ge-cancel { background-image: none; background-color: transparent; border: none; box-shadow: none;
                   color: rgba(255,255,255,0.72); font-size: 13px; font-weight: 600; }
button.ge-cancel:hover { color: #ffffff; background-color: rgba(255,255,255,0.06); }
"""


def _rounded(cr: Any, x: float, y: float, w: float, h: float, r: float) -> None:
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()


def draw_siren(cr: Any, phase: float) -> None:
    """The siren in its 128-unit box. ``phase`` runs 0…1 once a second: rays blink, the halo breathes."""
    import cairo  # type: ignore
    on = phase < 0.5
    # Halo: a soft red disc behind the dome that swells and fades.
    halo = 34 + 14 * phase
    gradient = cairo.RadialGradient(64, 72, 8, 64, 72, halo)
    gradient.add_color_stop_rgba(0, *RED, 0.55 * (1 - phase))
    gradient.add_color_stop_rgba(1, *RED, 0)
    cr.set_source(gradient)
    cr.arc(64, 72, halo, 0, 2 * math.pi)
    cr.fill()
    cr.set_line_cap(cairo.LINE_CAP_ROUND)
    cr.set_line_width(7)
    cr.set_source_rgba(*RAY, 1.0 if on else 0.16)
    for (x1, y1), (x2, y2) in _RAYS:
        cr.move_to(x1, y1); cr.line_to(x2, y2)
    cr.stroke()
    # Dome with a vertical gloss.
    cr.move_to(34, 94); cr.line_to(34, 70); cr.arc(64, 70, 30, math.pi, 2 * math.pi); cr.line_to(94, 94); cr.close_path()
    dome = cairo.LinearGradient(0, 40, 0, 94)
    dome.add_color_stop_rgb(0, 1.0, 0.45, 0.42) if on else dome.add_color_stop_rgb(0, 0.93, 0.36, 0.36)
    dome.add_color_stop_rgb(1, *RED_DEEP)
    cr.set_source(dome)
    cr.fill()
    cr.set_source_rgba(1, 1, 1, 0.6); cr.set_line_width(5)
    cr.arc(64, 70, 18, math.pi, 1.5 * math.pi); cr.stroke()
    for x, y, w, h, r, color in ((24, 94, 80, 14, 4, (0.45, 0.09, 0.11)), (16, 108, 96, 10, 5, (0.2, 0.2, 0.21))):
        cr.set_source_rgb(*color)
        _rounded(cr, x, y, w, h, r)
        cr.fill()


class SirenArea(Gtk.DrawingArea):
    def __init__(self, size: int = 112) -> None:
        super().__init__()
        self.set_size_request(size, size)
        self.started = time.monotonic()
        self.connect("draw", self._draw)
        self._timer = GLib.timeout_add(50, self._tick)
        self.connect("destroy", lambda *_: GLib.source_remove(self._timer))

    def _tick(self) -> bool:
        self.queue_draw()
        return True

    def _draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        scale = min(width, height) / 128
        cr.translate((width - 128 * scale) / 2, (height - 128 * scale) / 2)
        cr.scale(scale, scale)
        draw_siren(cr, (time.monotonic() - self.started) % 1.0)
        return False


def _paint_card(widget: Gtk.Widget, cr: Any) -> bool:
    """Card, red glow from the top, the warning band and a thin red outline."""
    import cairo  # type: ignore
    width, height = widget.get_allocated_width(), widget.get_allocated_height()
    cr.set_operator(cairo.OPERATOR_SOURCE)
    cr.set_source_rgba(0, 0, 0, 0)
    cr.paint()
    cr.set_operator(cairo.OPERATOR_OVER)
    inset = 14
    x, y, w, h = inset, inset, width - 2 * inset, height - 2 * inset
    # Outer glow.
    for step in range(10, 0, -1):
        cr.set_source_rgba(*RED, 0.028)
        _rounded(cr, x - step, y - step, w + 2 * step, h + 2 * step, RADIUS + step)
        cr.fill()
    _rounded(cr, x, y, w, h, RADIUS)
    cr.set_source_rgb(*CARD)
    cr.fill_preserve()
    cr.save()
    cr.clip()
    glow = cairo.RadialGradient(x + w / 2, y - 40, 10, x + w / 2, y - 40, h * 0.75)
    glow.add_color_stop_rgba(0, *RED, 0.42)
    glow.add_color_stop_rgba(1, *RED, 0)
    cr.set_source(glow)
    cr.paint()
    # Warning band: diagonal stripes along the top edge.
    band = 8
    cr.rectangle(x, y, w, band)
    cr.clip()
    cr.set_source_rgb(0.12, 0.05, 0.06)
    cr.paint()
    cr.set_source_rgba(*RED, 0.95)
    offset = -band
    while offset < w + band:
        cr.move_to(x + offset, y + band); cr.line_to(x + offset + band, y); cr.line_to(x + offset + band * 2, y)
        cr.line_to(x + offset + band, y + band); cr.close_path()
        offset += band * 2.2
    cr.fill()
    cr.restore()
    _rounded(cr, x + 0.75, y + 0.75, w - 1.5, h - 1.5, RADIUS)
    cr.set_source_rgba(1.0, 0.36, 0.33, 0.85)
    cr.set_line_width(1.5)
    cr.stroke()
    return False


def confirm(parent: Gtk.Window | None, printers: list[str]) -> bool:
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS)

    def styled(widget: Gtk.Widget, css: str) -> Gtk.Widget:
        widget.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        widget.get_style_context().add_class(css)
        return widget

    dialog = Gtk.Window(title=i18n.t("Emergency power-off"), modal=True, decorated=False, resizable=False)
    if parent is not None:
        dialog.set_transient_for(parent)
    dialog.set_position(Gtk.WindowPosition.CENTER_ALWAYS)
    dialog.set_keep_above(True)
    screen = dialog.get_screen()
    visual = screen.get_rgba_visual() if screen is not None else None
    if visual is not None:
        dialog.set_visual(visual)
    dialog.set_app_paintable(True)
    dialog.connect("draw", _paint_card)

    inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    inner.set_margin_top(40); inner.set_margin_bottom(34); inner.set_margin_start(46); inner.set_margin_end(46)
    inner.set_size_request(380, -1)

    def label(text: str, css: str) -> Gtk.Label:
        widget = Gtk.Label(label=text, wrap=True, justify=Gtk.Justification.CENTER, max_width_chars=42)
        return styled(widget, css)

    inner.pack_start(SirenArea(), False, False, 0)
    inner.pack_start(label(i18n.t("Emergency power-off").upper(), "ge-kicker"), False, False, 2)
    inner.pack_start(label(i18n.t("Switch off every printer's power?"), "ge-title"), False, False, 0)
    inner.pack_start(label(i18n.t("{0} sockets are switched off at once. Running prints end and cannot be resumed.").format(len(printers)),
                           "ge-detail"), False, False, 0)
    chips = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, homogeneous=False, max_children_per_line=4,
                        min_children_per_line=max(1, min(len(printers), 3)),
                        halign=Gtk.Align.CENTER, column_spacing=6, row_spacing=6)
    chips.set_margin_top(8); chips.set_margin_bottom(14)
    for name in printers:
        chip = styled(Gtk.Label(label=f"🖨  {name}"), "ge-chip")
        child = Gtk.FlowBoxChild(); child.add(chip); chips.add(child)
    inner.pack_start(chips, False, False, 0)

    result = {"ok": False}
    loop = GLib.MainLoop()

    def finish(ok: bool) -> None:
        result["ok"] = ok
        dialog.destroy()

    go = styled(Gtk.Button(label="⏻  " + i18n.t("Switch everything off")), "ge-panic")
    go.set_can_default(True)
    go.connect("clicked", lambda *_: finish(True))
    cancel = styled(Gtk.Button(label=i18n.t("Cancel"), halign=Gtk.Align.CENTER), "ge-cancel")
    cancel.connect("clicked", lambda *_: finish(False))
    inner.pack_start(go, False, False, 0)
    inner.pack_start(cancel, False, False, 4)
    inner.pack_start(label(i18n.t("Return — switch off · Esc — cancel"), "ge-hint"), False, False, 0)

    def key(_widget: Gtk.Widget, event: Any) -> bool:
        from gi.repository import Gdk  # type: ignore
        if event.keyval == Gdk.KEY_Escape:
            finish(False)
            return True
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            finish(True)
            return True
        return False
    dialog.connect("key-press-event", key)
    dialog.connect("destroy", lambda *_: loop.quit())
    dialog.add(inner)
    dialog.show_all()
    go.grab_default()
    go.grab_focus()
    dialog.present()
    loop.run()
    return result["ok"]
