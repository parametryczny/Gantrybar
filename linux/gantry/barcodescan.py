"""Webcam barcode reading for Spoolbase, kept off the GTK main thread.

GStreamer state changes can take seconds, or never return, when a camera source misbehaves: a
source that fails with "Internal data stream error" may then hang the teardown. The scanner used to
start and stop its pipeline on the main thread, so a broken or missing camera froze every Gantry
window (Linux Mint feedback, 2026-09-16). Here every state change runs on a worker thread, callbacks
reach the UI through `dispatch`, and nothing arrives once the session is closed. No GTK imports, so
the flow is testable without a display.
"""
from __future__ import annotations

import glob
import threading
from typing import Any, Callable

VIDEO_DEVICES = "/dev/video*"


def camera_devices(pattern: str = VIDEO_DEVICES) -> list[str]:
    """Webcams on Linux are V4L2 devices, including the ones PipeWire also offers."""
    return sorted(glob.glob(pattern))


def camera_source(gst: Any, devices: list[str]) -> str | None:
    """A V4L2 source bound to the first camera. autovideosrc is only the fallback when the V4L2
    plugin is missing, because it may pick a desktop portal source that fails without a camera."""
    if not devices:
        return None
    if gst.ElementFactory.find("v4l2src") is not None:
        return f"v4l2src device={devices[0]}"
    if gst.ElementFactory.find("autovideosrc") is not None:
        return "autovideosrc"
    return None


def pipeline_description(source: str) -> str:
    # Leaky one-buffer queues: a slow preview or decoder drops frames instead of stalling the source.
    return (f"{source} ! videoconvert ! tee name=t "
            "t. ! queue leaky=downstream max-size-buffers=1 ! videoconvert ! video/x-raw,format=RGB ! "
            "appsink name=preview emit-signals=true max-buffers=1 drop=true sync=false "
            "t. ! queue leaky=downstream max-size-buffers=1 ! videoconvert ! zbar message=true ! "
            "fakesink sync=false")


class ScannerSession:
    """One camera session. `start` returns a message key when scanning cannot begin at all;
    `on_frame(data, width, height)`, `on_code(code)` and `on_error(message)` run through `dispatch`."""

    def __init__(self, gst: Any, *, on_frame: Callable[[bytes, int, int], None],
                 on_code: Callable[[str], None], on_error: Callable[[str], None],
                 dispatch: Callable[..., Any], devices: Callable[[], list[str]] = camera_devices) -> None:
        self.gst = gst
        self.on_frame, self.on_code, self.on_error = on_frame, on_code, on_error
        self.dispatch = dispatch
        self.devices = devices
        self.pipeline: Any | None = None
        self.closed = False
        self._lock = threading.Lock()

    # ---- lifecycle -----------------------------------------------------------------------------

    def start(self) -> str | None:
        gst = self.gst
        if gst is None:
            return "GStreamer support is unavailable."
        if gst.ElementFactory.find("zbar") is None:
            return "Barcode decoder missing. Install gstreamer1.0-plugins-bad."
        devices = self.devices()
        if not devices:
            return "No camera found. Type the code from the label into the search field."
        source = camera_source(gst, devices)
        if source is None:
            return "Could not start the camera."
        try:
            pipeline = gst.parse_launch(pipeline_description(source))
            pipeline.get_by_name("preview").connect("new-sample", self._new_sample)
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message", self._bus_message)
        except Exception:
            return "Could not start the camera."
        with self._lock:
            if self.closed:
                return None
            self.pipeline = pipeline
        threading.Thread(target=self._play, args=(pipeline,), name="gantry-scanner-start", daemon=True).start()
        return None

    def _play(self, pipeline: Any) -> None:
        if pipeline.set_state(self.gst.State.PLAYING) == self.gst.StateChangeReturn.FAILURE:
            self._post(self._fail, "Could not start the camera.")

    def stop(self) -> None:
        """Safe from any thread and any number of times; never waits for the camera."""
        with self._lock:
            if self.closed:
                return
            self.closed = True
            pipeline, self.pipeline = self.pipeline, None
        if pipeline is None:
            return
        try:
            pipeline.get_bus().remove_signal_watch()
        except Exception:
            pass
        threading.Thread(target=self._teardown, args=(pipeline,), name="gantry-scanner-stop", daemon=True).start()

    def _teardown(self, pipeline: Any) -> None:
        try:
            pipeline.set_state(self.gst.State.NULL)
        except Exception:
            pass

    # ---- callbacks -----------------------------------------------------------------------------

    def _post(self, callback: Callable[..., None], *args: Any) -> None:
        def run() -> bool:
            if not self.closed:
                callback(*args)
            return False
        self.dispatch(run)

    def _new_sample(self, sink: Any) -> Any:
        gst = self.gst
        if self.closed:
            return gst.FlowReturn.EOS
        sample = sink.emit("pull-sample")
        if sample is None:
            return gst.FlowReturn.ERROR
        caps = sample.get_caps().get_structure(0)
        width, height = caps.get_value("width"), caps.get_value("height")
        buffer = sample.get_buffer()
        self._post(self.on_frame, buffer.extract_dup(0, buffer.get_size()), width, height)
        return gst.FlowReturn.OK

    def _bus_message(self, _bus: Any, message: Any) -> None:
        self.handle_message(message)

    def handle_message(self, message: Any) -> None:
        """Runs on the main loop (bus signal watch)."""
        if self.closed:
            return
        gst = self.gst
        if message.type == gst.MessageType.ELEMENT:
            structure = message.get_structure()
            if structure is not None and structure.get_name() == "barcode":
                code = str(structure.get_value("symbol") or "").strip()
                if code:
                    self.stop()
                    self.on_code(code)
        elif message.type == gst.MessageType.ERROR:
            self._fail("The camera sends no picture. Close other apps using it, or type the code into the search field.")

    def _fail(self, message: str) -> None:
        self.stop()
        self.on_error(message)
