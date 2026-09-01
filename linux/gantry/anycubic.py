"""LAN driver for the Anycubic Kobra S1.

The printer exposes a small HTTP bootstrap service on port 18910.  Its response
contains the per-printer MQTT credentials encrypted with AES-128-CBC; telemetry
and controls then use the printer's local MQTT-over-TLS broker.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import socket
import ssl
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid
from collections.abc import Callable
from typing import Any

from .core import AmsSlot, FilamentGroup, FilamentSlot, Printer, PrinterState, Telemetry
from .mqtt import connect_packet, publish_packet, publish_payload, read_packet, subscribe_packet


def _number(value: Any) -> float | None:
    try: return float(value) if value is not None else None
    except (TypeError, ValueError): return None


def _integer(value: Any) -> int | None:
    value = _number(value)
    return int(value) if value is not None else None


def _state(value: Any) -> PrinterState:
    name = str(value or "").lower()
    if name in {"printing", "running", "prepare", "working"}: return PrinterState.PRINTING
    if name in {"pause", "paused", "pausing"}: return PrinterState.PAUSED
    if name in {"done", "finished", "complete", "completed", "success"}: return PrinterState.FINISHED
    if name in {"error", "failed", "failure", "abnormal"}: return PrinterState.ERROR
    return PrinterState.IDLE


def parse_anycubic_message(payload: bytes | str, previous: Telemetry | None = None) -> Telemetry | None:
    try: root = json.loads(payload)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError): return None
    if not isinstance(root, dict): return None
    kind = str(root.get("type") or "")
    data = root.get("data") if isinstance(root.get("data"), dict) else {}
    tel = copy.deepcopy(previous) if previous is not None else Telemetry()
    changed = False

    if kind == "info":
        tel.state = _state(data.get("state")); changed = True
        temp = data.get("temp") if isinstance(data.get("temp"), dict) else {}
        project = data.get("project") if isinstance(data.get("project"), dict) else {}
        for key, attr in (("curr_nozzle_temp", "nozzle"), ("target_nozzle_temp", "nozzle_target"),
                          ("curr_hotbed_temp", "bed"), ("target_hotbed_temp", "bed_target"),
                          ("curr_chamber_temp", "chamber")):
            if key in temp: setattr(tel, attr, _number(temp.get(key))); changed = True
        if "fan_speed_pct" in data: tel.part_fan = _integer(data.get("fan_speed_pct")); changed = True
        if "aux_fan_speed_pct" in data: tel.aux_fan = _integer(data.get("aux_fan_speed_pct")); changed = True
        if "box_fan_level" in data: tel.chamber_fan = _integer(data.get("box_fan_level")); changed = True
        if "print_speed_mode" in data: tel.speed_level = _integer(data.get("print_speed_mode")); changed = True
        if project:
            changed = _apply_project(tel, project, data.get("state")) or changed
    elif kind == "tempature":  # spelling used by the printer firmware
        for key, attr in (("curr_nozzle_temp", "nozzle"), ("target_nozzle_temp", "nozzle_target"),
                          ("curr_hotbed_temp", "bed"), ("target_hotbed_temp", "bed_target"),
                          ("curr_chamber_temp", "chamber")):
            if key in data: setattr(tel, attr, _number(data.get(key))); changed = True
    elif kind == "print":
        changed = _apply_project(tel, data, root.get("state"))
    elif kind == "fan":
        for key, attr in (("fan_speed_pct", "part_fan"), ("aux_fan_speed_pct", "aux_fan"),
                          ("box_fan_level", "chamber_fan")):
            if key in data: setattr(tel, attr, _integer(data.get(key))); changed = True
    elif kind == "multiColorBox":
        boxes = data.get("multi_color_box") if isinstance(data.get("multi_color_box"), list) else []
        groups: list[FilamentGroup] = []
        for box_index, box in enumerate(boxes):
            if not isinstance(box, dict): continue
            loaded = _integer(box.get("loaded_slot"))
            slots: list[FilamentSlot] = []
            by_index = {(_integer(slot.get("index")) or 0): slot for slot in box.get("slots", []) if isinstance(slot, dict)}
            capacity = max(4, max(by_index, default=-1) + 1)
            for slot_index in range(capacity):
                slot = by_index.get(slot_index, {})
                present = (_integer(slot.get("status")) or 0) > 0
                rgb = slot.get("color")
                color = None
                if isinstance(rgb, list) and len(rgb) >= 3:
                    color = "".join(f"{max(0, min(255, int(c))):02X}" for c in rgb[:3]) + "FF"
                material = str(slot.get("type") or "") or None
                slots.append(FilamentSlot(slot_id=f"ace-{box_index}-{slot_index}",
                    label=f"{chr(65 + box_index)}{slot_index + 1}", material=material if present else None,
                    color=color if present else None, remaining=None,
                    active=present and loaded == slot_index))
            groups.append(FilamentGroup(group_id=f"ace-{box_index}", source_type="ams",
                display_name="ACE Pro" if box_index == 0 else f"ACE Pro {box_index + 1}",
                declared_capacity=capacity, temperature=_number(box.get("temp")), slots=slots))
        if groups:
            tel.filament_groups = groups
            tel.ams_slots = [AmsSlot(slot_id=s.slot_id, label=s.label, material=s.material or "—",
                color=s.color or "8E8E93FF", remaining=s.remaining, active=s.active)
                for group in groups for s in group.slots]
            changed = True
    if changed:
        tel.nozzles = []
        return tel
    return None


def _apply_project(tel: Telemetry, project: dict[str, Any], state: Any) -> bool:
    tel.state = _state(state)
    progress = _integer(project.get("progress"))
    if progress is not None: tel.progress = max(0, min(100, progress))
    # Kobra S1 reports both print_time and remain_time in minutes.
    remaining = _integer(project.get("remain_time"))
    if remaining is not None: tel.remaining_minutes = max(0, remaining)
    if "curr_layer" in project: tel.current_layer = _integer(project.get("curr_layer"))
    if "total_layers" in project: tel.total_layers = _integer(project.get("total_layers"))
    if "filename" in project: tel.job_name = str(project.get("filename") or "") or None
    return True


def _post_json(url: str) -> dict[str, Any]:
    request = urllib.request.Request(url, data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.loads(response.read())


def _decrypt(encrypted: str, token: str, local_token: str) -> dict[str, Any]:
    key, iv = token[16:32].encode(), local_token.encode()[:16].ljust(16, b"\0")
    # PyCryptodome is embedded in the portable AppImage. System packages can use either it or the
    # openssl command already declared as a package dependency.
    try:
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import unpad
        clear = unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(base64.b64decode(encrypted)), AES.block_size)
        return json.loads(clear)
    except ImportError:
        pass
    process = subprocess.run(["openssl", "enc", "-aes-128-cbc", "-d", "-K", key.hex(), "-iv", iv.hex()],
                             input=base64.b64decode(encrypted), capture_output=True, timeout=8, check=True)
    return json.loads(process.stdout)


def discover_anycubic(host: str, port: int = 18910) -> dict[str, Any]:
    with urllib.request.urlopen(f"http://{host}:{port}/info", timeout=8) as response:
        info = json.loads(response.read())
    if info.get("ctrlType") == "cloud":
        raise ConnectionError("Włącz tryb LAN w ustawieniach drukarki Anycubic")
    token, control = str(info.get("token") or ""), str(info.get("ctrlInfoUrl") or "")
    if not token or not control: raise ConnectionError("Drukarka nie zwróciła danych sterowania LAN")
    ts = int(time.time() * 1000); nonce = uuid.uuid4().hex[:6]
    first = hashlib.md5(token[:16].encode()).hexdigest()
    sign = hashlib.md5(f"{first}{ts}{nonce}".encode()).hexdigest()
    query = urllib.parse.urlencode({"ts": ts, "nonce": nonce, "sign": sign, "did": uuid.uuid4().hex.upper()})
    result = _post_json(f"{control}{'&' if '?' in control else '?'}{query}")
    body = result.get("data") if isinstance(result.get("data"), dict) else {}
    if result.get("code") != 200 or not body.get("info") or not body.get("token"):
        raise ConnectionError("Anycubic odrzucił inicjalizację połączenia LAN")
    credentials = _decrypt(str(body["info"]), token, str(body["token"]))
    credentials["modelName"] = credentials.get("modelName") or info.get("modelName") or "Anycubic Kobra S1"
    credentials["cn"] = info.get("cn")
    return credentials


class AnycubicS1Connection:
    def __init__(self, printer: Printer, on_event: Callable[[str, object | None], None]) -> None:
        self.printer, self.on_event = printer, on_event
        self.telemetry = Telemetry(); self._stop = threading.Event(); self._socket: ssl.SSLSocket | None = None
        self._thread: threading.Thread | None = None; self._send_lock = threading.Lock()
        self._base = ""; self._credentials: dict[str, Any] = {}

    def start(self) -> None:
        self._stop.clear(); self._thread = threading.Thread(target=self._run, name=f"anycubic-{self.printer.serial}", daemon=True); self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._socket:
            try: self._socket.close()
            except OSError: pass

    def send_action(self, action: str) -> bool:
        return self._publish("print", action)

    def set_light(self, enabled: bool) -> bool:
        return self._publish("light", "control", {"type": 2, "status": 1 if enabled else 0, "brightness": 100})

    def _publish(self, kind: str, action: str, data: Any = None) -> bool:
        if not self._socket or not self._base: return False
        payload = {"type": kind, "action": action, "timestamp": int(time.time() * 1000), "msgid": str(uuid.uuid4()), "data": data}
        try:
            with self._send_lock: self._socket.sendall(publish_packet(f"{self._base}/{kind}", json.dumps(payload).encode()))
            return True
        except OSError: return False

    def _run(self) -> None:
        delay = 2.0
        while not self._stop.is_set():
            try: self._connect_and_read(); delay = 2.0
            except Exception as error:
                if not self._stop.is_set(): self.on_event("disconnected", str(error)); self._stop.wait(delay); delay = min(delay * 1.7, 30)

    def _connect_and_read(self) -> None:
        self._credentials = discover_anycubic(self.printer.host, self.printer.port or 18910)
        parsed = urllib.parse.urlparse(str(self._credentials.get("broker") or ""))
        host, port = parsed.hostname or self.printer.host, parsed.port or 9883
        mode = str(self._credentials.get("modeId") or self._credentials.get("modelId") or "")
        device = str(self._credentials.get("deviceId") or "")
        if not mode or not device: raise ConnectionError("Brak identyfikatora MQTT Anycubic")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); context.check_hostname = False; context.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, port), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname=host) as stream:
                self._socket = stream; stream.settimeout(35)
                stream.sendall(connect_packet(str(self._credentials.get("username") or ""), str(self._credentials.get("password") or "")))
                header, body = read_packet(stream)
                if header >> 4 != 2 or len(body) < 2 or body[1] != 0: raise PermissionError("Anycubic odrzucił połączenie MQTT")
                self.on_event("connected", None)
                stream.sendall(subscribe_packet(f"anycubic/anycubicCloud/v1/printer/+/{mode}/{device}/#"))
                stream.sendall(subscribe_packet(f"anycubic/anycubicCloud/v1/+/public/{mode}/{device}/+/report"))
                self._base = f"anycubic/anycubicCloud/v1/web/printer/{mode}/{device}"
                for kind, action in (("info", "query"), ("light", "query"), ("multiColorBox", "getInfo")):
                    self._publish(kind, action)
                self._publish("video", "startCapture")
                while not self._stop.is_set():
                    try: header, body = read_packet(stream)
                    except socket.timeout:
                        with self._send_lock: stream.sendall(b"\xC0\x00")
                        continue
                    payload = publish_payload(header, body)
                    if payload is None: continue
                    updated = parse_anycubic_message(payload, self.telemetry)
                    if updated is not None: self.telemetry = updated; self.on_event("telemetry", updated)
        self._socket = None; self._base = ""
