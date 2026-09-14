"""Automations for the Linux app, the counterpart of the macOS/Windows engine: per-printer rules that
fire once per print when a condition first becomes true (at a layer, at a progress %, on a state) and
run an action (chamber light, pause/resume/stop, notification, a raw printer command, or a shell
script). Manual rules fire only from the Run button.

Safety mirrors macOS: the two code-running actions (raw command / shell script) are gated by an
off-by-default kill switch plus a one-time per-rule consent prompt, so a planted config cannot run
code silently. Pure Python (no GTK) so the model, store and trigger logic stay unit-testable.
"""
from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import threading
import uuid
from typing import Any, Callable

from . import i18n
from .core import PrinterKind, PrinterState, Telemetry

# Bambu MQTT command payloads (same as macOS).
_LIGHT_ON = ('{"system":{"sequence_id":"2003","command":"ledctrl","led_node":"chamber_light",'
             '"led_mode":"on","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0}}')
_LIGHT_OFF = _LIGHT_ON.replace('"led_mode":"on"', '"led_mode":"off"')
_PAUSE = '{"print":{"sequence_id":"2004","command":"pause"}}'
_RESUME = '{"print":{"sequence_id":"2004","command":"resume"}}'
_STOP = '{"print":{"sequence_id":"2004","command":"stop"}}'

TRIGGERS = ("manual", "at_layer", "at_progress", "on_state")
ACTIONS = ("light_on", "light_off", "pause", "resume", "stop", "notify", "command", "script")
_CODE_ACTIONS = ("command", "script")


def new_rule(name: str) -> dict[str, Any]:
    return {"id": str(uuid.uuid4()), "name": name, "enabled": True,
            "trigger": {"type": "manual", "value": None},
            "action": {"type": "light_off", "text": ""}}


def trigger_summary(rule: dict[str, Any], pl: bool) -> str:
    t = rule.get("trigger", {})
    kind, value = t.get("type", "manual"), t.get("value")
    if kind == "at_layer":
        return i18n.t("at layer {0}").format(value)
    if kind == "at_progress":
        return i18n.t("at {0}%").format(value)
    if kind == "on_state":
        return i18n.t("on state: {0}").format(state_label(value))
    return i18n.t("manually")


_STATE_KEYS = {"idle": "Ready", "ready": "Ready", "printing": "Printing", "paused": "Paused",
               "finished": "Finished", "error": "Error", "offline": "Offline"}


def state_label(value: Any) -> str:
    """A printer state as the user reads it, not its internal value."""
    return i18n.t(_STATE_KEYS.get(str(value).lower(), str(value)))


