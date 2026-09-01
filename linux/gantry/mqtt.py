from __future__ import annotations

import hashlib
import json
import socket
import ssl
import struct
import threading
import time
import uuid
from collections.abc import Callable

from .core import Printer, Telemetry, parse_telemetry
from .storage import Config


def _mqtt_string(value: str) -> bytes:
    data = value.encode("utf-8")
    return struct.pack("!H", len(data)) + data


def _remaining_length(value: int) -> bytes:
    result = bytearray()
    while True:
        digit = value % 128
        value //= 128
        if value:
            digit |= 0x80
        result.append(digit)
        if not value:
            return bytes(result)


def connect_packet(username: str, password: str, client_id: str | None = None) -> bytes:
    variable = _mqtt_string("MQTT") + bytes((4, 0xC2)) + struct.pack("!H", 60)
    payload = _mqtt_string(client_id or f"Gantry-{uuid.uuid4().hex[:8]}") + _mqtt_string(username) + _mqtt_string(password)
    body = variable + payload
    return bytes((0x10,)) + _remaining_length(len(body)) + body


def subscribe_packet(topic: str) -> bytes:
    body = struct.pack("!H", 1) + _mqtt_string(topic) + b"\x00"
    return b"\x82" + _remaining_length(len(body)) + body


def publish_packet(topic: str, payload: bytes) -> bytes:
    body = _mqtt_string(topic) + payload
    return b"\x30" + _remaining_length(len(body)) + body


def read_packet(stream: ssl.SSLSocket) -> tuple[int, bytes]:
    first = stream.recv(1)
    if not first:
        raise ConnectionError("connection-closed")
    multiplier, remaining = 1, 0
    for _ in range(4):
        digit = stream.recv(1)
        if not digit:
            raise ConnectionError("incomplete-mqtt-packet")
        remaining += (digit[0] & 127) * multiplier
        if digit[0] & 128 == 0:
            break
        multiplier *= 128
    body = bytearray()
    while len(body) < remaining:
        chunk = stream.recv(remaining - len(body))
        if not chunk:
            raise ConnectionError("incomplete-mqtt-body")
        body.extend(chunk)
    return first[0], bytes(body)


def publish_payload(header: int, body: bytes) -> bytes | None:
    if header >> 4 != 3 or len(body) < 2:
        return None
    length = struct.unpack("!H", body[:2])[0]
    offset = 2 + length
    if header & 0x06:
        offset += 2
    return body[offset:] if offset <= len(body) else None


def publish_topic(header: int, body: bytes) -> str | None:
    if header >> 4 != 3 or len(body) < 2:
        return None
    length = struct.unpack("!H", body[:2])[0]
    if len(body) < 2 + length:
        return None
    try:
        return body[2:2 + length].decode("utf-8")
    except UnicodeDecodeError:
        return None


class MqttConnection:
    def __init__(self, printer: Printer, access_code: str, config: Config,
                 on_event: Callable[[str, object | None], None]) -> None:
        self.printer = printer
        self.access_code = access_code
        self.config = config
        self.on_event = on_event
        self.telemetry = Telemetry()
        self._stop = threading.Event()
        self._socket: ssl.SSLSocket | None = None
        self._thread: threading.Thread | None = None
        self._send_lock = threading.Lock()

    def send_command(self, json_str: str) -> bool:
        """Publish a raw command (e.g. chamber light, pause) to the printer's request topic. Used by
        automations. Safe to call from any thread; serialised against the read loop's own writes."""
        stream = self._socket
        if stream is None:
            return False
        packet = publish_packet(f"device/{self.printer.serial}/request", json_str.encode())
        try:
            with self._send_lock:
                stream.sendall(packet)
            return True
        except OSError:
            return False

    def start(self) -> None:
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name=f"mqtt-{self.printer.serial}", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._socket:
            try:
                self._socket.close()
            except OSError:
                pass

    def _run(self) -> None:
        delay = 2.0
        while not self._stop.is_set():
            try:
                self._connect_and_read()
                delay = 2.0
            except Exception as error:
                if not self._stop.is_set():
                    self.on_event("disconnected", str(error))
                    self._stop.wait(delay)
                    delay = min(delay * 1.7, 30.0)

    def _connect_and_read(self) -> None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        with socket.create_connection((self.printer.host, self.printer.port), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname=self.printer.host) as stream:
                self._socket = stream
                fingerprint = hashlib.sha256(stream.getpeercert(binary_form=True)).hexdigest()
                pinned = self.config.pin_for(self.printer.serial)
                if pinned and pinned != fingerprint:
                    raise ssl.SSLError("certificate-changed")
                if not pinned:
                    self.config.set_pin(self.printer.serial, fingerprint)
                stream.settimeout(35)
                stream.sendall(connect_packet("bblp", self.access_code))
                header, body = read_packet(stream)
                if header >> 4 != 2 or len(body) < 2 or body[1] != 0:
                    raise PermissionError("access-code-rejected")
                self.on_event("connected", None)
                report = f"device/{self.printer.serial}/report"
                request = f"device/{self.printer.serial}/request"
                stream.sendall(subscribe_packet(report))
                stream.sendall(publish_packet(request, b'{"pushing":{"sequence_id":"0","command":"pushall"}}'))
                last_ping = time.monotonic()
                while not self._stop.is_set():
                    try:
                        header, body = read_packet(stream)
                    except socket.timeout:
                        with self._send_lock:
                            stream.sendall(b"\xC0\x00")
                        last_ping = time.monotonic()
                        continue
                    if time.monotonic() - last_ping > 30:
                        with self._send_lock:
                            stream.sendall(b"\xC0\x00")
                        last_ping = time.monotonic()
                    payload = publish_payload(header, body)
                    if payload is None:
                        continue
                    updated = parse_telemetry(payload, self.telemetry)
                    if updated:
                        self.telemetry = updated
                        self.on_event("telemetry", updated)
        self._socket = None
