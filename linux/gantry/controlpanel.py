"""The printer control panel beside the Linux details, the GTK counterpart of macOS PrinterControlPanel:
print actions, sending a file (optionally straight to print), moving the head, temperatures, fans and
speed, and the socket's power draw.

Every command goes through the app (send_print_action, jog, home, set_* …), which already knows each
brand's dialect. The cards are rearranged by the printer's state so the controls that matter now come
first; moves are only offered while nothing is printing, and only with printer control switched on.
gi is already pinned in app.py.
"""
from __future__ import annotations

import math
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any, Callable

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # type: ignore

from . import i18n
from .control import (FAN_ECHO_TOLERANCE, PANEL_WIDTH, POWER_SAMPLE_SECONDS, POWER_SAMPLES, StepperModel,
                      card_order, motion_row_visible)
from .core import PrinterKind, PrinterState, Telemetry

_SPEED_MODES = ("Silent", "Standard", "Sport", "Ludicrous")


def _label(text: str = "", css: str | None = None, wrap: bool = False, xalign: float = 0) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=xalign)
    if wrap:
        label.set_line_wrap(True)
        label.set_max_width_chars(46)
    if css:
        label.get_style_context().add_class(css)
    return label


class Glyph(Gtk.DrawingArea):
    """The print actions' symbols, drawn rather than taken from the icon theme so they look the same on
    every desktop: pause, play, stop, lamp and power, in the button's own text colour."""

    def __init__(self, name: str) -> None:
        super().__init__()
        self.symbol = name
        self.set_size_request(22, 20)
        self.connect("draw", self._draw)

    def show_symbol(self, name: str) -> None:
        if name != self.symbol:
            self.symbol = name
            self.queue_draw()

    def _draw(self, _widget: Any, cr: Any) -> bool:
        color = self.get_style_context().get_color(self.get_state_flags())
        cr.set_source_rgba(color.red, color.green, color.blue, color.alpha)
        cx, cy = self.get_allocated_width() / 2, self.get_allocated_height() / 2
        name = self.symbol
        if name == "pause":
            cr.rectangle(cx - 6, cy - 7, 4, 14); cr.rectangle(cx + 2, cy - 7, 4, 14); cr.fill()
        elif name == "play":
            cr.move_to(cx - 5, cy - 7); cr.line_to(cx + 7, cy); cr.line_to(cx - 5, cy + 7); cr.close_path(); cr.fill()
        elif name == "stop":
            _rounded(cr, cx - 6, cy - 6, 12, 12, 2); cr.fill()
        elif name == "light":
            cr.set_line_width(1.8)
            cr.arc(cx, cy - 2.5, 5.5, math.pi * 0.8, math.pi * 2.2); cr.stroke()
            cr.move_to(cx - 3, cy + 4); cr.line_to(cx + 3, cy + 4); cr.stroke()
            cr.move_to(cx - 2, cy + 7); cr.line_to(cx + 2, cy + 7); cr.stroke()
        elif name == "power":
            cr.set_line_width(2)
            cr.arc(cx, cy + 1, 7, -math.pi / 2 + 0.7, 3 * math.pi / 2 - 0.7); cr.stroke()
            cr.move_to(cx, cy - 8); cr.line_to(cx, cy); cr.stroke()
        return False


class SliderRow(Gtk.Box):
    """A labelled slider that sends its value when released and shows "actual / target". The value model
    is the same StepperModel the capsules used, so telemetry still carrying the old setpoint does not pull
    the thumb back while the printer catches up."""

    def __init__(self, title: str, glyph: str, model: StepperModel, suffix: str,
                 on_commit: Callable[[int], Any]) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.model, self.suffix, self.on_commit = model, suffix, on_commit
        self._dragging = False
        self._programmatic = False
        self._settle = 0
        top = Gtk.Box(spacing=6)
        icon = _label(glyph, "panel-glyph")
        self.value = _label("—", "panel-value", xalign=1)
        top.pack_start(icon, False, False, 0)
        top.pack_start(_label(title, "panel-row-title"), False, False, 0)
        top.pack_end(self.value, False, False, 0)
        self.scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, model.low, model.high, model.step)
        self.scale.set_draw_value(False)
        self.scale.get_style_context().add_class("panel-scale")
        self.scale.connect("button-press-event", self._press)
        self.scale.connect("button-release-event", self._release)
        self.scale.connect("value-changed", self._changed)
        self.pack_start(top, False, False, 0)
        self.pack_start(self.scale, False, False, 0)
        self.connect("destroy", self._destroyed)

    def _snapped(self) -> int:
        step = self.model.step
        return self.model.clamp(round(self.scale.get_value() / step) * step)

    def _press(self, *_args: Any) -> bool:
        self._dragging = True
        return False

    def _release(self, *_args: Any) -> bool:
        self._dragging = False
        self._commit()
        return False

    def _changed(self, *_args: Any) -> None:
        if self._programmatic:
            return
        self.model.value = self._snapped()
        self.model.pending = True
        self.value.set_text(f"→ {self.model.value}{self.suffix}")
        if not self._dragging:
            # The keyboard or the wheel moved it: send once it stops.
            if self._settle:
                GLib.source_remove(self._settle)
            self._settle = GLib.timeout_add(600, self._settled)

    def _settled(self) -> bool:
        self._settle = 0
        self._commit()
        return False

    def _commit(self) -> None:
        if not self.model.pending:
            return
        value = self.model.commit(time.monotonic())
        self._set(value)
        self.on_commit(value)

    def _set(self, value: float) -> None:
        self._programmatic = True
        self.scale.set_value(value)
        self._programmatic = False

    def _destroyed(self, *_args: Any) -> None:
        if self._settle:
            GLib.source_remove(self._settle)
            self._settle = 0

    def set_enabled(self, enabled: bool) -> None:
        self.scale.set_sensitive(enabled)

    def update(self, actual: float | None, target: float | None) -> None:
        if self._dragging or self.model.pending:
            return
        reading = "—" if actual is None else f"{actual:.0f}"
        self.value.set_text(f"{reading} / {target:.0f}{self.suffix}" if target is not None else f"{reading}{self.suffix}")
        reported = target if target is not None else actual
        if reported is not None and self.model.show(round(reported), time.monotonic()):
            self._set(self.model.value)
        elif reported is not None and abs(self.scale.get_value() - self.model.value) > 0.5:
            self._set(self.model.value)


