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


#: ITU T.81 Annex K.3 Huffman tables as one DHT segment. Motion JPEG cameras often leave them out and rely
#: on the decoder knowing them; not every decoder does.
STANDARD_HUFFMAN_TABLES = bytes.fromhex(
    "ffc401a20000010501010101010100000000000000000102030405060708090a0b100002010303020403050504040000017d0102030004110512213141061351610722711432"
    "8191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a83"
    "8485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8"
    "f9fa0100030101010101010101010000000000000102030405060708090a0b110002010204040304070504040001027700010203110405213106124151076171132232810814"
    "4291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a8283"
    "8485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa")


def ensure_huffman_tables(jpeg: bytes) -> bytes:
    """A frame without Huffman tables gets the standard ones in front of its scan; anything else comes back
    unchanged. The same repair as macOS JPEGHuffman and Windows JpegHuffman."""
    if len(jpeg) <= 4 or jpeg[0] != 0xFF or jpeg[1] != 0xD8:
        return jpeg
    index = 2
    while index + 3 < len(jpeg):
        if jpeg[index] != 0xFF:
            return jpeg
        marker = jpeg[index + 1]
        if marker == 0xFF:
            index += 1
        elif marker == 0xC4:
            return jpeg
        elif marker == 0xDA:
            return jpeg[:index] + STANDARD_HUFFMAN_TABLES + jpeg[index:]
        elif marker == 0x01 or 0xD0 <= marker <= 0xD7:
            index += 2
        else:
            index += 2 + (jpeg[index + 2] << 8 | jpeg[index + 3])
    return jpeg


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
