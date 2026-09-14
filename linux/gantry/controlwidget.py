"""The GTK side of printer control: a setpoint capsule [ − | value | + ] driven by control.StepperModel.
Holding a button repeats, the command goes out once the value settles, and a change still pending when
the panel closes is sent then. gi is already pinned in app.py.
"""
from __future__ import annotations

import time
from typing import Any, Callable

from gi.repository import GLib, Gtk  # type: ignore

from . import i18n
from .control import (BUTTON_WIDTH, CAPSULE_HEIGHT, REPEAT_DELAY_MS, REPEAT_INTERVAL_MS, SETTLE_SECONDS,
                      StepperModel)


class ControlStepper(Gtk.Box):
    def __init__(self, model: StepperModel, target_caption: bool, suffix: str, on_commit: Callable[[int], Any],
                 format_value: Callable[[int], str] | None = None) -> None:
        super().__init__(spacing=0)
        self.model = model
        self.target_caption = target_caption
        self.suffix = suffix
        self.on_commit = on_commit
        self.format_value = format_value
        self._settle_source = 0
        self._repeat_source = 0
        self._repeated = False
        self.get_style_context().add_class("control-capsule")
        self.set_size_request(-1, CAPSULE_HEIGHT)
        self.minus = self._button("−", -1, i18n.t("Decrease"))
        self.plus = self._button("+", 1, i18n.t("Increase"))
        self.label = Gtk.Label(ellipsize=3)
        self.pack_start(self.minus, False, False, 0)
        self.pack_start(self.label, True, True, 0)
        self.pack_start(self.plus, False, False, 0)
        self.connect("destroy", self._on_destroy)
        self._render()

    def show_reported(self, value: Any) -> None:
        if self.model.show(value, time.monotonic()):
            self._render()

    # --- input ------------------------------------------------------------------------------------
    def _button(self, text: str, direction: int, name: str) -> Gtk.Button:
        button = Gtk.Button(label=text)
        button.set_relief(Gtk.ReliefStyle.NONE)
        button.set_size_request(BUTTON_WIDTH, CAPSULE_HEIGHT - 2)
        button.set_tooltip_text(name)
        button.get_style_context().add_class("control-step")
        button.connect("clicked", lambda *_: self._clicked(direction))
        button.connect("button-press-event", lambda *_: self._press(direction))
        button.connect("button-release-event", lambda *_: self._release())
        return button

    def _clicked(self, direction: int) -> None:
        # A held button already stepped while it repeated; the click that ends the hold is not another step.
        if self._repeated:
            self._repeated = False
            return
        self._nudge(direction)

    def _press(self, direction: int) -> bool:
        self._repeated = False
        self._cancel_repeat()
        self._repeat_source = GLib.timeout_add(REPEAT_DELAY_MS, self._start_repeat, direction)
        return False

    def _release(self) -> bool:
        self._cancel_repeat()
        return False

    def _start_repeat(self, direction: int) -> bool:
        self._repeat_source = GLib.timeout_add(REPEAT_INTERVAL_MS, self._repeat, direction)
        return False

    def _repeat(self, direction: int) -> bool:
        if not (self.model.can_increase if direction > 0 else self.model.can_decrease):
            self._repeat_source = 0
            return False
        self._repeated = True
        self._nudge(direction)
        return True

    def _cancel_repeat(self) -> None:
        if self._repeat_source:
            GLib.source_remove(self._repeat_source)
            self._repeat_source = 0

    # --- value ------------------------------------------------------------------------------------
    def _nudge(self, direction: int) -> None:
        self.model.nudge(direction)
        self._render()
        if self._settle_source:
            GLib.source_remove(self._settle_source)
        self._settle_source = GLib.timeout_add(int(SETTLE_SECONDS * 1000), self._settle)

    def _settle(self) -> bool:
        self._settle_source = 0
        self.on_commit(self.model.commit(time.monotonic()))
        return False

    def _on_destroy(self, *_args: Any) -> None:
        self._cancel_repeat()
        if self._settle_source:
            GLib.source_remove(self._settle_source)
            self._settle_source = 0
        # Closing the details right after a click must not swallow the change.
        if self.model.pending:
            self.on_commit(self.model.commit(time.monotonic()))

    def _render(self) -> None:
        value = self.model.value
        self.minus.set_sensitive(self.model.can_decrease)
        self.plus.set_sensitive(self.model.can_increase)
        off = self.target_caption and value == 0
        reading = i18n.t("Off").lower() if off else (self.format_value(value) if self.format_value else f"{value}{self.suffix}")
        caption = ""
        if self.target_caption:
            caption = f'<span size="small" alpha="70%">{GLib.markup_escape_text(i18n.t("Target").lower())} </span>'
        self.label.set_markup(f"{caption}<b>{GLib.markup_escape_text(reading)}</b>")