class JogPad(Gtk.DrawingArea):
    """A round XY pad: the inner ring moves 1 mm, the outer ring 10 mm, the centre homes X and Y."""

    def __init__(self, on_jog: Callable[[float, float], Any], on_home: Callable[[], Any]) -> None:
        super().__init__()
        self.on_jog, self.on_home = on_jog, on_home
        self.enabled = True
        self.hover: tuple[int, float] | None = None
        self.set_size_request(180, 180)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.POINTER_MOTION_MASK
                        | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.connect("draw", self._draw)
        self.connect("button-press-event", self._press)
        self.connect("motion-notify-event", self._motion)
        self.connect("leave-notify-event", lambda *_: self._set_hover(None))

    @staticmethod
    def hit(width: float, height: float, x: float, y: float) -> tuple[int, float] | None:
        """(direction, distance): 0 up (+Y), 1 right (+X), 2 down (−Y), 3 left (−X); -1 is home."""
        radius = min(width, height) / 2
        dx, dy = x - width / 2, height / 2 - y
        r = math.hypot(dx, dy)
        if r > radius:
            return None
        if r < radius * 0.3:
            return -1, 0
        distance = 1.0 if r < radius * 0.64 else 10.0
        direction = (1 if dx > 0 else 3) if abs(dx) > abs(dy) else (0 if dy > 0 else 2)
        return direction, distance

    def set_enabled(self, enabled: bool) -> None:
        if enabled != self.enabled:
            self.enabled = enabled
            self.queue_draw()

    def _set_hover(self, value: tuple[int, float] | None) -> None:
        if value != self.hover:
            self.hover = value
            self.queue_draw()

    def _motion(self, _widget: Any, event: Any) -> bool:
        self._set_hover(self.hit(self.get_allocated_width(), self.get_allocated_height(), event.x, event.y))
        return False

    def _press(self, _widget: Any, event: Any) -> bool:
        target = self.hit(self.get_allocated_width(), self.get_allocated_height(), event.x, event.y)
        if not self.enabled or target is None or event.button != 1:
            return False
        direction, distance = target
        if direction == -1:
            self.on_home()
        else:
            dx, dy = {0: (0, distance), 1: (distance, 0), 2: (0, -distance), 3: (-distance, 0)}[direction]
            self.on_jog(dx, dy)
        return True

    def _draw(self, _widget: Any, cr: Any) -> bool:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        radius = min(width, height) / 2 - 1
        cx, cy = width / 2, height / 2
        alpha = 1.0 if self.enabled else 0.45

        def ring(outer: float, inner: float, value: float) -> None:
            cr.new_path()
            cr.arc(cx, cy, outer, 0, 2 * math.pi)
            cr.arc_negative(cx, cy, inner, 2 * math.pi, 0)
            cr.set_source_rgba(1, 1, 1, value * alpha)
            cr.fill()
        ring(radius, radius * 0.64, 0.07)
        ring(radius * 0.64, radius * 0.3, 0.11)
        if self.enabled and self.hover is not None:
            cr.new_path()
            direction, distance = self.hover
            if direction == -1:
                cr.arc(cx, cy, radius * 0.3, 0, 2 * math.pi)
            else:
                middle = {0: -90, 1: 0, 2: 90, 3: 180}[direction] * math.pi / 180
                outer, inner = (radius, radius * 0.64) if distance == 10 else (radius * 0.64, radius * 0.3)
                cr.arc(cx, cy, outer, middle - math.pi / 4, middle + math.pi / 4)
                cr.arc_negative(cx, cy, inner, middle + math.pi / 4, middle - math.pi / 4)
                cr.close_path()
            cr.set_source_rgba(0.04, 0.52, 1.0, 0.28)
            cr.fill()
        cr.set_source_rgba(0, 0, 0, 0.35)
        cr.set_line_width(1)
        for angle in (45, 135, 225, 315):
            a = angle * math.pi / 180
            cr.move_to(cx + math.cos(a) * radius * 0.3, cy + math.sin(a) * radius * 0.3)
            cr.line_to(cx + math.cos(a) * radius, cy + math.sin(a) * radius)
        cr.stroke()
        cr.arc(cx, cy, radius * 0.3 - 3, 0, 2 * math.pi)
        cr.set_source_rgba(0, 0, 0, 0.3)
        cr.fill()

        ink = (0.95, 0.95, 0.94, alpha)

        def text(value: str, x: float, y: float, size: float, bold: bool) -> None:
            cr.select_font_face("Sans", 0, 1 if bold else 0)
            cr.set_font_size(size)
            extents = cr.text_extents(value)
            cr.move_to(x - extents.width / 2 - extents.x_bearing, y - extents.height / 2 - extents.y_bearing)
            cr.set_source_rgba(*ink)
            cr.show_text(value)
        outer_mid, inner_mid = radius * 0.82, radius * 0.47
        text("Y", cx, cy - outer_mid, 12, True)
        text("−Y", cx, cy + outer_mid, 12, True)
        text("X", cx + outer_mid, cy, 12, True)
        text("−X", cx - outer_mid, cy, 12, True)
        for dx, dy in ((0, -1), (0, 1), (1, 0), (-1, 0)):
            text("1", cx + dx * inner_mid, cy + dy * inner_mid, 9, False)
        text("⌂", cx, cy, 17, True)
        return False


