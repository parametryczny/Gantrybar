from __future__ import annotations

"""The emergency power-off question as a panic panel: red frame, the blinking siren from
design/emergency-siren.svg drawn with cairo, the printers it will hit and one big red button (Enter),
Esc to back out. Mirrors the macOS EmergencyPanel.

gi is already pinned in app.py.
"""

import math
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from . import i18n

RED = (0.898, 0.282, 0.302)
RAY = (1.0, 0.271, 0.227)
_RAYS = (((10, 50), (24, 56)), ((24, 18), (35, 31)), ((64, 4), (64, 19)), ((104, 18), (93, 31)), ((118, 50), (104, 56)))

_CSS = b"""
.gantry-emergency { background-color: #1c1213; border: 4px solid #ff453a; border-radius: 22px; }
.gantry-emergency-title { color: #ff6b66; font-size: 19px; font-weight: 900; }
.gantry-emergency-detail { color: rgba(255,255,255,0.8); font-size: 13px; }
.gantry-emergency-list { color: #ffffff; font-size: 12px; font-weight: 600; }
.gantry-emergency-hint { color: rgba(255,255,255,0.45); font-size: 10.5px; }
button.gantry-panic { background-image: none; background-color: #e5484d; color: #ffffff; border-radius: 12px;
                      border: none; font-size: 17px; font-weight: 900; min-height: 54px; box-shadow: none; }
button.gantry-panic:hover { background-color: #f0555a; }
button.gantry-panic:active { background-color: #b8363a; }
"""


class SirenArea(Gtk.DrawingArea):
    def __init__(self) -> None:
        super().__init__()
        self.set_size_request(104, 104)
        self.rays_on = True
        self.connect("draw", self._draw)
        self._timer = GLib.timeout_add(450, self._blink)
        self.connect("destroy", lambda *_: GLib.source_remove(self._timer))

    def _blink(self) -> bool:
        self.rays_on = not self.rays_on
        self.queue_draw()
        return True

    def _draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        scale = min(width, height) / 128
        cr.translate((width - 128 * scale) / 2, (height - 128 * scale) / 2)
        cr.scale(scale, scale)
        cr.set_line_cap(1)  # cairo.LINE_CAP_ROUND
        cr.set_source_rgba(*RAY, 1.0 if self.rays_on else 0.18)
        cr.set_line_width(7)
        for (x1, y1), (x2, y2) in _RAYS:
            cr.move_to(x1, y1); cr.line_to(x2, y2)
        cr.stroke()
        # Glow behind the dome, then the dome: M34 94 V70 A30 30 0 0 1 94 70 V94 Z
        for radius, alpha in ((40, 0.12 if self.rays_on else 0.05), (35, 0.2 if self.rays_on else 0.08)):
            cr.set_source_rgba(*RED, alpha)
            cr.arc(64, 72, radius, math.pi, 2 * math.pi); cr.line_to(64 + radius, 96); cr.line_to(64 - radius, 96)
            cr.close_path(); cr.fill()
        cr.set_source_rgb(*RED)
        cr.move_to(34, 94); cr.line_to(34, 70); cr.arc(64, 70, 30, math.pi, 2 * math.pi); cr.line_to(94, 94); cr.close_path()
        cr.fill()
        cr.set_source_rgba(1, 1, 1, 0.55); cr.set_line_width(5)
        cr.arc(64, 70, 18, math.pi, 1.5 * math.pi); cr.stroke()
        for x, y, w, h, r, color in ((24, 94, 80, 14, 4, (0.557, 0.106, 0.122)), (16, 108, 96, 10, 5, (0.227, 0.227, 0.235))):
            cr.set_source_rgb(*color)
            cr.new_sub_path()
            cr.arc(x + w - r, y + r, r, -math.pi / 2, 0); cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
            cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi); cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
            cr.close_path(); cr.fill()
        return False


def confirm(parent: Gtk.Window | None, printers: list[str]) -> bool:
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS)
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
        dialog.connect("draw", lambda _w, cr: (cr.set_source_rgba(0, 0, 0, 0), cr.set_operator(1), cr.paint(), cr.set_operator(2), False)[-1])

    frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
    frame.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    frame.get_style_context().add_class("gantry-emergency")
    for side in ("top", "bottom", "start", "end"):
        getattr(frame, f"set_margin_{side}")(0)
    inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=28)
    inner.set_size_request(400, -1)
    frame.pack_start(inner, True, True, 0)

    def text(value: str, css: str) -> Gtk.Label:
        label = Gtk.Label(label=value, wrap=True, justify=Gtk.Justification.CENTER, max_width_chars=44)
        label.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        label.get_style_context().add_class(css)
        return label

    inner.pack_start(SirenArea(), False, False, 0)
    inner.pack_start(text(i18n.t("Switch off every printer's power?").upper(), "gantry-emergency-title"), False, False, 0)
    inner.pack_start(text(i18n.t("{0} sockets are switched off at once. Running prints end and cannot be resumed.").format(len(printers)),
                          "gantry-emergency-detail"), False, False, 0)
    inner.pack_start(text("\n".join(f"•  {name}" for name in printers), "gantry-emergency-list"), False, False, 6)

    result = {"ok": False}
    loop = GLib.MainLoop()

    def finish(ok: bool) -> None:
        result["ok"] = ok
        dialog.destroy()

    go = Gtk.Button(label="⚡ " + i18n.t("Switch everything off").upper())
    go.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    go.get_style_context().add_class("gantry-panic")
    go.set_can_default(True)
    go.connect("clicked", lambda *_: finish(True))
    cancel = Gtk.Button(label=i18n.t("Cancel"), halign=Gtk.Align.CENTER)
    cancel.connect("clicked", lambda *_: finish(False))
    inner.pack_start(go, False, False, 0)
    inner.pack_start(cancel, False, False, 0)
    inner.pack_start(text(i18n.t("Return — switch off · Esc — cancel"), "gantry-emergency-hint"), False, False, 0)

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
    dialog.add(frame)
    dialog.show_all()
    go.grab_default()
    go.grab_focus()
    dialog.present()
    loop.run()
    return result["ok"]
