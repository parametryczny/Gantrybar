"""Small, GUI-free helpers shared by camera streams and unit tests."""
from __future__ import annotations

import socket
import ssl
import threading
from typing import Any, Callable

_SOI = b"\xff\xd8"
_EOI = b"\xff\xd9"

#: The P1 and A1 serve their chamber camera as JPEG frames over TLS on this port (the X1 uses RTSPS).
BAMBU_JPEG_PORT = 6000


def split_jpegs(buffer: bytearray, emit: Callable[[bytes], None]) -> None:
    """Pull every complete JPEG out of a growing byte buffer in place."""
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


# Compatibility for code/tests written before this helper was extracted from camera.py.
_split_jpegs = split_jpegs


def bambu_auth_packet(access_code: str) -> bytes:
    """80 bytes: a 0x40 header, 0x3000 at offset 4, the fixed "bblp" user at 16 and the access code at 48.
    The same wire format as macOS BambuJPEGCameraStream and Windows BambuCameraStream.TryJpegAsync."""
    packet = bytearray(80)
    packet[0] = 0x40
    packet[5] = 0x30
    packet[16:20] = b"bblp"
    code = access_code.encode("utf-8")[:32]
    packet[48:48 + len(code)] = code
    return bytes(packet)


def _tls_connect(host: str, port: int, timeout: float) -> Any:
    # The printer presents a self-signed certificate; the access code is what authenticates the session.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((host, port), timeout=timeout)
    return context.wrap_socket(raw, server_hostname=host)


def bambu_jpeg_frames(host: str, access_code: str, stop: threading.Event | None, on_frame: Callable[[bytes], None],
                      timeout: float = 10.0, connect: Callable[[str, int, float], Any] = _tls_connect) -> bool:
    """Streams a P1/A1 camera's frames to ``on_frame`` until ``stop`` is set or the printer closes the
    connection. Returns whether any frame arrived. Raises OSError when the camera cannot be reached or
    sends nothing within ``timeout``."""
    received = False

    def emit(frame: bytes) -> None:
        nonlocal received
        received = True
        on_frame(frame)

    stream = connect(host, BAMBU_JPEG_PORT, timeout)
    try:
        stream.sendall(bambu_auth_packet(access_code))
        buffer = bytearray()
        while stop is None or not stop.is_set():
            try:
                chunk = stream.recv(65536)
            except socket.timeout:
                if not received:
                    raise
                continue
            if not chunk:
                break
            buffer.extend(chunk)
            if len(buffer) > 8 * 1024 * 1024:
                del buffer[:-2 * 1024 * 1024]
            split_jpegs(buffer, emit)
    finally:
        try:
            stream.close()
        except OSError:
            pass
    return received