def start_script(content: str) -> tuple[subprocess.Popen, str | None]:
    """Starts a user script. One that begins with a shebang is written to a file of its own and run
    directly, so its interpreter is honoured, as on macOS; anything else runs through /bin/sh. Everything
    used to go to /bin/sh -c, so a Python script was read as shell. Returns the process and the temporary
    file to remove once it ends."""
    text = content.lstrip()
    if text.startswith("#!"):
        handle, path = tempfile.mkstemp(prefix="gantry-script-")
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(path, 0o700)
        try:
            return subprocess.Popen([path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True), path
        except OSError:
            os.unlink(path)
            raise
    return subprocess.Popen(["/bin/sh", "-c", content], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True), None


def action_summary(rule: dict[str, Any], pl: bool) -> str:
    label = {
        "light_on": "light on", "light_off": "light off", "pause": "pause", "resume": "resume",
        "stop": "stop", "notify": "notification", "command": "custom command", "script": "script",
    }.get(rule.get("action", {}).get("type", "light_off"), "")
    return i18n.t(label) if label else ""


class AutomationStore:
    """Per-printer rules kept in the app config (config.data['automations'])."""

    def __init__(self, config: Any) -> None:
        self.config = config

    def _all(self) -> dict[str, list[dict[str, Any]]]:
        data = self.config.data.get("automations")
        if not isinstance(data, dict):
            data = {}
            self.config.data["automations"] = data
        return data

    def for_printer(self, serial: str) -> list[dict[str, Any]]:
        return list(self._all().get(serial, []))

    def set_for_printer(self, serial: str, rules: list[dict[str, Any]]) -> None:
        self._all()[serial] = rules
        self.config.save()

    def upsert(self, serial: str, rule: dict[str, Any]) -> None:
        rules = self.for_printer(serial)
        for index, existing in enumerate(rules):
            if existing.get("id") == rule.get("id"):
                rules[index] = rule
                break
        else:
            rules.append(rule)
        self.set_for_printer(serial, rules)

    def delete(self, serial: str, rule_id: str) -> None:
        self.set_for_printer(serial, [r for r in self.for_printer(serial) if r.get("id") != rule_id])


def should_fire(rule: dict[str, Any], previous: Telemetry | None, current: Telemetry) -> bool:
    t = rule.get("trigger", {})
    kind, value = t.get("type", "manual"), t.get("value")
    if kind == "at_layer":
        try:
            n = int(value)
        except (TypeError, ValueError):
            return False
        prev_layer = (previous.current_layer or 0) if previous else 0
        return (current.current_layer or 0) >= n and prev_layer < n
    if kind == "at_progress":
        try:
            p = int(value)
        except (TypeError, ValueError):
            return False
        return current.progress >= p and (previous.progress if previous else -1) < p
    if kind == "on_state":
        prev_state = previous.state.value if previous else None
        return current.state.value == str(value) and prev_state != str(value)
    return False   # manual never auto-fires


class AutomationEngine:
    """Evaluates rules on each telemetry update and runs their actions. Fires once per print; re-arms at
    a clear end-of-print state (idle/finished) so a rule does not fire repeatedly mid-print."""

    def __init__(self, app: Any) -> None:
        self.app = app
        self.store = AutomationStore(app.config)
        self._fired: dict[str, set[str]] = {}
        self._scripts: dict[str, subprocess.Popen] = {}
        self._scripts_lock = threading.Lock()
        #: Called when a script starts or ends, from any thread; the window redraws its Run and Stop buttons.
        self.listeners: list[Callable[[], None]] = []

    # --- engine ---------------------------------------------------------------
    def evaluate(self, serial: str, previous: Telemetry | None, current: Telemetry) -> None:
        if current.state in (PrinterState.IDLE, PrinterState.FINISHED):
            self._fired[serial] = set()
        fired = self._fired.setdefault(serial, set())
        for rule in self.store.for_printer(serial):
            if not rule.get("enabled", True):
                continue
            if rule.get("id") in fired:
                continue
            if should_fire(rule, previous, current):
                fired.add(rule.get("id"))
                self.run(serial, rule)

    # --- actions --------------------------------------------------------------
    def run(self, serial: str, rule: dict[str, Any]) -> None:
        printer = next((p for p in self.app.printers if p.serial == serial), None)
        name = printer.name if printer else serial
        is_klipper = printer is not None and printer.kind == PrinterKind.KLIPPER
        action = rule.get("action", {})
        kind = action.get("type", "light_off")
        text = action.get("text", "")

        def printer_command(bambu: str, klipper_macro: str) -> None:
            if is_klipper:
                self.app.send_gcode(serial, klipper_macro)
            else:
                self.app.send_command(serial, bambu)

        if kind == "light_on":
            self.app.set_chamber_light(serial, True)
        elif kind == "light_off":
            self.app.set_chamber_light(serial, False)
        elif kind == "pause":
            printer_command(_PAUSE, "PAUSE")
        elif kind == "resume":
            printer_command(_RESUME, "RESUME")
        elif kind == "stop":
            printer_command(_STOP, "CANCEL_PRINT")
        elif kind == "notify":
            self.app.notify(name, text)
        elif kind in _CODE_ACTIONS:
            if not self._allow_code_action(rule, name):
                return
            if kind == "command":
                if is_klipper:
                    self.app.send_gcode(serial, text)
                else:
                    self.app.send_command(serial, text)
            else:
                self._run_script(name, rule, text)

    # --- scripts --------------------------------------------------------------
    def is_script_running(self, rule_id: str) -> bool:
        with self._scripts_lock:
            return rule_id in self._scripts

    def stop_script(self, rule_id: str) -> None:
        with self._scripts_lock:
            process = self._scripts.pop(rule_id, None)
        if process is None:
            return
        process.gantry_stopped = True  # type: ignore[attr-defined]
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        self._changed()

    def _changed(self) -> None:
        for listener in list(self.listeners):
            try:
                listener()
            except Exception:
                pass

    def _run_script(self, printer_name: str, rule: dict[str, Any], content: str) -> None:
        """Runs a script, keeps it stoppable from the Run button, and says when it fails. It used to run
        detached with every error and timeout swallowed while the notice claimed it had run."""
        rule_id, name = str(rule.get("id")), rule.get("name")
        self.stop_script(rule_id)
        try:
            process, temporary = start_script(content)
        except OSError as error:
            self.app.notify(printer_name, i18n.t("Could not start the script {0}: {1}").format(name, error))
            return
        with self._scripts_lock:
            self._scripts[rule_id] = process
        self._changed()
        self.app.notify(printer_name, i18n.t("Ran script: {0}").format(name))

        def watch() -> None:
            code = process.wait()
            if temporary:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
            with self._scripts_lock:
                # Only this run's own entry: a newer run under the same rule stays registered.
                if self._scripts.get(rule_id) is process:
                    del self._scripts[rule_id]
            if code != 0 and not getattr(process, "gantry_stopped", False):
                self.app.notify(printer_name, i18n.t("The script {0} failed with exit code {1}").format(name, code))
            self._changed()
        threading.Thread(target=watch, name="automation-script", daemon=True).start()

    # --- safety ---------------------------------------------------------------
    def _allow_code_action(self, rule: dict[str, Any], printer_name: str) -> bool:
        if not bool(self.app.config.data.get("allow_script_actions", False)):
            self.app.notify(printer_name,
                            (f"Pominięto „{rule.get('name')}” — akcje skryptowe/komendy są wyłączone (Ustawienia)."
                             if self.app.language == "pl"
                             else f"Skipped \"{rule.get('name')}\" — script/command actions are disabled (Settings)."))
            return False
        approved = self.app.config.data.get("approved_script_rules", [])
        if rule.get("id") in approved:
            return True
        # The consent prompt is a GTK dialog; ask the app to run it on the main thread and remember.
        if self.app.confirm_code_action(rule):
            approved = list(approved) + [rule.get("id")]
            self.app.config.data["approved_script_rules"] = approved
            self.app.config.save()
            return True
        return False


def light_payload(on: bool) -> str:
    return _LIGHT_ON if on else _LIGHT_OFF
