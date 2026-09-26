"""The Spoolbase barcode scanner must never freeze Gantry: a missing, busy or broken camera ends in a
message, and stopping never waits for GStreamer (Linux Mint feedback, 2026-09-16)."""
import threading
import time
import unittest
from types import SimpleNamespace

from gantry import barcodescan
from gantry.barcodescan import ScannerSession


class FakeElementFactory:
    def __init__(self, available):
        self.available = set(available)

    def find(self, name):
        return object() if name in self.available else None


class FakeBus:
    def __init__(self):
        self.watching = False
        self.handlers = []

    def add_signal_watch(self):
        self.watching = True

    def remove_signal_watch(self):
        self.watching = False

    def connect(self, _signal, handler):
        self.handlers.append(handler)


class FakePipeline:
    """set_state blocks until released, like a camera source that hangs on teardown."""

    def __init__(self, gst):
        self.gst = gst
        self.bus = FakeBus()
        self.sink = SimpleNamespace(connect=lambda *_args: None)
        self.release = threading.Event()
        self.states = []

    def get_by_name(self, _name):
        return self.sink

    def get_bus(self):
        return self.bus

    def set_state(self, state):
        self.states.append(state)
        if state == self.gst.State.NULL:
            self.release.wait(10)
        return self.gst.play_result


def fake_gst(available=("zbar", "v4l2src", "autovideosrc"), play_result="ok"):
    gst = SimpleNamespace(
        ElementFactory=FakeElementFactory(available),
        State=SimpleNamespace(PLAYING="playing", NULL="null"),
        StateChangeReturn=SimpleNamespace(FAILURE="failure"),
        MessageType=SimpleNamespace(ELEMENT="element", ERROR="error"),
        FlowReturn=SimpleNamespace(OK="ok", EOS="eos", ERROR="error"),
        play_result=play_result,
        launched=[],
    )

    def parse_launch(description):
        gst.launched.append(description)
        gst.pipeline = FakePipeline(gst)
        return gst.pipeline
    gst.parse_launch = parse_launch
    return gst


def barcode(symbol):
    structure = SimpleNamespace(get_name=lambda: "barcode", get_value=lambda _key: symbol)
    return SimpleNamespace(type="element", get_structure=lambda: structure)


class ScannerSessionTests(unittest.TestCase):
    def session(self, gst, devices=("/dev/video0",)):
        self.frames, self.codes, self.errors = [], [], []
        return ScannerSession(gst, on_frame=lambda *args: self.frames.append(args),
                              on_code=self.codes.append, on_error=self.errors.append,
                              dispatch=lambda callback: callback(), devices=lambda: list(devices))

    def test_missing_pieces_are_reported_without_building_a_pipeline(self):
        self.assertEqual(self.session(None).start(), "GStreamer support is unavailable.")
        gst = fake_gst(available=("v4l2src",))
        self.assertEqual(self.session(gst).start(), "Barcode decoder missing. Install gstreamer1.0-plugins-bad.")
        gst = fake_gst()
        self.assertEqual(self.session(gst, devices=()).start(),
                         "No camera found. Type the code from the label into the search field.")
        self.assertEqual(gst.launched, [])

    def test_prefers_the_first_v4l2_camera_over_autovideosrc(self):
        gst = fake_gst()
        self.assertEqual(barcodescan.camera_source(gst, ["/dev/video2", "/dev/video3"]), "v4l2src device=/dev/video2")
        self.assertEqual(barcodescan.camera_source(fake_gst(available=("autovideosrc",)), ["/dev/video0"]),
                         "autovideosrc")
        self.assertIsNone(barcodescan.camera_source(gst, []))

    def test_start_and_stop_never_wait_for_the_camera(self):
        gst = fake_gst()
        session = self.session(gst)
        started = time.monotonic()
        self.assertIsNone(session.start())
        session.stop()
        session.stop()
        self.assertLess(time.monotonic() - started, 1.0)  # teardown is still blocked in its thread
        self.assertTrue(session.closed)
        self.assertFalse(gst.pipeline.bus.watching)
        gst.pipeline.release.set()

    def test_camera_error_stops_the_session_and_reports_once(self):
        gst = fake_gst()
        session = self.session(gst)
        session.start()
        error = SimpleNamespace(type="error")
        session.handle_message(error)
        session.handle_message(error)
        gst.pipeline.release.set()
        self.assertEqual(len(self.errors), 1)
        self.assertIn("camera sends no picture", self.errors[0])
        self.assertTrue(session.closed)

    def test_failed_play_is_reported(self):
        gst = fake_gst(play_result="failure")
        session = self.session(gst)
        session.start()
        deadline = time.monotonic() + 2
        while not self.errors and time.monotonic() < deadline:
            time.sleep(0.01)
        gst.pipeline.release.set()
        self.assertEqual(self.errors, ["Could not start the camera."])

    def test_first_code_wins_and_nothing_arrives_after_close(self):
        gst = fake_gst()
        session = self.session(gst)
        session.start()
        session.handle_message(barcode("GFA00-K0"))
        session.handle_message(barcode("OTHER"))
        gst.pipeline.release.set()
        self.assertEqual(self.codes, ["GFA00-K0"])
        sink = SimpleNamespace(emit=lambda _name: self.fail("closed session must not pull samples"))
        self.assertEqual(session._new_sample(sink), "eos")


class ScannerMessagesTests(unittest.TestCase):
    def test_every_session_message_is_in_the_polish_catalog(self):
        """The dialog passes these through i18n.t(message), which the catalog check cannot see."""
        import json
        import re
        from pathlib import Path
        root = Path(__file__).resolve().parents[2]
        catalog = json.loads((root / "i18n" / "pl.json").read_text(encoding="utf-8"))
        source = (root / "linux" / "gantry" / "barcodescan.py").read_text(encoding="utf-8")
        messages = set(re.findall(r'(?:return|_fail\(|_post\(self\._fail, )\s*"([^"]+\.)"', source))
        self.assertGreaterEqual(len(messages), 5)
        self.assertEqual(sorted(message for message in messages if message not in catalog), [])


class RealGStreamerTests(unittest.TestCase):
    """On CI the Debian job has GStreamer with v4l2src and zbar: a camera path that cannot open must
    end in an error and a stop that returns at once."""

    def test_unopenable_camera_reports_and_stops_quickly(self):
        try:
            import gi
            gi.require_version("Gst", "1.0")
            from gi.repository import Gst
            Gst.init(None)
        except (ImportError, ValueError) as error:
            self.skipTest(f"GStreamer bindings missing: {error}")
        if Gst.ElementFactory.find("zbar") is None or Gst.ElementFactory.find("v4l2src") is None:
            self.skipTest("zbar or v4l2src plugin missing")
        errors = []
        session = ScannerSession(Gst, on_frame=lambda *_args: None, on_code=lambda _code: None,
                                 on_error=errors.append, dispatch=lambda callback: callback(),
                                 devices=lambda: ["/dev/gantry-missing-camera"])
        self.assertIsNone(session.start())
        deadline = time.monotonic() + 10
        while not errors and time.monotonic() < deadline:
            time.sleep(0.05)
        started = time.monotonic()
        session.stop()
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual(errors, ["Could not start the camera."])


if __name__ == "__main__":
    unittest.main()