class PowerChart(Gtk.DrawingArea):
    """The socket's draw over the last few minutes."""

    def __init__(self) -> None:
        super().__init__()
        self.samples: list[float] = []
        self.set_size_request(-1, 90)
        self.connect("draw", self._draw)

    def append(self, watts: float) -> None:
        self.samples.append(watts)
        del self.samples[:-POWER_SAMPLES]
        self.queue_draw()

    def _draw(self, _widget: Any, cr: Any) -> bool:
        width, height = self.get_allocated_width(), self.get_allocated_height()
        _rounded(cr, 0, 0, width, height, 8)
        cr.set_source_rgba(1, 1, 1, 0.045)
        cr.fill()
        pad = 10
        if len(self.samples) < 2:
            cr.select_font_face("Sans", 0, 0)
            cr.set_font_size(11)
            message = i18n.t("Collecting data…")
            extents = cr.text_extents(message)
            cr.move_to((width - extents.width) / 2 - extents.x_bearing, height / 2 - extents.height / 2 - extents.y_bearing)
            cr.set_source_rgba(0.55, 0.56, 0.58, 1)
            cr.show_text(message)
            return False
        top = max(max(self.samples) * 1.15, 10)
        step = (width - 2 * pad) / (POWER_SAMPLES - 1)
        start = width - pad - step * (len(self.samples) - 1)
        points = [(start + step * index, height - pad - (height - 2 * pad) * value / top)
                  for index, value in enumerate(self.samples)]
        cr.move_to(*points[0])
        for point in points[1:]:
            cr.line_to(*point)
        cr.line_to(width - pad, height - pad)
        cr.line_to(start, height - pad)
        cr.close_path()
        cr.set_source_rgba(0.35, 0.78, 0.98, 0.18)
        cr.fill()
        cr.move_to(*points[0])
        for point in points[1:]:
            cr.line_to(*point)
        cr.set_source_rgba(0.35, 0.78, 0.98, 1)
        cr.set_line_width(1.6)
        cr.stroke()
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(9)
        cr.move_to(pad, pad + 8)
        cr.set_source_rgba(0.55, 0.56, 0.58, 1)
        cr.show_text(f"{max(self.samples):.0f} W")
        return False


