"""A single line of text that scrolls to its end while hovered instead of being cut off.

The GNU/Linux counterpart of the macOS MarqueeLabel and the Windows MarqueeText, used for the printer name
and the file name on a card. Clipped at rest; while the pointer is over it the text slides to its end and
back, pausing at each end. Nothing moves unless someone points at it.
"""
from __future__ import annotations

from typing import Any

from gi.repository import Gdk, GLib, Gtk  # type: ignore


class MarqueeLabel(Gtk.EventBox):
    STEP = 0.7
    START_PAUSE = 18
    END_PAUSE = 22
    TICK_MS = 16

    def __init__(self, text: str = "", css_class: str | None = None) -> None:
        super().__init__()
        self.set_visible_window(False)
        self.set_above_child(True)
        self.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.label = Gtk.Label(label=text, xalign=0)
        if css_class:
            self.label.get_style_context().add_class(css_class)
        # EXTERNAL: scrollable without a scrollbar and without asking for the text's full width, so the
        # line gives way when room runs out and hugs its text when there is room.
        self._scroller = Gtk.ScrolledWindow()
        self._scroller.set_policy(Gtk.PolicyType.EXTERNAL, Gtk.PolicyType.NEVER)
        self._scroller.set_propagate_natural_width(True)
        self._scroller.set_propagate_natural_height(True)
        self._scroller.set_shadow_type(Gtk.ShadowType.NONE)
        self._scroller.get_style_context().add_class("marquee")
        self._scroller.add(self.label)
        self.add(self._scroller)
        self._source: int | None = None
        self._offset = 0.0
        self._direction = -1.0
        self._pause = 0
        self.connect("enter-notify-event", self._on_enter)
        self.connect("leave-notify-event", self._on_leave)
        self.connect("unmap", lambda *_: self._reset())   # never leave a timer running for a hidden card

    def set_text(self, text: str) -> None:
        if text != self.label.get_text():
            self.label.set_text(text)
            self._reset()

    def get_text(self) -> str:
        return self.label.get_text()

    def _overflow(self) -> float:
        adjustment = self._scroller.get_hadjustment()
        return max(0.0, adjustment.get_upper() - adjustment.get_page_size())

    def _on_enter(self, *_args: Any) -> bool:
        if self._source is None and self._overflow() > 4:
            self._pause = self.START_PAUSE
            self._source = GLib.timeout_add(self.TICK_MS, self._tick)
        return False

    def _on_leave(self, _widget: Any, event: Any) -> bool:
        if getattr(event, "detail", None) == Gdk.NotifyType.INFERIOR:
            return False
        self._reset()
        return False

    def _tick(self) -> bool:
        if self._pause > 0:
            self._pause -= 1
            return True
        limit = self._overflow()
        self._offset += self._direction * self.STEP
        if self._offset <= -limit:
            self._offset, self._direction, self._pause = -limit, 1.0, self.END_PAUSE
        elif self._offset >= 0:
            self._offset, self._direction, self._pause = 0.0, -1.0, self.END_PAUSE
        self._scroller.get_hadjustment().set_value(-self._offset)
        return True

    def _reset(self) -> None:
        if self._source is not None:
            GLib.source_remove(self._source)
            self._source = None
        self._offset, self._direction, self._pause = 0.0, -1.0, 0
        self._scroller.get_hadjustment().set_value(0)
