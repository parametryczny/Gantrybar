"""Printer control on Linux: the setpoint model, the commands, the printer's replies and the Bambu
signing check (audit 2026-09-14: A24)."""
import json
import unittest
from types import SimpleNamespace

from gantry.control import (ECHO_WINDOW_SECONDS, FAN_ECHO_TOLERANCE, StepperModel, gcode_line_payload,
                            parse_command_reply, speed_level_payload)
from gantry.core import Printer, PrinterKind, Telemetry, parse_telemetry


class StepperModelTests(unittest.TestCase):
    def test_values_snap_to_the_step_grid_and_stay_in_range(self):
        model = StepperModel(0, 300, 5)
        model.show(223, now=0)
        self.assertEqual(model.nudge(1), 225)
        model.commit(now=0)
        model.show(223, now=100)
        self.assertEqual(model.nudge(-1), 220)
        low = StepperModel(0, 120, 5)
        self.assertEqual(low.nudge(-1), 0)
        self.assertFalse(low.can_decrease)
        self.assertTrue(low.can_increase)

    def test_old_telemetry_does_not_pull_the_value_back(self):
        model = StepperModel(0, 300, 5)
        model.show(220, now=0)
        model.nudge(1); model.nudge(1)
        self.assertFalse(model.show(220, now=0.1), "ignored while still settling")
        self.assertEqual(model.commit(now=1), 230)
        self.assertFalse(model.show(220, now=2), "stale setpoint ignored right after sending")
        self.assertEqual(model.value, 230)
        model.show(230, now=3)
        self.assertTrue(model.show(240, now=4), "after the echo the printer drives it again")

    def test_the_echo_window_ends_on_its_own(self):
        model = StepperModel(0, 300, 5)
        model.nudge(1)
        model.commit(now=0)
        self.assertTrue(model.show(0, now=ECHO_WINDOW_SECONDS + 1))
        self.assertEqual(model.value, 0)

    def test_fans_accept_bambus_rounded_echo(self):
        model = StepperModel(0, 100, 10, echo_tolerance=FAN_ECHO_TOLERANCE)
        model.show(60, now=0)
        model.nudge(1)
        model.commit(now=0)
        model.show(67, now=1)
        self.assertEqual(model.value, 67)


class CommandTests(unittest.TestCase):
    def test_payloads(self):
        self.assertEqual(json.loads(gcode_line_payload("M104 S220")),
                         {"print": {"sequence_id": "2006", "command": "gcode_line", "param": "M104 S220\n"}})
        self.assertEqual(json.loads(speed_level_payload(9))["print"]["param"], "4")

    def test_command_replies(self):
        self.assertEqual(parse_command_reply(b'{"print":{"command":"gcode_line","result":"success"}}'),
                         {"command": "gcode_line", "accepted": True, "reason": None})
        self.assertEqual(parse_command_reply(b'{"print":{"command":"print_speed","result":"failed","reason":"mqtt message verify failed"}}'),
                         {"command": "print_speed", "accepted": False, "reason": "mqtt message verify failed"})
        self.assertEqual(parse_command_reply(b'{"system":{"command":"gcode_line","result":"FAIL","reason":""}}')["reason"], "FAIL")
        self.assertIsNone(parse_command_reply(b'{"print":{"command":"pause","result":"success"}}'))
        self.assertIsNone(parse_command_reply(b'{"print":{"gcode_state":"RUNNING"}}'))

    def test_feature_mask_tells_whether_signed_commands_are_required(self):
        self.assertTrue(parse_telemetry(b'{"print":{"gcode_state":"IDLE","fun":"3EC1AFFF9CFF"}}').command_signing_required)
        self.assertFalse(parse_telemetry(b'{"print":{"gcode_state":"IDLE","fun":"3EC18FFF9CFF"}}').command_signing_required)
        self.assertIsNone(parse_telemetry(b'{"print":{"gcode_state":"IDLE"}}').command_signing_required)


try:
    from gantry import app as gantry_app
except Exception:  # pragma: no cover - GTK bindings missing on this host
    gantry_app = None


@unittest.skipIf(gantry_app is None, "gantry.app needs the GTK bindings")
class AppControlTests(unittest.TestCase):
    def _app(self):
        app = gantry_app.Gantry.__new__(gantry_app.Gantry)
        app.printers = [Printer("X1", "X1C", "10.0.0.5", kind=PrinterKind.BAMBU),
                        Printer("K1", "Voron", "10.0.0.7", kind=PrinterKind.KLIPPER)]
        app.telemetry = {"X1": Telemetry(), "K1": Telemetry()}
        app.sent_commands, app.sent_gcode = [], []
        app.send_command = lambda serial, text: (app.sent_commands.append((serial, json.loads(text))), True)[1]
        app.send_gcode = lambda serial, text: (app.sent_gcode.append((serial, text)), True)[1]
        app.detail_window = None
        return app

    def test_bambu_takes_gcode_lines_and_speed_modes(self):
        app = self._app()
        app.set_nozzle_temperature("X1", 220)
        app.set_fan("X1", 3, 70)
        app.set_print_speed_level("X1", 3)
        self.assertEqual([c[1]["print"]["command"] for c in app.sent_commands], ["gcode_line", "gcode_line", "print_speed"])
        self.assertEqual(app.sent_commands[0][1]["print"]["param"], "M104 S220\n")
        self.assertEqual(app.sent_commands[1][1]["print"]["param"], "M106 P3 S178\n")
        self.assertEqual(app.sent_commands[2][1]["print"]["param"], "3")

    def test_klipper_takes_gcode_and_only_the_part_fan(self):
        app = self._app()
        app.set_bed_temperature("K1", 60)
        app.set_fan("K1", 2, 50)
        app.set_fan("K1", 1, 50)
        app.set_print_speed("K1", 120)
        self.assertFalse(app.set_print_speed_level("K1", 3))
        # 50 % of 255 is 127.49999… in floating point, so 127, the same as macOS and Windows compute.
        self.assertEqual(app.sent_gcode, [("K1", "M140 S60"), ("K1", "M106 S127"), ("K1", "M220 S120")])

    def test_a_signing_refusal_blocks_controls_until_a_command_is_taken(self):
        app = self._app()
        app.set_nozzle_temperature("X1", 220)
        app.on_event("X1", "command_reply", {"command": "gcode_line", "accepted": False, "reason": "mqtt message verify failed"})
        self.assertTrue(app.requires_signed_commands("X1"))
        self.assertEqual(app.command_rejection("X1")["area"], "temperature")
        app.on_event("X1", "command_reply", {"command": "gcode_line", "accepted": True, "reason": None})
        self.assertFalse(app.requires_signed_commands("X1"))
        self.assertIsNone(app.command_rejection("X1"))

    def test_the_feature_mask_wins_over_a_remembered_refusal(self):
        app = self._app()
        app.on_event("X1", "command_reply", {"command": "gcode_line", "accepted": False, "reason": "mqtt message verify failed"})
        app.telemetry["X1"] = Telemetry(command_signing_required=False)
        self.assertFalse(app.requires_signed_commands("X1"))


if __name__ == "__main__":
    unittest.main()