class ControlPanel(Gtk.Box):
    """The panel itself. ``windowed`` is the Gantry window (not the tray popover): there the keyboard can
    move the head while the pointer is over the panel."""

    def __init__(self, app: Any, serial: str, windowed: bool) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.app, self.serial, self.windowed = app, serial, windowed
        self.get_style_context().add_class("control-panel")
        self.set_size_request(PANEL_WIDTH, -1)
        self._order: tuple[str, ...] = ()
        self._light_on = False
        self._socket_on: bool | None = None
        self._power_source = 0
        self._key_handler: tuple[Any, int] | None = None
        self._farm_listener: Callable[[], None] | None = None
        self._speed_updating = False

        title = _label(i18n.t("Control").upper(), "detail-title")
        self.pack_start(title, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.pack_start(scroll, True, True, 0)
        self.stack = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.stack.set_border_width(2)
        scroll.add(self.stack)

        self.opt_in = self._card(i18n.t("CONTROL IS OFF"), self._opt_in())
        self.stack.pack_start(self.opt_in, False, False, 0)
        self.cards = {
            "print": self._card(i18n.t("PRINT"), self._actions()),
            "send": self._card(i18n.t("SEND FILE"), self._send()),
            "motion": self._card(i18n.t("MOTION"), self._motion()),
            "thermal": self._card(i18n.t("TEMPERATURES AND FANS"), self._thermal()),
            "power": self._card(i18n.t("POWER"), self._power()),
        }
        self.arrange(False)
        self.connect("map", self._mapped)
        self.connect("unmap", self._unmapped)
        self.connect("destroy", self._unmapped)

    @property
    def printer(self) -> Any:
        return next((p for p in self.app.printers if p.serial == self.serial), None)

    # ------------------------------------------------------------------ build
    @staticmethod
    def _card(title: str, content: Gtk.Widget) -> Gtk.Box:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=9)
        card.get_style_context().add_class("detail-card")
        card.pack_start(_label(title, "detail-title"), False, False, 0)
        card.pack_start(content, False, False, 0)
        return card

    def arrange(self, busy: bool) -> None:
        """While printing: print actions, temperatures and power first, motion folded away. Otherwise the
        things done between prints come first: sending a file and moving the head."""
        order = card_order(busy)
        if order == self._order:
            return
        self._order = order
        for position, key in enumerate(order, start=1):
            card = self.cards[key]
            if card.get_parent() is None:
                self.stack.pack_start(card, False, False, 0)
            self.stack.reorder_child(card, position)

    def _opt_in(self) -> Gtk.Widget:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.pack_start(_label(i18n.t("Printer control is off. Turn it on to move the head and set temperatures, fans and speed from Gantry."),
                              "panel-hint", wrap=True), False, False, 0)
        button = Gtk.Button(label=i18n.t("Turn on control"))
        button.set_halign(Gtk.Align.START)
        button.connect("clicked", lambda *_: self._enable_control())
        box.pack_start(button, False, False, 0)
        return box

    def _icon_button(self, icon: str, caption: str, callback: Callable[[], Any]) -> Gtk.Button:
        button = Gtk.Button()
        button.get_style_context().add_class("panel-icon")
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        image = Glyph(icon)
        text = _label(caption, "panel-icon-caption", xalign=0.5)
        column.pack_start(image, False, False, 0)
        column.pack_start(text, False, False, 0)
        button.add(column)
        button._image, button._caption = image, text  # type: ignore[attr-defined]
        button.connect("clicked", lambda *_: callback())
        return button

    def _actions(self) -> Gtk.Widget:
        row = Gtk.Box(spacing=8, homogeneous=True)
        self.pause = self._icon_button("pause", i18n.t("Pause"), self._pause_or_resume)
        self.stop = self._icon_button("stop", i18n.t("Stop"), self._confirm_stop)
        self.stop.get_style_context().add_class("danger")
        # Not "Light": that key is the light theme, and reads "Jasny" in Polish.
        self.light = self._icon_button("light", i18n.t("Lamp"), self._toggle_light)
        self.socket = self._icon_button("power", i18n.t("Power"), self._toggle_socket)
        for button in (self.pause, self.stop, self.light, self.socket):
            row.pack_start(button, True, True, 0)
        return row

    def _send(self) -> Gtk.Widget:
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.drop = Gtk.EventBox()
        self.drop.set_visible_window(False)
        self.drop_frame = Gtk.Box()
        self.drop_frame.get_style_context().add_class("drop-zone")
        self.drop_frame.set_size_request(-1, 74)
        self.drop_caption = _label("", "panel-hint", wrap=True, xalign=0.5)
        self.drop_caption.set_justify(Gtk.Justification.CENTER)
        self.drop_frame.set_center_widget(self.drop_caption)
        self.drop.add(self.drop_frame)
        self.drop.drag_dest_set(Gtk.DestDefaults.ALL, [Gtk.TargetEntry.new("text/uri-list", 0, 0)], Gdk.DragAction.COPY)
        self.drop.connect("drag-data-received", self._dropped)
        self.drop.connect("drag-motion", lambda *_: (self.drop_frame.get_style_context().add_class("hover"), False)[1])
        self.drop.connect("drag-leave", lambda *_: self.drop_frame.get_style_context().remove_class("hover"))
        buttons = Gtk.Box(spacing=8)
        choose = Gtk.Button(label=i18n.t("Choose file…"))
        choose.connect("clicked", lambda *_: self._choose_file())
        farm = Gtk.Button(label=i18n.t("Farm…"))
        farm.connect("clicked", lambda *_: self.app.open_farm())
        buttons.pack_start(choose, False, False, 0)
        buttons.pack_end(farm, False, False, 0)
        self.send_status = _label("", "panel-hint", wrap=True)
        for widget in (self.drop, buttons, self.send_status):
            column.pack_start(widget, False, False, 0)
        return column

    def _motion(self) -> Gtk.Widget:
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.motion_row = Gtk.Box(spacing=10)
        self.jog_pad = JogPad(lambda dx, dy: self.app.jog(self.serial, x=dx, y=dy),
                              lambda: self.app.home(self.serial, "XY"))
        self.motion_buttons: list[Gtk.Button] = []

        def button(title: str, callback: Callable[[], Any]) -> Gtk.Button:
            widget = Gtk.Button(label=title)
            widget.set_size_request(72, -1)
            widget.connect("clicked", lambda *_: callback())
            self.motion_buttons.append(widget)
            return widget
        z = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for title, distance in (("Z +10", 10), ("Z +1", 1), ("Z −1", -1), ("Z −10", -10)):
            z.pack_start(button(title, lambda d=distance: self.app.jog(self.serial, z=d)), False, False, 0)
        home = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        for title, axes in ((i18n.t("All"), ""), ("X", "X"), ("Y", "Y"), ("Z", "Z")):
            home.pack_start(button(f"⌂ {title}", lambda a=axes: self.app.home(self.serial, a)), False, False, 0)
        z.set_valign(Gtk.Align.CENTER); home.set_valign(Gtk.Align.CENTER)
        self.motion_row.pack_start(self.jog_pad, False, False, 0)
        self.motion_row.pack_start(z, False, False, 0)
        self.motion_row.pack_start(home, False, False, 0)
        self.motion_notice = _label("", "control-notice", wrap=True)
        self.keyboard_hint = _label(i18n.t("Pointer over this panel: arrows move X/Y, Shift ×10, Page Up/Down move Z, H homes."),
                                    "panel-hint", wrap=True)
        for widget in (self.motion_row, self.motion_notice, self.keyboard_hint):
            column.pack_start(widget, False, False, 0)
        return column

    def _thermal(self) -> Gtk.Widget:
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        app, serial = self.app, self.serial
        self.nozzle = SliderRow(i18n.t("Nozzle"), "▲", StepperModel(0, 300, 5), "°",
                                lambda value: app.set_nozzle_temperature(serial, value))
        self.bed = SliderRow(i18n.t("Bed"), "▬", StepperModel(0, 120, 5), "°",
                             lambda value: app.set_bed_temperature(serial, value))
        self.chamber = _label("", "panel-value")
        self.part_fan = SliderRow(i18n.t("Part fan"), "✣", StepperModel(0, 100, 10, echo_tolerance=FAN_ECHO_TOLERANCE), "%",
                                  lambda value: app.set_fan(serial, 1, value))
        self.aux_fan = SliderRow(i18n.t("Aux fan"), "✣", StepperModel(0, 100, 10, echo_tolerance=FAN_ECHO_TOLERANCE), "%",
                                 lambda value: app.set_fan(serial, 2, value))
        self.chamber_fan = SliderRow(i18n.t("Chamber fan"), "✣", StepperModel(0, 100, 10, echo_tolerance=FAN_ECHO_TOLERANCE), "%",
                                     lambda value: app.set_fan(serial, 3, value))
        # Bambu takes a speed mode, the others a percentage.
        self.speed_model = StepperModel(1, 4, 1)
        self.speed_modes = Gtk.Box(spacing=0, homogeneous=True)
        self.speed_modes.get_style_context().add_class("linked")
        self.speed_buttons: list[Gtk.ToggleButton] = []
        for level, name in enumerate(_SPEED_MODES, start=1):
            toggle = Gtk.ToggleButton(label=i18n.t(name))
            toggle.connect("toggled", self._speed_toggled, level)
            self.speed_buttons.append(toggle)
            self.speed_modes.pack_start(toggle, True, True, 0)
        self.speed = SliderRow(i18n.t("Speed"), "»", StepperModel(10, 166, 10), "%",
                               lambda value: app.set_print_speed(serial, value))
        self.thermal_notice = _label("", "control-notice", wrap=True)
        for widget in (self.nozzle, self.bed, self.chamber, self.part_fan, self.aux_fan, self.chamber_fan,
                       self.speed_modes, self.speed, self.thermal_notice):
            column.pack_start(widget, False, False, 0)
        return column

    def _power(self) -> Gtk.Widget:
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        row = Gtk.Box(spacing=8)
        self.power_label = _label("", "panel-value")
        self.power_setup = Gtk.Button(label=i18n.t("Set up socket…"))
        self.power_setup.connect("clicked", lambda *_: self.app.open_smart_plug(self.serial))
        row.pack_start(self.power_label, True, True, 0)
        row.pack_end(self.power_setup, False, False, 0)
        self.chart = PowerChart()
        column.pack_start(row, False, False, 0)
        column.pack_start(self.chart, False, False, 0)
        return column

    # ------------------------------------------------------------------ state
    def _plug(self) -> Any:
        controller = getattr(self.app, "smart_plugs", None)
        return controller.store.plug(self.serial) if controller is not None else None

    def _control_on(self) -> bool:
        return bool(self.app.config.data.get("printer_control_enabled", False))

    def _signing(self) -> bool:
        requires = getattr(self.app, "requires_signed_commands", None)
        return bool(callable(requires) and requires(self.serial))

    def _accepts_gcode(self) -> bool:
        accepts = getattr(self.app, "accepts_gcode", None)
        return bool(callable(accepts) and accepts(self.serial))

    def _motion_safe(self) -> bool:
        safe = getattr(self.app, "is_motion_safe", None)
        return bool(callable(safe) and safe(self.serial))

    def update(self, tel: Telemetry | None = None) -> None:
        printer = self.printer
        if printer is None:
            return
        tel = tel or self.app.telemetry.get(self.serial, Telemetry())
        busy = tel.state in (PrinterState.PRINTING, PrinterState.PAUSED)
        online = tel.state != PrinterState.OFFLINE
        allowed = self._control_on()
        self.arrange(busy)
        self.opt_in.set_visible(not allowed)

        paused = tel.state == PrinterState.PAUSED
        self.pause._image.show_symbol("play" if paused else "pause")
        self.pause._caption.set_text(i18n.t("Resume") if paused else i18n.t("Pause"))
        self.pause.set_sensitive(busy)
        self.stop.set_sensitive(busy)
        self.light.set_sensitive(online)
        self._lit(self.light, self._light_on)
        plug = self._plug()
        self.socket.set_sensitive(plug is not None)
        self._lit(self.socket, self._socket_on is True)
        self.socket.set_tooltip_text(None if plug is not None else i18n.t("No smart socket is set up for this printer."))

        from .transfer import accepts
        extensions = [value for value in ("3mf", "gcode", "bgcode") if accepts(printer.kind, value)]
        self.drop_caption.set_text(i18n.t("This printer cannot receive files from Gantry.") if not extensions else
                                   i18n.t("Drop a file here") + "\n" +
                                   i18n.t("Supported: {0}").format(", ".join("." + value for value in extensions)))
        self.drop.set_sensitive(bool(extensions))

        takes = self._accepts_gcode()
        motion = takes and allowed and self._motion_safe()
        self.jog_pad.set_enabled(motion)
        for button in self.motion_buttons:
            button.set_sensitive(motion)
        self.motion_row.set_visible(motion_row_visible(motion, busy, takes))
        self.keyboard_hint.set_visible(self.windowed and motion)
        self.motion_notice.set_visible(not motion and allowed)
        self.motion_notice.set_text(i18n.t("This printer does not take motion commands from Gantry.") if not takes else
                                    i18n.t("Moving the head is available while the printer is not printing."))

        bambu = printer.kind == PrinterKind.BAMBU
        nozzle = tel.nozzles[0] if tel.nozzles else None
        self.nozzle.update(nozzle.current if nozzle else tel.nozzle, nozzle.target if nozzle else tel.nozzle_target)
        self.bed.update(tel.bed, tel.bed_target)
        self.chamber.set_visible(tel.chamber is not None)
        self.chamber.set_text(f"{i18n.t('Chamber')}: " + ("—" if tel.chamber is None else f"{tel.chamber:.0f}°"))
        self.part_fan.update(tel.part_fan, None)
        self.aux_fan.update(tel.aux_fan, None)
        self.chamber_fan.update(tel.chamber_fan, None)
        self.aux_fan.set_visible(bambu)
        self.chamber_fan.set_visible(bambu)
        self.speed_modes.set_visible(bambu)
        self.speed.set_visible(not bambu)
        if bambu:
            self.speed_model.show(tel.speed_level or 2, time.monotonic())
            self._show_speed_mode()
        self.speed.update(tel.speed_percent, None)
        usable = takes and online and allowed
        for row in (self.nozzle, self.bed, self.part_fan, self.aux_fan, self.chamber_fan, self.speed):
            row.set_enabled(usable)
        for toggle in self.speed_buttons:
            toggle.set_sensitive(usable)
        self.thermal_notice.set_visible(not takes)
        self.thermal_notice.set_text(signing_notice_panel() if bambu and self._signing() else
                                     i18n.t("This printer does not take temperature or fan commands from Gantry."))

        meters = plug is not None and plug.meters
        self.power_setup.set_visible(not meters)
        self.power_setup.set_label(i18n.t("Set up socket…") if plug is None else i18n.t("Socket settings…"))
        self.chart.set_visible(meters)
        if plug is None:
            self.power_label.set_text(i18n.t("No smart socket"))
        elif not meters:
            self.power_label.set_text(i18n.t("This socket does not measure power."))
        else:
            last = self.chart.samples[-1] if self.chart.samples else None
            self.power_label.set_text(f"{last:.0f} W · {i18n.t('live')}" if last is not None else i18n.t("Reading…"))

    @staticmethod
    def _lit(button: Gtk.Button, on: bool) -> None:
        context = button.get_style_context()
        (context.add_class if on else context.remove_class)("active")

    def _show_speed_mode(self) -> None:
        self._speed_updating = True
        for level, toggle in enumerate(self.speed_buttons, start=1):
            toggle.set_active(level == self.speed_model.value)
        self._speed_updating = False

    def _speed_toggled(self, toggle: Gtk.ToggleButton, level: int) -> None:
        if self._speed_updating:
            return
        if not toggle.get_active():
            if level == self.speed_model.value:
                self._show_speed_mode()   # a mode cannot be switched off, only replaced
            return
        self.speed_model.value = level
        self.speed_model.commit(time.monotonic())
        self._show_speed_mode()
        self.app.set_print_speed_level(self.serial, level)

    # ------------------------------------------------------------------ actions
    def _enable_control(self) -> None:
        self.app.config.data["printer_control_enabled"] = True
        self.app.config.save()
        self.update()

    def _pause_or_resume(self) -> None:
        tel = self.app.telemetry.get(self.serial, Telemetry())
        self.app.send_print_action(self.serial, "resume" if tel.state == PrinterState.PAUSED else "pause")

    def _confirm_stop(self) -> None:
        name = self.printer.name if self.printer else self.serial
        dialog = Gtk.MessageDialog(transient_for=self.get_toplevel(), modal=True, message_type=Gtk.MessageType.WARNING,
                                   buttons=Gtk.ButtonsType.NONE, text=i18n.t("Stop the print on {0}?").format(name))
        dialog.format_secondary_text(i18n.t("A stopped print cannot be resumed."))
        dialog.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
        stop = dialog.add_button(i18n.t("Stop"), Gtk.ResponseType.OK)
        stop.get_style_context().add_class("destructive-action")
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        confirmed = self._run(dialog) == Gtk.ResponseType.OK
        dialog.destroy()
        if confirmed:
            self.app.send_print_action(self.serial, "stop")

    def _run(self, dialog: Gtk.Dialog) -> int:
        """Runs a dialog without the tray panel hiding itself when the dialog takes the focus."""
        window = getattr(self.app, "window", None)
        if window is not None and hasattr(window, "_suppress_hide"):
            window._suppress_hide = True
        try:
            return dialog.run()
        finally:
            if window is not None and hasattr(window, "_suppress_hide"):
                window._suppress_hide = False

    def _toggle_light(self) -> None:
        self._light_on = not self._light_on
        self.app.set_chamber_light(self.serial, self._light_on)
        self._lit(self.light, self._light_on)

    def _toggle_socket(self) -> None:
        on = self._socket_on is not True
        if on:
            self.app.smart_plugs.power(True, self.serial)
        else:
            self.app.power_socket(self.serial, False)
        GLib.timeout_add(1500, lambda: (self._read_socket(), False)[1])

    def _read_socket(self) -> None:
        plug, controller = self._plug(), getattr(self.app, "smart_plugs", None)
        if plug is None or controller is None:
            return
        secret = controller.store.secret(self.serial)

        def job() -> None:
            try:
                state = plug.send(None, secret)
            except RuntimeError:
                state = None
            GLib.idle_add(lambda: (self._socket_state(state), False)[1])
        threading.Thread(target=job, daemon=True).start()

    def _socket_state(self, state: bool | None) -> None:
        self._socket_on = state
        self._lit(self.socket, state is True)

    # ------------------------------------------------------------------ sending a file
    def _dropped(self, _widget: Any, _context: Any, _x: int, _y: int, selection: Any, _info: int, _time: int) -> None:
        self.drop_frame.get_style_context().remove_class("hover")
        uris = selection.get_uris() or []
        paths = [urllib.parse.unquote(urllib.parse.urlsplit(uri).path) for uri in uris if uri.startswith("file://")]
        if paths:
            GLib.idle_add(lambda: (self.send(paths[0]), False)[1])

    def _choose_file(self) -> None:
        printer = self.printer
        if printer is None:
            return
        from .transfer import accepts
        chooser = Gtk.FileChooserDialog(title=i18n.t("Choose file…"), transient_for=self.get_toplevel(),
                                        action=Gtk.FileChooserAction.OPEN)
        chooser.add_buttons(i18n.t("Cancel"), Gtk.ResponseType.CANCEL, "OK", Gtk.ResponseType.ACCEPT)
        pattern = Gtk.FileFilter()
        extensions = [value for value in ("3mf", "gcode", "gco", "g", "bgcode") if accepts(printer.kind, value)]
        pattern.set_name(", ".join("." + value for value in extensions))
        for value in extensions:
            pattern.add_pattern(f"*.{value}"); pattern.add_pattern(f"*.{value.upper()}")
        chooser.add_filter(pattern)
        path = chooser.get_filename() if self._run(chooser) == Gtk.ResponseType.ACCEPT else None
        chooser.destroy()
        if path:
            self.send(path)

    def send(self, path: str) -> None:
        """Drop or choose a file: it goes into the Farm library, then one dialog shows what it is (preview,
        time, filament and whether the AMS has it) and offers "Upload only" or "Send and print". Printing
        stays locked until the bed is confirmed empty; the Farm's own start rules still decide when."""
        from .farm import FarmError, auto_mapping, shared
        from .transfer import accepts
        printer = self.printer
        if printer is None:
            return
        extension = Path(path).suffix.lower().lstrip(".")
        if not accepts(printer.kind, extension):
            self.send_status.set_text(i18n.t("{0} cannot print .{1} files.").format(printer.name, extension))
            return
        self.send_status.set_text(i18n.t("Preparing {0}…").format(Path(path).name))
        farm = shared(self.app)
        self._watch_farm()
        file = farm.import_file(path)
        if file is None or not file.get("plates"):
            self.send_status.set_text(farm.notice)
            return
        plate = file["plates"][0]
        mapping: list[int] = []
        note: str | None = None
        can_print = True
        if not file.get("format"):
            slots = getattr(self.app.telemetry.get(self.serial), "ams_slots", []) or []
            found = auto_mapping(plate, slots)
            if found is not None:
                mapping = found
                note = i18n.t("AMS: matching filament found.")
            elif len(plate.get("filaments") or []) > 1:
                can_print = False
                note = i18n.t("The AMS has no matching filament for every colour. Assign the slots in the Farm.")
        choice = self._confirm_send(farm, file, plate, printer, note, can_print)
        if choice is None:
            self.send_status.set_text(i18n.t("Not sent."))
            return
        try:
            if choice == "print":
                farm.arm(self.serial)
            farm.upload_to(file, plate, printer, mapping, auto_start=choice == "print")
        except FarmError as error:
            farm.disarm(self.serial)
            self.send_status.set_text(str(error))

    def _confirm_send(self, farm: Any, file: dict[str, Any], plate: dict[str, Any], printer: Any,
                      note: str | None, can_print: bool) -> str | None:
        dialog = Gtk.Dialog(title=i18n.t("Send {0} to {1}?").format(file["name"], printer.name),
                            transient_for=self.get_toplevel(), modal=True)
        dialog.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
        dialog.add_button(i18n.t("Upload only"), 2)
        send = dialog.add_button(i18n.t("Send and print"), Gtk.ResponseType.OK)
        send.get_style_context().add_class("suggested-action")
        send.set_sensitive(False)
        box = dialog.get_content_area()
        box.set_spacing(8); box.set_border_width(14)
        row = Gtk.Box(spacing=12)
        preview = farm.preview_path(file["id"], plate["index"])
        if preview.exists():
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(preview), 96, 96, True)
                row.pack_start(Gtk.Image.new_from_pixbuf(pixbuf), False, False, 0)
            except GLib.Error:
                pass
        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        heading = _label(i18n.t("Send {0} to {1}?").format(file["name"], printer.name), wrap=True)
        heading.set_markup(f"<b>{GLib.markup_escape_text(heading.get_text())}</b>")
        text.pack_start(heading, False, False, 0)
        for line in send_lines(plate, note):
            text.pack_start(_label(line, wrap=True), False, False, 0)
        row.pack_start(text, True, True, 0)
        box.pack_start(row, False, False, 0)
        bed = Gtk.CheckButton(label=i18n.t("The bed is empty and ready"))
        bed.connect("toggled", lambda check: send.set_sensitive(check.get_active() and can_print))
        box.pack_start(bed, False, False, 0)
        dialog.set_default_response(Gtk.ResponseType.CANCEL)
        dialog.show_all()
        response = self._run(dialog)
        dialog.destroy()
        return {Gtk.ResponseType.OK: "print", 2: "upload"}.get(response)

    def _watch_farm(self) -> None:
        farm = getattr(self.app, "farm", None)
        if farm is None or self._farm_listener is not None:
            return

        def changed() -> None:
            job = next((j for j in farm.jobs if j["serial"] == self.serial), None)
            if job is None:
                return
            value = farm.progress.get(job["id"])
            if value is not None:
                self.send_status.set_text(i18n.t("Sending {0}: {1}%").format(job["fileName"], int(value * 100)))
            else:
                self.send_status.set_text(f"{job['fileName']} · {job['message']}")
        self._farm_listener = changed
        farm.listeners.append(changed)

    # ------------------------------------------------------------------ lifecycle
    def _mapped(self, *_args: Any) -> None:
        self._watch_farm()
        self._read_socket()
        plug = self._plug()
        if plug is not None and plug.meters and not self._power_source:
            self._sample_power()
            self._power_source = GLib.timeout_add_seconds(POWER_SAMPLE_SECONDS, lambda: (self._sample_power(), True)[1])
        if self.windowed and self._key_handler is None:
            toplevel = self.get_toplevel()
            if isinstance(toplevel, Gtk.Window):
                self._key_handler = (toplevel, toplevel.connect("key-press-event", self._key))

    def _unmapped(self, *_args: Any) -> None:
        if self._power_source:
            GLib.source_remove(self._power_source)
            self._power_source = 0
        if self._key_handler is not None:
            window, handler = self._key_handler
            if window.handler_is_connected(handler):
                window.disconnect(handler)
            self._key_handler = None
        farm = getattr(self.app, "farm", None)
        if farm is not None and self._farm_listener in farm.listeners:
            farm.listeners.remove(self._farm_listener)
        self._farm_listener = None

    def _sample_power(self) -> None:
        plug, controller = self._plug(), getattr(self.app, "smart_plugs", None)
        if plug is None or controller is None or not plug.meters:
            return
        secret = controller.store.secret(self.serial)

        def job() -> None:
            try:
                watts = plug.power(secret)
            except RuntimeError:
                watts = None
            if watts is not None:
                GLib.idle_add(lambda: (self._add_sample(watts), False)[1])
        threading.Thread(target=job, daemon=True).start()

    def _add_sample(self, watts: float) -> None:
        self.chart.append(watts)
        self.update()

    def _pointer_inside(self) -> bool:
        toplevel = self.get_toplevel()
        window = toplevel.get_window() if isinstance(toplevel, Gtk.Window) else None
        display = Gdk.Display.get_default()
        if window is None or display is None:
            return False
        _, px, py, _ = window.get_device_position(display.get_default_seat().get_pointer())
        origin = self.translate_coordinates(toplevel, 0, 0)
        if origin is None:
            return False
        ox, oy = origin
        return ox <= px < ox + self.get_allocated_width() and oy <= py < oy + self.get_allocated_height()

    def _key(self, window: Gtk.Window, event: Any) -> bool:
        """Arrow keys move the head only while the pointer is over this panel, so typing or scrolling
        elsewhere in the window never moves the printer."""
        if not self.get_mapped() or isinstance(window.get_focus(), Gtk.Entry):
            return False
        move = key_move(event.keyval, bool(event.state & Gdk.ModifierType.SHIFT_MASK))
        if move is None or not self._control_on() or not self._accepts_gcode() or not self._motion_safe():
            return False
        if not self._pointer_inside():
            return False
        if move == "home":
            self.app.home(self.serial)
        else:
            x, y, z = move
            self.app.jog(self.serial, x=x, y=y, z=z)
        return True


