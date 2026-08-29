"""Live camera view for the Linux dashboard, matching the macOS/Windows Details camera:

  - Bambu: the printer's local RTSPS stream (rtsps://bblp:<access code>@host:322/streaming/live/1),
    decoded by ffmpeg used purely as an H.264 decoder (as on Windows) into an MJPEG pipe. ffmpeg on
    Linux speaks TLS through openssl/gnutls and accepts the printer's self-signed certificate, so no
    custom TLS client is needed here. Requires the "LAN Mode Live View" toggle on the printer.
  - Klipper / Moonraker and other MJPEG cameras: the multipart JPEG stream read directly in pure
    Python (no ffmpeg), so a webcam works even without the decoder installed.

Frames are JPEGs either way; each is handed to GdkPixbuf and drawn into a Gtk.Image. All network/decoder
work happens on a worker thread; the UI is only touched via GLib.idle_add.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import threading
import urllib.request
from typing import Any, Callable

from gi.repository import GdkPixbuf, GLib, Gtk  # type: ignore  # noqa: E402

from .core import PrinterKind

_SOI = b"\xff\xd8"   # JPEG start of image
_EOI = b"\xff\xd9"   # JPEG end of image


def _split_jpegs(buffer: bytearray, emit: Callable[[bytes], None]) -> None:
    """Pull every complete JPEG out of a growing byte buffer (in place)."""
    while True:
        start = buffer.find(_SOI)
        if start < 0:
            if len(buffer) > 4:
                del buffer[:-2]
            return
        end = buffer.find(_EOI, start + 2)
        if end < 0:
            if start > 0:
                del buffer[:start]
            return
        frame = bytes(buffer[start:end + 2])
        del buffer[:end + 2]
        emit(frame)


class CameraWindow(Gtk.Window):
    def __init__(self, app: Any, serial: str, access_code: str | None) -> None:
        super().__init__()
        self.app = app
        self.serial = serial
        self.access_code = access_code or ""
        self.printer = next((p for p in app.printers if p.serial == serial), None)
        self._stop = threading.Event()
        self._process: subprocess.Popen | None = None
        pl = app.language == "pl"

        self.set_title(("Kamera" if pl else "Camera") + f" · {self.printer.name if self.printer else serial}")
        self.set_default_size(720, 460)
        self.set_transient_for(app.window)
        self.set_position(Gtk.WindowPosition.CENTER)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        root.set_border_width(8)
        self.add(root)
        self.image = Gtk.Image()
        self.image.set_size_request(640, 360)
        frame = Gtk.EventBox()
        frame.get_style_context().add_class("card")
        frame.add(self.image)
        root.pack_start(frame, True, True, 0)
        self.status = Gtk.Label(xalign=0)
        self.status.get_style_context().add_class("subtitle")
        self.status.set_text("Łączenie z kamerą…" if pl else "Connecting to camera…")
        root.pack_start(self.status, False, False, 0)
        self.badge = Gtk.Label(xalign=0)
        self.badge.get_style_context().add_class("meta")
        root.pack_start(self.badge, False, False, 0)

        self.connect("destroy", self._on_destroy)
        self.connect("delete-event", lambda *_: (self.stop(), False)[1])

    # --- lifecycle ------------------------------------------------------------
    def start(self) -> None:
        self._stop.clear()
        threading.Thread(target=self._run, name=f"camera-{self.serial}", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        if self._process is not None:
            try:
                self._process.terminate()
            except Exception:
                pass

    def _on_destroy(self, *_a: Any) -> None:
        self.stop()

    # --- workers --------------------------------------------------------------
    def _run(self) -> None:
        try:
            if self.printer is not None and self.printer.kind == PrinterKind.BAMBU:
                self._run_bambu()
            else:
                self._run_mjpeg()
        except Exception as exc:  # noqa: BLE001 - surface, never crash the thread
            self._set_status(f"Błąd kamery: {exc}" if self.app.language == "pl" else f"Camera error: {exc}")

    def _run_bambu(self) -> None:
        pl = self.app.language == "pl"
        if not shutil.which("ffmpeg"):
            self._set_status("Brak ffmpeg — zainstaluj pakiet ffmpeg, aby oglądać kamerę Bambu."
                             if pl else "ffmpeg not found — install the ffmpeg package to view the Bambu camera.")
            return
        host = self.printer.host
        url = f"rtsps://bblp:{self.access_code}@{host}:322/streaming/live/1"
        self._set_badge("RTSPS · 322")
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-rtsp_transport", "tcp",
               "-i", url, "-an", "-f", "mjpeg", "-q:v", "6", "-"]
        self._process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        buffer = bytearray()
        got_frame = False
        assert self._process.stdout is not None
        while not self._stop.is_set():
            chunk = self._process.stdout.read(32768)
            if not chunk:
                break
            buffer.extend(chunk)

            def emit(frame: bytes) -> None:
                nonlocal got_frame
                got_frame = True
                self._push_jpeg(frame)
            _split_jpegs(buffer, emit)
        if not got_frame and not self._stop.is_set():
            self._set_status("Brak obrazu. Włącz „LAN Mode Live View” na drukarce."
                             if pl else "No image. Enable \"LAN Mode Live View\" on the printer.")

    def _run_mjpeg(self) -> None:
        pl = self.app.language == "pl"
        url = self._mjpeg_url()
        if not url:
            self._set_status("Nie znaleziono adresu kamery MJPEG." if pl else "No MJPEG camera URL found.")
            return
        self._set_badge("MJPEG")
        request = urllib.request.Request(url)
        with urllib.request.urlopen(request, timeout=10) as stream:
            buffer = bytearray()
            while not self._stop.is_set():
                chunk = stream.read(16384)
                if not chunk:
                    break
                buffer.extend(chunk)
                _split_jpegs(buffer, self._push_jpeg)

    def _mjpeg_url(self) -> str | None:
        host, port = self.printer.host, self.printer.port
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
        def apply() -> bool:
            if self._stop.is_set():
                return False
            try:
                loader = GdkPixbuf.PixbufLoader.new_with_type("jpeg")
                loader.write(data)
                loader.close()
                pixbuf = loader.get_pixbuf()
            except Exception:
                return False
            if pixbuf is None:
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
