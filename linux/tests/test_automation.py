import unittest

from gantry.automation import AutomationEngine, AutomationStore, new_rule, should_fire
from gantry.core import PrinterKind, Printer, Telemetry, PrinterState


class _Config:
    def __init__(self):
        self.data = {"automations": {}, "allow_script_actions": False, "approved_script_rules": []}
        self.saved = 0

    def save(self):
        self.saved += 1


class _App:
    """Minimal stand-in for the Gantry app: records the commands the engine would send."""
    def __init__(self):
        self.config = _Config()
        self.language = "en"
        self.printers = [Printer("X1", "Printer", "10.0.0.5", kind=PrinterKind.BAMBU)]
        self.sent_commands = []
        self.sent_gcode = []
        self.lights = []
        self.notes = []

    def send_command(self, serial, json_str):
        self.sent_commands.append((serial, json_str)); return True

    def send_gcode(self, serial, script):
        self.sent_gcode.append((serial, script)); return True

    def set_chamber_light(self, serial, on):
        self.lights.append((serial, on))

    def notify(self, name, text):
        self.notes.append((name, text))

    def confirm_code_action(self, rule):
        return False   # deny by default in tests


class ShouldFireTests(unittest.TestCase):
    def test_at_layer_edge(self):
        rule = {"trigger": {"type": "at_layer", "value": 5}}
        prev = Telemetry(current_layer=4)
        cur = Telemetry(current_layer=5)
        self.assertTrue(should_fire(rule, prev, cur))
        self.assertFalse(should_fire(rule, cur, Telemetry(current_layer=6)))  # already past

    def test_at_progress_and_state(self):
        self.assertTrue(should_fire({"trigger": {"type": "at_progress", "value": 50}},
                                    Telemetry(progress=49), Telemetry(progress=50)))
        self.assertTrue(should_fire({"trigger": {"type": "on_state", "value": "finished"}},
                                    Telemetry(state=PrinterState.PRINTING),
                                    Telemetry(state=PrinterState.FINISHED)))
        self.assertFalse(should_fire({"trigger": {"type": "manual", "value": None}}, None, Telemetry()))


class EngineTests(unittest.TestCase):
    def test_fires_once_per_print_and_rearms(self):
        app = _App()
        engine = AutomationEngine(app)
        rule = new_rule("light at 10")
        rule["trigger"] = {"type": "at_layer", "value": 10}
        rule["action"] = {"type": "light_on", "text": ""}
        engine.store.upsert("X1", rule)
        engine.evaluate("X1", Telemetry(current_layer=9, state=PrinterState.PRINTING),
                        Telemetry(current_layer=10, state=PrinterState.PRINTING))
        self.assertEqual(app.lights, [("X1", True)])
        # Does not fire again the same print.
        engine.evaluate("X1", Telemetry(current_layer=10, state=PrinterState.PRINTING),
                        Telemetry(current_layer=11, state=PrinterState.PRINTING))
        self.assertEqual(len(app.lights), 1)
        # Re-arms at finish, then fires on the next print.
        engine.evaluate("X1", Telemetry(state=PrinterState.PRINTING), Telemetry(state=PrinterState.FINISHED))
        engine.evaluate("X1", Telemetry(current_layer=9, state=PrinterState.PRINTING),
                        Telemetry(current_layer=10, state=PrinterState.PRINTING))
        self.assertEqual(len(app.lights), 2)

    def test_script_blocked_without_optin(self):
        app = _App()
        engine = AutomationEngine(app)
        rule = new_rule("danger")
        rule["action"] = {"type": "script", "text": "echo hi"}
        engine.run("X1", rule)
        self.assertEqual(app.notes and app.notes[0][0], "Printer")   # a "skipped" note, no execution

    def test_disabled_rule_skipped(self):
        app = _App()
        engine = AutomationEngine(app)
        rule = new_rule("off")
        rule["enabled"] = False
        rule["trigger"] = {"type": "at_progress", "value": 1}
        rule["action"] = {"type": "light_on"}
        engine.store.upsert("X1", rule)
        engine.evaluate("X1", Telemetry(progress=0), Telemetry(progress=100))
        self.assertEqual(app.lights, [])


if __name__ == "__main__":
    unittest.main()
