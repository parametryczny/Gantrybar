import json
import unittest
import urllib.parse
from types import SimpleNamespace

from gantry.core import PrinterState, Telemetry
from gantry.smartplug import SmartPlug, SmartPlugController, parse_state


def _query(request):
    return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(request.full_url).query))


class RequestTests(unittest.TestCase):
    def test_tasmota_outlet_and_login(self):
        plug = SmartPlug(kind="tasmota", host="192.168.1.60", channel=3, username="admin")
        off = plug.request(False, "s3cret")
        self.assertEqual(urllib.parse.urlsplit(off.full_url).path, "/cm")
        self.assertEqual(_query(off)["cmnd"], "Power3 Off")
        self.assertEqual(_query(off)["password"], "s3cret")
        self.assertEqual(_query(plug.request(None, None))["cmnd"], "Power3")
        self.assertIs(parse_state("tasmota", 3, '{"POWER3":"OFF"}'), False)
        self.assertIs(parse_state("tasmota", 1, '{"POWER":"ON"}'), True)

    def test_shelly_relays_count_from_zero(self):
        gen1 = SmartPlug(kind="shelly", host="http://10.0.0.5/", channel=2)
        self.assertEqual(gen1.request(True, None).full_url, "http://10.0.0.5/relay/1?turn=on")
        gen2 = SmartPlug(kind="shellyRPC", host="10.0.0.6")
        self.assertEqual(gen2.request(False, None).full_url, "http://10.0.0.6/rpc/Switch.Set?id=0&on=false")
        self.assertIs(parse_state("shellyRPC", 1, '{"id":0,"output":true}'), True)
        self.assertIs(parse_state("shelly", 2, '{"ison":false}'), False)

    def test_home_assistant_posts_entity_with_token(self):
        plug = SmartPlug(kind="homeAssistant", host="http://ha.local:8123", entityID="switch.p1s")
        request = plug.request(True, "TOKEN")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, "http://ha.local:8123/api/services/homeassistant/turn_on")
        self.assertEqual(request.get_header("Authorization"), "Bearer TOKEN")
        self.assertEqual(json.loads(request.data), {"entity_id": "switch.p1s"})
        self.assertTrue(plug.request(None, "TOKEN").full_url.endswith("/api/states/switch.p1s"))
        self.assertIs(parse_state("homeAssistant", 1, '{"state":"on"}'), True)

    def test_incomplete_sockets_say_what_is_missing(self):
        self.assertIsNotNone(SmartPlug(kind="tasmota").problem)
        self.assertIsNotNone(SmartPlug(kind="homeAssistant", host="http://ha:8123").problem)
        self.assertIsNone(SmartPlug(kind="homeAssistant", host="http://ha:8123", entityID="switch.x").problem)
        self.assertIsNone(SmartPlug(kind="http", onURL="http://x/on", offURL="http://x/off").problem)
        self.assertIsNone(SmartPlug(kind="http", onURL="http://x/on", offURL="http://x/off").request(None, None))

    def test_shared_json_shape(self):
        plug = SmartPlug.from_dict({"kind": "shelly", "host": "10.0.0.5", "channel": 0})
        self.assertEqual(plug.channel, 1)
        self.assertTrue(plug.includeInEmergency)
        self.assertEqual(SmartPlug.from_dict({"kind": "zigbee2mqtt"}).kind, "http")
        self.assertNotIn("entityID", plug.to_dict())


class _Secrets:
    def __init__(self):
        self.values = {}

    def get(self, key):
        return self.values.get(key)

    def set(self, key, value):
        self.values[key] = value

    def delete(self, key):
        self.values.pop(key, None)


def _app(plugs):
    config = SimpleNamespace(data={"smart-plugs-v1": plugs}, save=lambda: None)
    return SimpleNamespace(config=config, secrets=_Secrets(),
                           printers=[SimpleNamespace(serial="A", name="Alfa"), SimpleNamespace(serial="B", name="Beta")],
                           telemetry={"A": Telemetry(), "B": Telemetry()})


