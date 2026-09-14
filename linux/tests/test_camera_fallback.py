"""The production CameraView must leave a silent RTSPS pipeline for JPEG without an ERROR/EOS."""
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from gantry.core import PrinterKind
try:
    from gantry import camera
except ImportError:
    camera = None

@unittest.skipIf(camera is None, "GTK unavailable")
class CameraFallbackTests(unittest.TestCase):
    def test_no_first_frame_and_no_bus_error_still_reaches_jpeg(self):
        pipeline = Mock()
        pipeline.set_state.return_value = 1
        pipeline.get_bus.return_value.timed_pop_filtered.return_value = None
        element = Mock(); element.link.return_value = True
        gst = SimpleNamespace(Pipeline=SimpleNamespace(new=lambda _: pipeline),
            ElementFactory=SimpleNamespace(make=lambda *_: element),
            Caps=SimpleNamespace(from_string=lambda _: None),
            State=SimpleNamespace(PLAYING=1, NULL=0), StateChangeReturn=SimpleNamespace(FAILURE=0),
            FlowReturn=SimpleNamespace(OK=0), MSECOND=1,
            MessageType=SimpleNamespace(ERROR=1, EOS=2))
        view = SimpleNamespace(app=SimpleNamespace(language="en"), printer=SimpleNamespace(kind=PrinterKind.BAMBU),
            serial="test", camera_host="127.0.0.1", access_code="fixture", _received_frame=False,
            FIRST_FRAME_TIMEOUT=10, _pipeline=None, _set_status=Mock(), _set_badge=Mock(), _run_bambu_jpeg=Mock())
        view._run_bambu = lambda stop: camera.CameraView._run_bambu(view, stop)
        with patch.object(camera, "Gst", gst), patch.object(camera.time, "monotonic", side_effect=[100, 111]):
            camera.CameraView._run(view, threading.Event())
        view._run_bambu_jpeg.assert_called_once()
        self.assertIsNone(view._pipeline)
        pipeline.set_state.assert_called_with(0)
