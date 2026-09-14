"""App-level flows through the real Gantry methods, with in-memory stand-ins for transports, dialogs and
user defaults (audit 2026-09-14: A01, A02, A08)."""
import threading
import time
import unittest
from datetime import datetime
from types import SimpleNamespace
from unittest import mock

try:
    from gantry import app as gantry_app
except Exception as error:  # pragma: no cover - GTK bindings missing on this host
    raise unittest.SkipTest(f"gantry.app needs the GTK bindings: {error}")

from gantry.core import Printer, PrinterKind, PrinterState, Telemetry
from gantry.startup import StartupState


def _app(printers):
    app = gantry_app.Gantry.__new__(gantry_app.Gantry)
    app.printers = printers
    return app


class ElegooCommandRoutingTests(unittest.TestCase):
    class Connection:
        def __init__(self):
            self.sent = []

        def send_method(self, method, params):
            self.sent.append((method, params))
            return True

    def routed(self, kind, payload):
        app = _app([Printer("E1", "Elegoo", "10.0.0.9", kind=kind)])
        connection = self.Connection()
        app.connections = {"E1": connection}
        return app.send_command("E1", payload), connection.sent

    def test_pause_resume_and_stop_reach_both_generations(self):
        for kind, codes in ((PrinterKind.ELEGOO_CC1, (129, 131, 130)),
                            (PrinterKind.ELEGOO_CC2, (1021, 1023, 1022))):
            for command, code in zip(("pause", "resume", "stop"), codes):
                with self.subTest(kind=kind, command=command):
                    ok, sent = self.routed(kind, f'{{"print":{{"command":"{command}"}}}}')
                    self.assertTrue(ok)
                    self.assertEqual(sent, [(code, {})])

    def test_raw_method_json_is_passed_through(self):
        ok, sent = self.routed(PrinterKind.ELEGOO_CC1, '{"method": 403, "params": {"LightStatus": {"SecondLight": 1}}}')
        self.assertTrue(ok)
        self.assertEqual(sent, [(403, {"LightStatus": {"SecondLight": 1}})])

    def test_malformed_or_unknown_commands_are_refused_without_sending(self):
        for payload in ('{not json', '{"print":{"command":"light"}}'):
            with self.subTest(payload=payload):
                ok, sent = self.routed(PrinterKind.ELEGOO_CC2, payload)
                self.assertFalse(ok)
                self.assertEqual(sent, [])


class QuietHoursTests(unittest.TestCase):
    @staticmethod
    def config(**values):
        return SimpleNamespace(data=values)

    def test_equal_start_and_end_silence_nothing(self):
        config = self.config(quiet_hours_enabled=True, quiet_hours_start="22:00", quiet_hours_end="22:00")
        for hour in (0, 12, 22):
            self.assertFalse(gantry_app.quiet_hours_active(config, datetime(2026, 9, 14, hour, 0)))

    def test_overnight_range(self):
        config = self.config(quiet_hours_enabled=True, quiet_hours_start="22:00", quiet_hours_end="07:00")
        self.assertTrue(gantry_app.quiet_hours_active(config, datetime(2026, 9, 14, 23, 30)))
        self.assertTrue(gantry_app.quiet_hours_active(config, datetime(2026, 9, 14, 6, 59)))
        self.assertFalse(gantry_app.quiet_hours_active(config, datetime(2026, 9, 14, 7, 0)))
        self.assertFalse(gantry_app.quiet_hours_active(config, datetime(2026, 9, 14, 12, 0)))

    def test_off_unless_switched_on(self):
        from gantry.storage import DEFAULTS
        self.assertFalse(DEFAULTS["quiet_hours_enabled"])
        self.assertFalse(gantry_app.quiet_hours_active(self.config(), datetime(2026, 9, 14, 23, 0)))


class FinishedPrintDuringQuietHoursTests(unittest.TestCase):
    def test_history_and_roll_accounting_run_while_the_alert_stays_silent(self):
        app = _app([Printer("X1", "Printer", "10.0.0.5", kind=PrinterKind.BAMBU)])
        app.startup = StartupState(["X1"])
        app.telemetry = {"X1": Telemetry(state=PrinterState.PRINTING, job_name="benchy")}
        app.connection_reasons = {}
        app.temp_history = {}
        app.insights = SimpleNamespace(observe=lambda *args: None)
        app.detail_window = None
        app.cards = {}
        app.language = "en"
        app.config = SimpleNamespace(data={"notify_finished": True})
        app.physical_spools = SimpleNamespace(detach_assignments_replaced_by_nfc=lambda *args: [])
        app._spoolbase_active = lambda: True
        app.dashboard_visible = lambda: False
        app._refresh_progress_indicators = lambda: None
        alerts = []
        app.notify = lambda title, body: alerts.append((title, body))

        finished = Telemetry(state=PrinterState.FINISHED, job_name="benchy")
        with mock.patch.object(gantry_app, "quiet_hours_active", return_value=True), \
                mock.patch("gantry.telegram.record_history") as history, \
                mock.patch("gantry.consumption.on_finish") as on_finish:
            app.on_event("X1", "telemetry", finished)

        history.assert_called_once_with(app, "X1", "Printer", "benchy")
        on_finish.assert_called_once()
        self.assertEqual(alerts, [], "quiet hours must still silence the alert")


class ConfirmCodeActionTests(unittest.TestCase):
    RULE = {"name": "Night light", "action": {"type": "script", "text": "echo hi"}}

    class Dialog:
        answer = None

        def __init__(self, **kwargs):
            pass

        def format_secondary_text(self, text):
            pass

        def add_button(self, text, response):
            pass

        def run(self):
            return type(self).answer

        def destroy(self):
            pass

    def setUp(self):
        self.app = _app([])
        self.app.language = "en"
        self.app.window = None
        self.Dialog.answer = gantry_app.Gtk.ResponseType.OK
        patcher = mock.patch.object(gantry_app.Gtk, "MessageDialog", self.Dialog)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_on_the_gtk_thread_the_dialog_answers_without_waiting(self):
        started = time.monotonic()
        with mock.patch.object(threading.Event, "wait", side_effect=AssertionError("waited on the GTK thread")):
            self.assertTrue(self.app.confirm_code_action(self.RULE))
        self.assertLess(time.monotonic() - started, 1.0)

    def test_a_denial_is_returned(self):
        self.Dialog.answer = gantry_app.Gtk.ResponseType.CANCEL
        self.assertFalse(self.app.confirm_code_action(self.RULE))

    def test_a_worker_thread_gets_the_answer_from_the_loop(self):
        from gi.repository import GLib
        outcome = {}
        with mock.patch.object(GLib, "idle_add", side_effect=lambda function, *args: function(*args)):
            worker = threading.Thread(target=lambda: outcome.setdefault("ok", self.app.confirm_code_action(self.RULE)))
            worker.start()
            worker.join(5)
        self.assertTrue(outcome.get("ok"))


if __name__ == "__main__":
    unittest.main()
