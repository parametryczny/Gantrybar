"""Live camera view for the Linux dashboard, matching the macOS/Windows Details camera:

  - Bambu: the printer's local RTSPS stream, decoded in-process by GStreamer. Credentials are passed
    as rtspsrc properties and never exposed in a child process command line. Requires the printer's
    "LAN Mode Live View" toggle.
  - Klipper / Moonraker and other MJPEG cameras: the multipart JPEG stream read directly in pure
    Python (no ffmpeg), so a webcam works even without the decoder installed.

Frames are JPEGs either way; each is handed to GdkPixbuf and drawn into a Gtk.Image. All network/decoder
work happens on a worker thread; the UI is only touched via GLib.idle_add.
"""
from __future__ import annotations

import json
import threading
import time
import urllib.request
from typing import Any

import gi

gi.require_version("GdkPixbuf", "2.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import GdkPixbuf, GLib, Gtk  # type: ignore  # noqa: E402

from . import i18n
from .core import PrinterKind
from .jpegstream import bambu_jpeg_frames, ensure_huffman_tables, split_jpegs
from .overrides import overrides_for

try:
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst  # type: ignore  # noqa: E402
    Gst.init(None)
except (ImportError, ValueError):
    Gst = None  # type: ignore[assignment]


#: Brands whose stream Gantry can decode. Anything else would only ever show a black rectangle, so it is
#: never offered a picture. The same list as macOS CameraFeedController and Windows DockCameraFeed.
CAMERA_KINDS = frozenset({PrinterKind.BAMBU, PrinterKind.KLIPPER, PrinterKind.ELEGOO_CC1,
                          PrinterKind.ELEGOO_CC2, PrinterKind.ANYCUBIC_KOBRA_S1})

#: The edge dock draws a picture at most 300 px wide; a 1080p frame scaled on every draw is waste.
SINK_FRAME_WIDTH = 640


def supports_camera(kind: Any) -> bool:
    return kind in CAMERA_KINDS


def elegoo_video_refusal(ack: int | None) -> str | None:
    """Cmd 386 Ack: 0 started, 1 too many viewers, 2 no camera, 3 unknown. No answer at all (older firmware,
    a socket still connecting) is not a refusal, so the stream is tried anyway."""
    if ack is None or ack == 0:
        return None
    if ack == 1:
        return i18n.t("The printer allows one camera viewer at a time. Close the camera in Elegoo Slicer or the Elegoo app, or restart the printer.")
    if ack == 2:
        return i18n.t("The printer reports that it has no camera.")
    return i18n.t("The printer could not start the camera (code {0}).").format(ack)


class CameraView(Gtk.Box):
    # A feed that worked and then went quiet is restarted, with a growing delay so a camera that is
    # genuinely gone is not hammered. Matches the macOS CameraFeedController watchdog.
    FIRST_FRAME_TIMEOUT = 10.0
    #: A printer that has just been told to start its camera can take a moment to serve it, so an MJPEG
    #: stream that has not produced a picture yet is retried before the failure is shown.
    MJPEG_ATTEMPTS = 3
    DECODE_FAILURES_BEFORE_NOTICE = 5
    MINIMUM_RESTART_DELAY = 8.0
    MAXIMUM_RESTART_DELAY = 30.0
    WATCHDOG_INTERVAL_MS = 2000

    def __init__(self, app: Any, serial: str, access_code: str | None) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.app = app
        self.serial = serial
        self.access_code = access_code or ""
        self.printer = next((p for p in app.printers if p.serial == serial), None)
        self.camera_host = overrides_for(app.config, serial).get("cameraHost") or \
            (self.printer.host if self.printer is not None else "")
        self._stop = threading.Event()
        self._pipeline: Any | None = None
        self._running = False
        self._received_frame = False
        self._decode_failures = 0
        self._last_frame_at = time.monotonic()
        self._last_healthy_reset = time.monotonic()
        self._restart_delay = CameraView.MINIMUM_RESTART_DELAY
        self._watchdog_generation = 0
        #: When set, decoded frames go here instead of into this view's own image. The edge dock uses
        #: it to draw pictures inside its own silhouette with the same streams and watchdog.
        self.frame_sink: Any | None = None
        pl = app.language == "pl"

        self.set_border_width(2)
        self.image = Gtk.Image()
        self.image.set_size_request(420, 230)
        frame = Gtk.EventBox()
        frame.get_style_context().add_class("card")
        frame.add(self.image)
        self.pack_start(frame, True, True, 0)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("subtitle")
        self.status.set_text(i18n.t("Connecting to camera…"))
        self.pack_start(self.status, False, False, 0)
        self.badge = Gtk.Label(xalign=0)
        self.badge.get_style_context().add_class("meta")
        self.pack_start(self.badge, False, False, 0)

        self.connect("destroy", self._on_destroy)

    # --- lifecycle ------------------------------------------------------------
    def start(self) -> None:
        if self._running:
            return
        self._running = True
        # A fresh event per run, not a cleared one: a worker from the previous run keeps the event it
        # was started with, which stays set, so it can never push frames into the new run.
        stop = threading.Event()
        self._stop = stop
        self._received_frame = False
        self._decode_failures = 0
        self._last_frame_at = time.monotonic()
        threading.Thread(target=self._run, args=(stop,),
                         name=f"camera-{self.serial}", daemon=True).start()
        self._arm_watchdog()

    def stop(self) -> None:
        self._running = False
        self._watchdog_generation += 1  # any armed watchdog tick is now stale
        self._stop.set()
        pipeline = self._pipeline
        if pipeline is not None and Gst is not None:
            try:
                pipeline.set_state(Gst.State.NULL)
            except Exception:
                pass

    def _arm_watchdog(self) -> None:
        self._watchdog_generation += 1
        generation = self._watchdog_generation
        GLib.timeout_add(CameraView.WATCHDOG_INTERVAL_MS,
                         lambda: self._check_for_silence(generation))

    def _check_for_silence(self, generation: int) -> bool:
        """Restarts a feed that produced frames and then stopped. A feed that never produced one is
        left to the status label: restarting it would not help and would only churn the network."""
        if not self._running or generation != self._watchdog_generation:
            return False
        if not self._received_frame or time.monotonic() - self._last_frame_at <= self._restart_delay:
            return True
        self._restart_delay = min(CameraView.MAXIMUM_RESTART_DELAY, self._restart_delay * 2)
        self.stop()
        self.start()
        return False

    def _note_frame(self) -> None:
        """A frame arrived, so the feed is alive. Sustained flow also earns back the short retry
        delay, otherwise one bad patch would leave a healthy camera on a 30 second leash."""
        self._received_frame = True
        now = time.monotonic()
        self._last_frame_at = now
        if self._restart_delay > CameraView.MINIMUM_RESTART_DELAY and now - self._last_healthy_reset > 60:
            self._restart_delay = CameraView.MINIMUM_RESTART_DELAY
            self._last_healthy_reset = now

    def _on_destroy(self, *_a: Any) -> None:
        self.stop()

    # --- workers --------------------------------------------------------------
    def _run(self, stop: threading.Event) -> None:
        try:
            if self.printer is not None and self.printer.kind in {PrinterKind.BAMBU, PrinterKind.ANYCUBIC_KOBRA_S1}:
                if self.printer.kind == PrinterKind.ANYCUBIC_KOBRA_S1:
                    self._run_anycubic(stop)
                    return
                # The X1 answers on RTSPS; the P1 and A1 have no RTSP endpoint and serve JPEG frames on port
                # 6000 instead. A stream that never produced a frame is the cue to try that protocol before
                # calling the camera unavailable, as macOS and Windows do.
                if not self._run_bambu(stop) and not stop.is_set():
                    self._run_bambu_jpeg(stop)
            else:
                self._run_mjpeg(stop)
        except Exception as exc:  # noqa: BLE001 - surface, never crash the thread
            if not stop.is_set():
                self._set_status(i18n.t("Camera error: {0}").format(exc))

    def _run_bambu(self, stop: threading.Event) -> bool:
        """RTSPS on port 322. Returns whether it produced a picture (or was stopped), so the caller knows when to try JPEG."""
        pl = self.app.language == "pl"
        if Gst is None:
            self._set_status(i18n.t("GStreamer is unavailable — install GStreamer and the H.264 decoder."))
            return False
        if not self.access_code:
            self._set_status(i18n.t("Printer access code is missing."))
            return True

        pipeline = Gst.Pipeline.new(f"bambu-camera-{self.serial}")
        source = Gst.ElementFactory.make("rtspsrc", "source")
        depay = Gst.ElementFactory.make("rtph264depay", "depay")
        parser = Gst.ElementFactory.make("h264parse", "parser")
        decoder = Gst.ElementFactory.make("avdec_h264", "decoder")
        convert = Gst.ElementFactory.make("videoconvert", "convert")
        encoder = Gst.ElementFactory.make("jpegenc", "encoder")
        sink = Gst.ElementFactory.make("appsink", "sink")
        elements = (source, depay, parser, decoder, convert, encoder, sink)
        if pipeline is None or any(element is None for element in elements):
            self._set_status(i18n.t("Required GStreamer H.264/JPEG plugins are missing."))
            return False

        source.set_property("location", f"rtsps://{self.camera_host}:322/streaming/live/1")
        source.set_property("user-id", "bblp")
        source.set_property("user-pw", self.access_code)
        source.set_property("latency", 120)
        if source.find_property("protocols") is not None:
            # GstRtsp.RTSPLowerTrans.TCP == 4; avoid another optional GI namespace.
            source.set_property("protocols", 4)
        if source.find_property("tls-validation-flags") is not None:
            # Bambu printers use a local self-signed certificate.
            source.set_property("tls-validation-flags", 0)

        sink.set_property("emit-signals", True)
        sink.set_property("sync", False)
        sink.set_property("max-buffers", 1)
        sink.set_property("drop", True)
        encoder.set_property("quality", 82)
        for element in elements:
            pipeline.add(element)
        if not depay.link(parser) or not parser.link(decoder) or not decoder.link(convert) \
                or not convert.link(encoder) or not encoder.link(sink):
            self._set_status(i18n.t("Could not link the camera pipeline."))
            pipeline.set_state(Gst.State.NULL)
            return False

        def pad_added(_source: Any, pad: Any) -> None:
            target = depay.get_static_pad("sink")
            if target is not None and not target.is_linked():
                pad.link(target)

        def new_sample(appsink: Any) -> Any:
            sample = appsink.emit("pull-sample")
            if sample is None:
                return Gst.FlowReturn.ERROR
            buffer = sample.get_buffer()
            if buffer is not None:
                self._push_jpeg(buffer.extract_dup(0, buffer.get_size()))
            return Gst.FlowReturn.OK

        source.connect("pad-added", pad_added)
        sink.connect("new-sample", new_sample)
        self._pipeline = pipeline
        self._set_badge("RTSPS · 322")
        result = pipeline.set_state(Gst.State.PLAYING)
        if result == Gst.StateChangeReturn.FAILURE:
            self._set_status(i18n.t("Could not start the camera stream."))
            pipeline.set_state(Gst.State.NULL)
            self._pipeline = None
            return False

        bus = pipeline.get_bus()
        first_frame_deadline = time.monotonic() + self.FIRST_FRAME_TIMEOUT
        while not stop.is_set():
            if not self._received_frame and time.monotonic() >= first_frame_deadline:
                break
            message = bus.timed_pop_filtered(
                250 * Gst.MSECOND, Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if message is None:
                continue
            if message.type == Gst.MessageType.ERROR:
                error, _debug = message.parse_error()
                self._set_status((i18n.t("Camera error: ")) + error.message)
            elif message.type == Gst.MessageType.EOS:
                self._set_status(i18n.t("The camera stream ended."))
            break
        pipeline.set_state(Gst.State.NULL)
        if self._pipeline is pipeline:
            self._pipeline = None
        return self._received_frame or stop.is_set()

    def _run_bambu_jpeg(self, stop: threading.Event) -> None:
        """P1 and A1: JPEG frames over TLS on port 6000 after an 80-byte login (jpegstream.bambu_jpeg_frames)."""
        self._set_status(i18n.t("Connecting to the P1/A1 camera…"))
        self._set_badge("JPEG · 6000")
        try:
            if not bambu_jpeg_frames(self.camera_host, self.access_code, stop, self._push_jpeg) and not stop.is_set():
                self._set_status(i18n.t("The camera sent no picture. Check the access code and LAN Mode Live View."))
        except OSError as error:
            if not stop.is_set():
                self._set_status(i18n.t("Camera error: {0}").format(error))

    def _run_anycubic(self, stop: threading.Event) -> None:
        pl = self.app.language == "pl"
        if Gst is None:
            self._set_status(i18n.t("GStreamer is unavailable for FLV decoding."))
            return
        pipeline = Gst.Pipeline.new(f"anycubic-camera-{self.serial}")
        source = Gst.ElementFactory.make("souphttpsrc", "source")
        demux = Gst.ElementFactory.make("flvdemux", "demux")
        queue = Gst.ElementFactory.make("queue", "queue")
        decoder = Gst.ElementFactory.make("decodebin", "decoder")
        convert = Gst.ElementFactory.make("videoconvert", "convert")
        encoder = Gst.ElementFactory.make("jpegenc", "encoder")
        sink = Gst.ElementFactory.make("appsink", "sink")
        elements = (source, demux, queue, decoder, convert, encoder, sink)
        if pipeline is None or any(element is None for element in elements):
            self._set_status(i18n.t("Could not create the FLV camera pipeline."))
            return
        source.set_property("location", f"http://{self.camera_host}:18088/flv")
        encoder.set_property("quality", 82)
        sink.set_property("emit-signals", True); sink.set_property("sync", False)
        sink.set_property("max-buffers", 1); sink.set_property("drop", True)
        for element in elements: pipeline.add(element)
        if not source.link(demux) or not queue.link(decoder) or not convert.link(encoder) or not encoder.link(sink):
            self._set_status(i18n.t("Could not link the FLV camera pipeline."))
            return
        def link_video_pad(_element: Any, pad: Any, target: Any) -> None:
            caps = pad.get_current_caps() or pad.query_caps(None)
            if caps is not None and "video/" in caps.to_string():
                target_pad = target.get_static_pad("sink")
                if target_pad is not None and not target_pad.is_linked(): pad.link(target_pad)
        demux.connect("pad-added", lambda element, pad: link_video_pad(element, pad, queue))
        decoder.connect("pad-added", lambda element, pad: link_video_pad(element, pad, convert))
        def new_sample(appsink: Any) -> Any:
            sample = appsink.emit("pull-sample")
            if sample is None: return Gst.FlowReturn.ERROR
            buffer = sample.get_buffer()
            if buffer is not None: self._push_jpeg(buffer.extract_dup(0, buffer.get_size()))
            return Gst.FlowReturn.OK
        sink.connect("new-sample", new_sample); self._pipeline = pipeline; self._set_badge("FLV · 18088")
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self._set_status(i18n.t("Could not start the FLV camera."))
            pipeline.set_state(Gst.State.NULL); self._pipeline = None; return
        bus = pipeline.get_bus()
        first_frame_deadline = time.monotonic() + self.FIRST_FRAME_TIMEOUT
        while not stop.is_set():
            if not self._received_frame and time.monotonic() >= first_frame_deadline:
                break
            message = bus.timed_pop_filtered(250 * Gst.MSECOND, Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if message is None: continue
            if message.type == Gst.MessageType.ERROR:
                error, _debug = message.parse_error(); self._set_status((i18n.t("Camera error: ")) + error.message)
            break
        pipeline.set_state(Gst.State.NULL)
        if self._pipeline is pipeline: self._pipeline = None

    def _run_mjpeg(self, stop: threading.Event) -> None:
        gate = self._elegoo_video_gate()
        if gate is None:
            self._stream_mjpeg(stop)
            return
        # The CC1 serves nothing on 3031 until it has accepted Cmd 386, and it says why when it refuses.
        ack = gate.acquire()
        try:
            refusal = elegoo_video_refusal(ack)
            if refusal is not None:
                if not stop.is_set():
                    self._set_status(refusal)
                return
            if not stop.is_set():
                self._stream_mjpeg(stop)
        finally:
            gate.release()

    def _elegoo_video_gate(self) -> Any | None:
        if self.printer is None or self.printer.kind != PrinterKind.ELEGOO_CC1:
            return None
        return getattr(self.app.connections.get(self.serial), "video_gate", None)

    def _stream_mjpeg(self, stop: threading.Event) -> None:
        url = self._mjpeg_url()
        if not url:
            self._set_status(i18n.t("No MJPEG camera URL found."))
            return
        self._set_badge("MJPEG")
        emit = lambda frame: self._push_jpeg(ensure_huffman_tables(frame))  # noqa: E731
        for attempt in range(1, CameraView.MJPEG_ATTEMPTS + 1):
            try:
                with urllib.request.urlopen(urllib.request.Request(url), timeout=10) as stream:
                    buffer = bytearray()
                    while not stop.is_set():
                        chunk = stream.read(16384)
                        if not chunk:
                            break
                        buffer.extend(chunk)
                        split_jpegs(buffer, emit)
                if stop.is_set():
                    return
                failure = i18n.t("The camera stream ended.")
            except OSError as error:
                if stop.is_set():
                    return
                failure = i18n.t("Camera error: {0}").format(error)
            # A stream that already showed pictures is the watchdog's to restart.
            if self._received_frame or attempt == CameraView.MJPEG_ATTEMPTS:
                self._set_status(failure)
                return
            if stop.wait(2.0):
                return

    def _mjpeg_url(self) -> str | None:
        host, port = self.camera_host, self.printer.port
        if self.printer.kind == PrinterKind.ELEGOO_CC2:
            connection = self.app.connections.get(self.serial)
            sender = getattr(connection, "send_method", None)
            if callable(sender): sender(1042, {})
            return f"http://{host}:8080/?action=stream"
        if self.printer.kind == PrinterKind.ELEGOO_CC1:
            return f"http://{host}:3031/video"
        if self.printer.kind == PrinterKind.KLIPPER:
            try:
                raw = urllib.request.urlopen(
                    f"http://{host}:{port}/server/webcams/list", timeout=6).read()
                webcams = json.loads(raw).get("result", {}).get("webcams", [])
                if webcams:
                    path = webcams[0].get("stream_url") or webcams[0].get("snapshot_url") or ""
                    if path.startswith("http"):
                        return path
                    if path:
                        return f"http://{host}{path if path.startswith('/') else '/' + path}"
            except Exception:
                pass
            return f"http://{host}/webcam/?action=stream"
        return None

    # --- UI updates -----------------------------------------------------------
    def _push_jpeg(self, data: bytes) -> None:
        self._note_frame()

        def apply() -> bool:
            if self._stop.is_set():
                return False
            try:
                loader = GdkPixbuf.PixbufLoader.new_with_type("jpeg")
                loader.write(data)
                loader.close()
                pixbuf = loader.get_pixbuf()
            except Exception:
                pixbuf = None
            if pixbuf is None:
                # Frames that arrive but never decode used to leave "Connecting to camera…" up for good.
                self._decode_failures += 1
                if self._decode_failures == CameraView.DECODE_FAILURES_BEFORE_NOTICE:
                    self.status.set_text(i18n.t("The camera sends pictures that cannot be decoded."))
                return False
            self._decode_failures = 0
            sink = self.frame_sink
            if sink is not None:
                width = pixbuf.get_width()
                if width > SINK_FRAME_WIDTH:
                    pixbuf = pixbuf.scale_simple(SINK_FRAME_WIDTH, int(pixbuf.get_height() * SINK_FRAME_WIDTH / width),
                                                 GdkPixbuf.InterpType.BILINEAR)
                sink(pixbuf)
                return False
            alloc = self.image.get_allocation()
            target_w = max(320, alloc.width)
            scale = target_w / pixbuf.get_width()
            target_h = int(pixbuf.get_height() * scale)
            self.image.set_from_pixbuf(pixbuf.scale_simple(target_w, target_h, GdkPixbuf.InterpType.BILINEAR))
            self.status.set_text("")
            return False
        GLib.idle_add(apply)

    def _set_status(self, text: str) -> None:
        GLib.idle_add(lambda: (self.status.set_text(text), False)[1])

    def _set_badge(self, text: str) -> None:
        GLib.idle_add(lambda: (self.badge.set_text(text), False)[1])


class CameraWindow(Gtk.Window):
    """Standalone host retained for the card menu; Details embeds CameraView directly."""

    def __init__(self, app: Any, serial: str, access_code: str | None) -> None:
        super().__init__()
        printer = next((p for p in app.printers if p.serial == serial), None)
        pl = app.language == "pl"
        self.set_title((i18n.t("Camera")) + f" · {printer.name if printer else serial}")
        self.set_default_size(720, 460)
        self.set_transient_for(app.window)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.view = CameraView(app, serial, access_code)
        self.view.set_border_width(8)
        self.add(self.view)
        self.connect("delete-event", lambda *_: (self.stop(), False)[1])

    def start(self) -> None:
        self.view.start()

    def stop(self) -> None:
        self.view.stop()
