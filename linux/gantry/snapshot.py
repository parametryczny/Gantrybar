"""Grabs a single still frame from a printer's camera and returns it as JPEG.

The Linux counterpart of macOS Services/CameraSnapshot.swift, used by the Telegram bot's /photo and
/watch. Bambu (RTSPS/H.264) and Anycubic (HTTP/FLV) go through the same GStreamer pipelines the live
view builds, only torn down after the first frame; Klipper and Elegoo stream MJPEG, so their first
frame is read in pure Python without any decoder.

Deliberately free of the GTK main loop: `try-pull-sample` blocks on the calling thread, so this is safe
to call from the bot's worker thread. Best-effort with a timeout; returns None rather than raising.
"""
from __future__ import annotations

import time
import urllib.request
from typing import Any

import gi

from .core import PrinterKind
from .jpegstream import split_jpegs
from .overrides import overrides_for

try:
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst  # type: ignore  # noqa: E402
    Gst.init(None)
except (ImportError, ValueError):
    Gst = None  # type: ignore[assignment]


def capture(app: Any, serial: str, timeout: float = 12) -> bytes | None:
    """First JPEG frame from this printer's camera, or None when unavailable."""
    printer = next((p for p in app.printers if p.serial == serial), None)
    if printer is None:
        return None
    host = overrides_for(app.config, serial).get("cameraHost") or printer.host
    try:
        if printer.kind == PrinterKind.BAMBU:
            code = app.secrets.get(serial) or ""
            if not code:
                return None
            return _grab_bambu(host, code, serial, timeout)
        if printer.kind == PrinterKind.ANYCUBIC_KOBRA_S1:
            return _grab_anycubic(host, serial, timeout)
        url = _mjpeg_url(app, printer, host)
        return _grab_mjpeg(url, timeout) if url else None
    except Exception:      # noqa: BLE001 - a snapshot must never take the bot down
        return None


# --- GStreamer ---------------------------------------------------------------

def _pull_first(pipeline: Any, sink: Any, timeout: float) -> bytes | None:
    """Run the pipeline until appsink yields one buffer, then always tear it down."""
    sink.set_property("sync", False)
    sink.set_property("max-buffers", 1)
    sink.set_property("drop", True)
    try:
        pipeline.set_state(Gst.State.PLAYING)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            # Action signal rather than the GstApp binding, so no extra GI namespace is required.
            sample = sink.emit("try-pull-sample", int(0.5 * Gst.SECOND))
            if sample is None:
                continue
            buffer = sample.get_buffer()
            if buffer is not None:
                return buffer.extract_dup(0, buffer.get_size())
        return None
    finally:
        pipeline.set_state(Gst.State.NULL)


def _grab_bambu(host: str, access_code: str, serial: str, timeout: float) -> bytes | None:
    if Gst is None:
        return None
    pipeline = Gst.Pipeline.new(f"snapshot-bambu-{serial}")
    names = ("rtspsrc", "rtph264depay", "h264parse", "avdec_h264", "videoconvert", "jpegenc", "appsink")
    source, depay, parser, decoder, convert, encoder, sink = (Gst.ElementFactory.make(n, None) for n in names)
    elements = (source, depay, parser, decoder, convert, encoder, sink)
    if pipeline is None or any(element is None for element in elements):
        return None
    source.set_property("location", f"rtsps://{host}:322/streaming/live/1")
    source.set_property("user-id", "bblp")
    source.set_property("user-pw", access_code)
    source.set_property("latency", 120)
    if source.find_property("protocols") is not None:
        source.set_property("protocols", 4)          # TCP
    if source.find_property("tls-validation-flags") is not None:
        source.set_property("tls-validation-flags", 0)   # local self-signed certificate
    encoder.set_property("quality", 82)
    for element in elements:
        pipeline.add(element)
    if not (depay.link(parser) and parser.link(decoder) and decoder.link(convert)
            and convert.link(encoder) and encoder.link(sink)):
        pipeline.set_state(Gst.State.NULL)
        return None
    source.connect("pad-added", lambda _s, pad: _link_to(pad, depay))
    return _pull_first(pipeline, sink, timeout)


def _grab_anycubic(host: str, serial: str, timeout: float) -> bytes | None:
    if Gst is None:
        return None
    pipeline = Gst.Pipeline.new(f"snapshot-anycubic-{serial}")
    names = ("souphttpsrc", "flvdemux", "queue", "decodebin", "videoconvert", "jpegenc", "appsink")
    source, demux, queue, decoder, convert, encoder, sink = (Gst.ElementFactory.make(n, None) for n in names)
    elements = (source, demux, queue, decoder, convert, encoder, sink)
    if pipeline is None or any(element is None for element in elements):
        return None
    source.set_property("location", f"http://{host}:18088/flv")
    encoder.set_property("quality", 82)
    for element in elements:
        pipeline.add(element)
    if not (source.link(demux) and queue.link(decoder) and convert.link(encoder) and encoder.link(sink)):
        pipeline.set_state(Gst.State.NULL)
        return None
    demux.connect("pad-added", lambda _e, pad: _link_to(pad, queue))
    decoder.connect("pad-added", lambda _e, pad: _link_to(pad, convert))
    return _pull_first(pipeline, sink, timeout)


def _link_to(pad: Any, element: Any) -> None:
    target = element.get_static_pad("sink")
    if target is not None and not target.is_linked():
        pad.link(target)


# --- MJPEG (Klipper / Elegoo) -------------------------------------------------

def _grab_mjpeg(url: str, timeout: float) -> bytes | None:
    frames: list[bytes] = []
    request = urllib.request.Request(url)
    with urllib.request.urlopen(request, timeout=timeout) as stream:
        buffer = bytearray()
        deadline = time.monotonic() + timeout
        while not frames and time.monotonic() < deadline:
            chunk = stream.read(16384)
            if not chunk:
                break
            buffer.extend(chunk)
            split_jpegs(buffer, frames.append)
    return frames[0] if frames else None


def _mjpeg_url(app: Any, printer: Any, host: str) -> str | None:
    """Same addresses the live view uses, including the Elegoo 'start the stream' nudge."""
    if printer.kind in {PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2}:
        connection = app.connections.get(printer.serial)
        sender = getattr(connection, "send_method", None)
        is_cc2 = printer.kind == PrinterKind.ELEGOO_CC2
        if callable(sender):
            sender(1042, {}) if is_cc2 else sender(386, {"Enable": 1})
        return f"http://{host}:8080/?action=stream" if is_cc2 else f"http://{host}:3031/video"
    if printer.kind == PrinterKind.KLIPPER:
        return f"http://{host}:{printer.port or 7125}/webcam/?action=stream"
    return None