def key_move(keyval: int, shift: bool) -> tuple[float, float, float] | str | None:
    """What a key does over the panel: (x, y, z) in millimetres, "home", or None."""
    step = 10.0 if shift else 1.0
    moves = {Gdk.KEY_Left: (-step, 0.0, 0.0), Gdk.KEY_Right: (step, 0.0, 0.0),
             Gdk.KEY_Up: (0.0, step, 0.0), Gdk.KEY_Down: (0.0, -step, 0.0),
             Gdk.KEY_Page_Up: (0.0, 0.0, step), Gdk.KEY_Page_Down: (0.0, 0.0, -step)}
    if keyval in moves:
        return moves[keyval]
    if keyval in (Gdk.KEY_h, Gdk.KEY_H):
        return "home"
    return None


def send_lines(plate: dict[str, Any], note: str | None) -> list[str]:
    """What the send dialog says about a plate: time, filament, the AMS note and the slicing reminder."""
    lines: list[str] = []
    seconds = plate.get("seconds")
    if seconds:
        lines.append(i18n.t("Print time: {0}").format(f"{seconds // 3600} h {seconds % 3600 // 60:02d} min"))
    filaments = [f for f in plate.get("filaments") or [] if f.get("grams", 0) > 0]
    if filaments:
        lines.append(i18n.t("Filament: {0}").format(", ".join(f"{f['material']} {f['grams']:.0f} g" for f in filaments)))
    if note:
        lines.append(note)
    lines.append(i18n.t("Check that the file was sliced for this printer and nozzle."))
    return lines


def signing_notice_panel() -> str:
    return i18n.t("Controls are off: the printer only accepts commands signed by Bambu Connect. Turn on LAN Only mode and Developer Mode on the printer.")


def _rounded(cr: Any, x: float, y: float, w: float, h: float, r: float) -> None:
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 1.5 * math.pi)
    cr.close_path()
