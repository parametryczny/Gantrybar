"""Automations window for the Linux app: list, add, edit, delete, enable and run per-printer rules,
the GTK counterpart of the macOS AutomationsWindow. Rule storage and the trigger engine live in the
gi-free automation.py; this module is only the UI.
"""
from __future__ import annotations

from typing import Any

from gi.repository import Gtk  # type: ignore  # noqa: E402

from . import i18n
from .automation import (ACTIONS, AutomationStore, TRIGGERS, action_summary, new_rule,
                         trigger_summary)
from .core import PrinterState

_STATE_CHOICES = [PrinterState.PRINTING.value, PrinterState.PAUSED.value, PrinterState.FINISHED.value,
                  PrinterState.ERROR.value, PrinterState.IDLE.value]


class AutomationsWindow(Gtk.Window):
    def __init__(self, app: Any, serial: str) -> None:
        super().__init__()
        self.app = app
        self.serial = serial
        self.store = AutomationStore(app.config)
        pl = app.language == "pl"
        printer = next((p for p in app.printers if p.serial == serial), None)
        name = printer.name if printer else serial

        self.set_title((i18n.t("Automations")) + f" · {name}")
        self.set_default_size(520, 480)
        self.set_transient_for(app.window)
        self.set_position(Gtk.WindowPosition.CENTER)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        root.set_border_width(12)
        self.add(root)

        head = Gtk.Box(spacing=8)
        title = Gtk.Label(xalign=0)
        title.set_markup(f"<b>{'Automatyzacje' if pl else 'Automations'}</b>  ·  {name}")
        head.pack_start(title, True, True, 0)
        add = Gtk.Button(label="＋ " + (i18n.t("New rule")))
        add.connect("clicked", lambda _b: self._edit(None))
        head.pack_start(add, False, False, 0)
        root.pack_start(head, False, False, 0)

        note = Gtk.Label(xalign=0, wrap=True)
        note.get_style_context().add_class("subtitle")
        note.set_text((i18n.t("Rules fire once per print when the condition first becomes true. The command and script actions require enabling in Settings and a one-time approval.")))
        root.pack_start(note, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        root.pack_start(scroll, True, True, 0)
        self.list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        scroll.add(self.list)
        self._render()

    def _pl(self) -> bool:
        return self.app.language == "pl"

    def _render(self) -> None:
        for child in self.list.get_children():
            self.list.remove(child)
        pl = self._pl()
        rules = self.store.for_printer(self.serial)
        if not rules:
            empty = Gtk.Label(label=(i18n.t("No rules yet. Add one with \"New\".")), xalign=0)
            empty.get_style_context().add_class("subtitle")
            self.list.pack_start(empty, False, False, 4)
        for rule in rules:
            self.list.pack_start(self._row(rule), False, False, 0)
        self.list.show_all()

    def _row(self, rule: dict[str, Any]) -> Gtk.Widget:
        pl = self._pl()
        frame = Gtk.Frame()
        frame.set_shadow_type(Gtk.ShadowType.NONE)
        frame.get_style_context().add_class("card")
        box = Gtk.Box(spacing=8)
        box.set_border_width(8)
        frame.add(box)

        toggle = Gtk.CheckButton()
        toggle.set_active(bool(rule.get("enabled", True)))
        toggle.connect("toggled", lambda b: self._set_enabled(rule, b.get_active()))
        box.pack_start(toggle, False, False, 0)

        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        title = Gtk.Label(label=rule.get("name", ""), xalign=0)
        title.get_style_context().add_class("printer-name")
        sub = Gtk.Label(xalign=0)
        sub.get_style_context().add_class("subtitle")
        sub.set_text(f"{trigger_summary(rule, pl)}  →  {action_summary(rule, pl)}")
        texts.pack_start(title, False, False, 0)
        texts.pack_start(sub, False, False, 0)
        box.pack_start(texts, True, True, 0)

        run = Gtk.Button(label=(i18n.t("Run")))
        run.connect("clicked", lambda _b: self.app.automations.run(self.serial, rule))
        box.pack_start(run, False, False, 0)
        edit = Gtk.Button(label=(i18n.t("Edit")))
        edit.connect("clicked", lambda _b: self._edit(rule))
        box.pack_start(edit, False, False, 0)
        delete = Gtk.Button(label="🗑")
        delete.connect("clicked", lambda _b: self._delete(rule))
        box.pack_start(delete, False, False, 0)
        return frame

    def _set_enabled(self, rule: dict[str, Any], enabled: bool) -> None:
        rule = dict(rule, enabled=enabled)
        self.store.upsert(self.serial, rule)

    def _delete(self, rule: dict[str, Any]) -> None:
        self.store.delete(self.serial, rule.get("id"))
        self._render()

    # --- editor ---------------------------------------------------------------
    def _edit(self, rule: dict[str, Any] | None) -> None:
        pl = self._pl()
        editing = rule is not None
        rule = dict(rule) if rule else new_rule(i18n.t("New rule"))
        dialog = Gtk.Dialog(title=(i18n.t("Rule")), transient_for=self, modal=True)
        dialog.set_default_size(420, -1)
        content = dialog.get_content_area()
        content.set_spacing(8)
        content.set_border_width(12)

        def labeled(text: str, widget: Gtk.Widget) -> None:
            row = Gtk.Box(spacing=8)
            lab = Gtk.Label(label=text, xalign=0)
            lab.set_size_request(110, -1)
            row.pack_start(lab, False, False, 0)
            row.pack_start(widget, True, True, 0)
            content.pack_start(row, False, False, 0)

        name_entry = Gtk.Entry()
        name_entry.set_text(rule.get("name", ""))
        labeled(i18n.t("Name"), name_entry)

        trigger_combo = Gtk.ComboBoxText()
        for key in TRIGGERS:
            trigger_combo.append(key, trigger_summary({"trigger": {"type": key, "value": "N"}}, pl).replace("N", "…"))
        trigger_combo.set_active_id(rule.get("trigger", {}).get("type", "manual"))
        labeled(i18n.t("Trigger"), trigger_combo)

        value_spin = Gtk.SpinButton.new_with_range(1, 100000, 1)
        tv = rule.get("trigger", {}).get("value")
        value_spin.set_value(float(tv) if isinstance(tv, (int, float, str)) and str(tv).isdigit() else 1)
        labeled(i18n.t("Value"), value_spin)

        state_combo = Gtk.ComboBoxText()
        for state in _STATE_CHOICES:
            state_combo.append(state, state)
        state_combo.set_active_id(rule.get("trigger", {}).get("value") if rule.get("trigger", {}).get("type") == "on_state" else PrinterState.FINISHED.value)
        labeled(i18n.t("State"), state_combo)

        action_combo = Gtk.ComboBoxText()
        for key in ACTIONS:
            action_combo.append(key, action_summary({"action": {"type": key}}, pl))
        action_combo.set_active_id(rule.get("action", {}).get("type", "light_off"))
        labeled(i18n.t("Action"), action_combo)

        text_entry = Gtk.Entry()
        text_entry.set_text(rule.get("action", {}).get("text", ""))
        text_entry.set_placeholder_text(i18n.t("text / command / script"))
        labeled(i18n.t("Text"), text_entry)

        def sync_visibility(*_a: Any) -> None:
            tk = trigger_combo.get_active_id()
            value_spin.set_visible(tk in ("at_layer", "at_progress"))
            state_combo.set_visible(tk == "on_state")
            ak = action_combo.get_active_id()
            text_entry.set_visible(ak in ("notify", "command", "script"))
        trigger_combo.connect("changed", sync_visibility)
        action_combo.connect("changed", sync_visibility)

        dialog.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
        dialog.add_button(i18n.t("Save"), Gtk.ResponseType.OK)
        dialog.show_all()
        sync_visibility()

        if dialog.run() == Gtk.ResponseType.OK:
            tk = trigger_combo.get_active_id() or "manual"
            value: Any = None
            if tk in ("at_layer", "at_progress"):
                value = int(value_spin.get_value())
            elif tk == "on_state":
                value = state_combo.get_active_id()
            rule["name"] = name_entry.get_text().strip() or (i18n.t("Rule"))
            rule["trigger"] = {"type": tk, "value": value}
            rule["action"] = {"type": action_combo.get_active_id() or "light_off", "text": text_entry.get_text()}
            self.store.upsert(self.serial, rule)
            self._render()
        dialog.destroy()
