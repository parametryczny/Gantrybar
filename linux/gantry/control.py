"""Printer control shared by the Linux detail view and its tests: the setpoint model behind each capsule,
the commands it sends and the printer's replies. The same values as macOS ControlStepperView and Windows
ControlStepper (contract detailControls). Pure Python, no GTK.
"""
from __future__ import annotations

import json
from typing import Any

from . import i18n

CAPSULE_HEIGHT = 28
BUTTON_WIDTH = 26
RADIUS = 8
SETTLE_SECONDS = 0.6
ECHO_WINDOW_SECONDS = 6
REPEAT_DELAY_MS = 400
REPEAT_INTERVAL_MS = 70
#: Bambu reports fans in fifteenths of full speed, so 70% comes back as 67%.
FAN_ECHO_TOLERANCE = 7
#: How long a refused command stays on the card.
REJECTION_SECONDS = 120
CONTROL_COMMANDS = frozenset({"gcode_line", "print_speed"})


class StepperModel:
    """One setpoint the user nudges. Values snap to the step grid; while a change is still settling, and
    for a few seconds after it is sent, telemetry that still carries the old setpoint is ignored so the
    number does not jump back while the printer catches up."""

    def __init__(self, low: int, high: int, step: int, echo_tolerance: int = 0) -> None:
        self.low, self.high, self.step, self.echo_tolerance = low, high, step, echo_tolerance
        self.value = low
        self.pending = False
        self._ignore_until = 0.0

    def clamp(self, value: Any) -> int:
        return max(self.low, min(self.high, int(value)))

    @property
    def can_decrease(self) -> bool:
        return self.value > self.low

    @property
    def can_increase(self) -> bool:
        return self.value < self.high

    def nudge(self, direction: int) -> int:
        # Onto the step grid first, so 223° goes to 225° and 220°, not 228° and 218°.
        value, step = self.value, self.step
        target = (value // step + 1) * step if direction > 0 else ((value + step - 1) // step - 1) * step
        self.value = self.clamp(target)
        self.pending = True
        return self.value

    def commit(self, now: float) -> int:
        self.pending = False
        self._ignore_until = now + ECHO_WINDOW_SECONDS
        return self.value

    def show(self, reported: Any, now: float) -> bool:
        """The printer's own setpoint. Returns whether the shown value changed."""
        if self.pending:
            return False
        value = self.clamp(reported)
        if now < self._ignore_until:
            if abs(value - self.value) > self.echo_tolerance:
                return False
            self._ignore_until = 0.0
        changed = value != self.value
        self.value = value
        return changed


def gcode_line_payload(line: str) -> str:
    return json.dumps({"print": {"sequence_id": "2006", "command": "gcode_line", "param": line + "\n"}})


def speed_level_payload(level: int) -> str:
    """Bambu speed mode: 1 Silent, 2 Standard, 3 Sport, 4 Ludicrous. Bambu ignores M220 in a G-code line,
    which is why a percentage sent to one always came back as 100%."""
    return json.dumps({"print": {"sequence_id": "2004", "command": "print_speed", "param": str(max(1, min(4, int(level))))}})


def parse_command_reply(payload: bytes | str) -> dict[str, Any] | None:
    """A Bambu printer's answer to a control command: which command, whether it was taken and its reason
    when not. None for anything else, telemetry included. Mirrors macOS BambuCommandReply."""
    raw = payload if isinstance(payload, bytes) else payload.encode("utf-8", "replace")
    if b'"result"' not in raw:
        return None
    try:
        root = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(root, dict):
        return None
    for key in ("print", "system"):
        body = root.get(key)
        if not isinstance(body, dict):
            continue
        command, result = body.get("command"), body.get("result")
        if command not in CONTROL_COMMANDS or not isinstance(result, str):
            continue
        accepted = result.lower() in ("success", "ok")
        reason = body.get("reason") if isinstance(body.get("reason"), str) and body.get("reason") else None
        return {"command": command, "accepted": accepted, "reason": None if accepted else (reason or result)}
    return None


def rejection_message(reason: str) -> str:
    """Bambu firmware with authorization control answers "mqtt message verify failed" to any command not
    signed by Bambu Connect. Gantry does not sign, so the notice says what the printer needs."""
    if "verify failed" in reason.lower():
        return i18n.t("The printer only accepts commands signed by Bambu Connect. To control it from Gantry, turn on LAN Only mode and then Developer Mode on the printer.")
    return i18n.t("The printer rejected the command: {0}").format(reason)


def signing_notice() -> str:
    return i18n.t("Controls are off: the printer only accepts commands signed by Bambu Connect. Turn on LAN Only mode and then Developer Mode on the printer to control it from Gantry.")


# --- the control panel beside the details (macOS PrinterControlPanel) -------------------------------

#: The panel's width beside the details, the same as macOS PrinterControlPanelView.width.
PANEL_WIDTH = 420
#: Print actions and power while a print runs; sending a file and moving the head between prints.
BUSY_ORDER = ("print", "thermal", "power", "send", "motion")
IDLE_ORDER = ("send", "motion", "thermal", "print", "power")
#: How often the metering socket is read for the power chart, and how many samples it keeps.
POWER_SAMPLE_SECONDS = 3
POWER_SAMPLES = 100


def card_order(busy: bool) -> tuple[str, ...]:
    return BUSY_ORDER if busy else IDLE_ORDER


def is_motion_safe(state: Any) -> bool:
    """Motion is refused mid-print: a jog then would ruin the part, or worse, crash the nozzle into it."""
    from .core import PrinterState
    return state in (PrinterState.IDLE, PrinterState.FINISHED)


def takes_gcode(kind: Any, signing_required: bool) -> bool:
    """Kinds whose motion, temperatures and fans Gantry drives with G-code. A Bambu printer that only
    takes commands signed by Bambu Connect would refuse every one of them."""
    from .core import PrinterKind
    if kind in (PrinterKind.KLIPPER, PrinterKind.OCTOPRINT):
        return True
    return kind == PrinterKind.BAMBU and not signing_required


def jog_gcode(x: float = 0, y: float = 0, z: float = 0) -> str | None:
    """A relative move in millimetres, back to absolute afterwards. Z alone moves slower."""
    axes = [f"{name}{value:.2f}" for name, value in (("X", x), ("Y", y), ("Z", z)) if value]
    if not axes:
        return None
    feed = 600 if z and not x and not y else 3000
    return f"G91\nG1 {' '.join(axes)} F{feed}\nG90"


def home_gcode(axes: str = "") -> str:
    """G28 for the given axes, all of them when none are named."""
    names = " ".join(character for character in axes.upper() if character in "XYZ")
    return f"G28 {names}" if names else "G28"


def motion_row_visible(motion: bool, busy: bool, takes: bool) -> bool:
    """The jog pad folds away while it cannot be used: one line says why instead of a grid of dead buttons."""
    return motion or not (busy or not takes)