class ControllerTests(unittest.TestCase):
    def test_auto_off_arms_on_finish_and_cancels_on_new_print(self):
        app = _app({"A": {"kind": "tasmota", "host": "1.2.3.4", "autoOffMinutes": 5}})
        scheduled, cancelled = [], []
        controller = SmartPlugController(app, notify=lambda *_: None, telegram=lambda *_: None,
                                         run_async=lambda job: None,
                                         schedule=lambda seconds, fn: scheduled.append((seconds, fn)) or len(scheduled),
                                         cancel=cancelled.append)
        controller.observe("A", PrinterState.PRINTING)
        controller.observe("A", PrinterState.FINISHED)
        self.assertEqual([s for s, _ in scheduled], [300])
        controller.observe("A", PrinterState.FINISHED)
        self.assertEqual(len(scheduled), 1, "the same finish must not arm twice")
        controller.observe("A", PrinterState.PRINTING)
        self.assertEqual(cancelled, [1])
        controller.observe("B", PrinterState.FINISHED)
        self.assertEqual(len(scheduled), 1, "a printer without a socket arms nothing")

    def test_store_keeps_secret_out_of_config(self):
        app = _app({})
        controller = SmartPlugController(app, notify=lambda *_: None, telegram=lambda *_: None)
        controller.store.set("A", SmartPlug(kind="homeAssistant", host="http://ha", entityID="switch.a"), "TOKEN")
        self.assertNotIn("TOKEN", json.dumps(app.config.data))
        self.assertEqual(controller.store.secret("A"), "TOKEN")
        controller.store.set("A", None, None)
        self.assertIsNone(controller.store.secret("A"))
        self.assertTrue(controller.store.is_empty())

    def test_power_without_socket_says_so(self):
        messages = []
        controller = SmartPlugController(_app({}), notify=lambda title, body: messages.append(body),
                                         telegram=lambda *_: None)
        controller.power(False, "A")
        self.assertEqual(len(messages), 1)


if __name__ == "__main__":
    unittest.main()


class LiveHttpTests(unittest.TestCase):
    """Against a local stand-in socket, so the real urllib path (and its errors) is exercised."""

    def _serve(self, handler_body):
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                handler_body(self)

            def log_message(self, *_args):
                pass
        server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return f"127.0.0.1:{server.server_address[1]}"

    def test_tasmota_switch_reports_state(self):
        seen = []

        def reply(handler):
            seen.append(handler.path)
            body = b'{"POWER2":"OFF"}'
            handler.send_response(200); handler.send_header("Content-Length", str(len(body))); handler.end_headers()
            handler.wfile.write(body)
        host = self._serve(reply)
        self.assertIs(SmartPlug(kind="tasmota", host=host, channel=2).send(False, None), False)
        self.assertIn("cmnd=Power2%20Off", seen[0])

    def test_shelly_login_is_answered_and_refusal_is_explained(self):
        import base64

        def reply(handler):
            expected = "Basic " + base64.b64encode(b"admin:pw").decode()
            if handler.headers.get("Authorization") != expected:
                handler.send_response(401); handler.send_header("WWW-Authenticate", 'Basic realm="shelly"')
                handler.send_header("Content-Length", "0"); handler.end_headers(); return
            body = b'{"ison":true}'
            handler.send_response(200); handler.send_header("Content-Length", str(len(body))); handler.end_headers()
            handler.wfile.write(body)
        host = self._serve(reply)
        self.assertIs(SmartPlug(kind="shelly", host=host).send(True, "pw"), True)
        with self.assertRaises(RuntimeError):
            SmartPlug(kind="shelly", host=host).send(True, None)

    def test_emergency_switches_every_marked_socket_and_reports_failures(self):
        def reply(handler):
            body = b'{"POWER1":"OFF"}'
            handler.send_response(200); handler.send_header("Content-Length", str(len(body))); handler.end_headers()
            handler.wfile.write(body)
        host = self._serve(reply)
        app = _app({"A": {"kind": "tasmota", "host": host},
                    "B": {"kind": "tasmota", "host": "127.0.0.1:1"},
                    "C": {"kind": "tasmota", "host": host, "includeInEmergency": False}})
        app.printers.append(SimpleNamespace(serial="C", name="Gamma"))
        sent = []
        controller = SmartPlugController(app, notify=lambda *_: None, telegram=lambda *args: sent.append(args))
        lines = controller.emergency_off()
        self.assertEqual(lines[0], "✓ Alfa")
        self.assertTrue(lines[1].startswith("✕ Beta"))
        self.assertEqual(len(lines), 2, "a socket left out of emergencies is not touched")
        self.assertEqual(len(sent), 1)
