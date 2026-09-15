"""Local-network drivers for Elegoo Centauri Carbon generations 1 and 2.

CC1 speaks SDCP over WebSocket. CC2 runs an unauthenticated/TCP MQTT broker with
an access-code login, mandatory client registration and application heartbeat.
The two transports deliberately remain separate even though both normalize into
Gantry's shared :class:`Telemetry` model.
"""
from __future__ import annotations

import copy
import json
import socket
import threading
import time
import uuid
from collections.abc import Callable
from typing import Any

from . import i18n
from .core import FilamentGroup, FilamentSlot, Printer, PrinterState, Telemetry
from .mqtt import (connect_packet, publish_packet, publish_payload, publish_topic,
                   read_packet, subscribe_packet)


def deep_merge(base: dict[str, Any], update: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(base)
    for key, value in update.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def _number(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _integer(value: Any) -> int | None:
    value = _number(value)
    return int(value) if value is not None else None


def _percent_pwm(value: Any) -> int | None:
    raw = _number(value)
    return None if raw is None else max(0, min(100, round(raw / 255 * 100)))


def _cc2_state(machine: dict[str, Any], print_status: dict[str, Any]) -> PrinterState:
    internal = str(print_status.get("state") or "").lower()
    if internal in {"error", "failed"} or machine.get("exception_status"):
        return PrinterState.ERROR
    if internal in {"paused", "pausing"} or _integer(machine.get("sub_status")) in {2501, 2502, 2505}:
        return PrinterState.PAUSED
    if internal in {"complete", "completed"} or _integer(machine.get("sub_status")) == 2077:
        return PrinterState.FINISHED
    if internal in {"printing", "resuming"} or _integer(machine.get("status")) == 2:
        return PrinterState.PRINTING
    if _integer(machine.get("status")) == 14:
        return PrinterState.ERROR
    return PrinterState.IDLE


def parse_cc2_status(result: dict[str, Any], previous: Telemetry | None = None) -> Telemetry:
    tel = copy.deepcopy(previous) if previous is not None else Telemetry()
    machine = result.get("machine_status") if isinstance(result.get("machine_status"), dict) else {}
    status = result.get("print_status") if isinstance(result.get("print_status"), dict) else {}
    extruder = result.get("extruder") if isinstance(result.get("extruder"), dict) else {}
    bed = result.get("heater_bed") if isinstance(result.get("heater_bed"), dict) else {}
    chamber = result.get("ztemperature_sensor") or result.get("chamber") or {}
    fans = result.get("fans") if isinstance(result.get("fans"), dict) else {}
    move = result.get("gcode_move_inf") or result.get("gcode_move") or {}

    tel.state = _cc2_state(machine, status)
    progress = _integer(status.get("progress", machine.get("progress")))
    if progress is not None: tel.progress = max(0, min(100, progress))
    remaining = _integer(status.get("remaining_time_sec"))
    if remaining is not None: tel.remaining_minutes = max(0, round(remaining / 60))
    if "filename" in status: tel.job_name = str(status.get("filename") or "") or None
    if "current_layer" in status: tel.current_layer = _integer(status.get("current_layer"))
    if "total_layer" in status: tel.total_layers = _integer(status.get("total_layer"))
    if "filament_used" in status: tel.filament_used_mm = _number(status.get("filament_used"))
    if "temperature" in extruder: tel.nozzle = _number(extruder.get("temperature"))
    if "target" in extruder: tel.nozzle_target = _number(extruder.get("target"))
    if "temperature" in bed: tel.bed = _number(bed.get("temperature"))
    if "target" in bed: tel.bed_target = _number(bed.get("target"))
    if isinstance(chamber, dict) and "temperature" in chamber: tel.chamber = _number(chamber.get("temperature"))
    for key, attr in (("fan", "part_fan"), ("aux_fan", "aux_fan"), ("box_fan", "chamber_fan")):
        value = fans.get(key)
        if isinstance(value, dict) and "speed" in value: setattr(tel, attr, _percent_pwm(value.get("speed")))
    mode = _integer(move.get("speed_mode")) if isinstance(move, dict) else None
    if mode is not None:
        tel.speed_level = mode + 1
        tel.speed_percent = {0: 50, 1: 100, 2: 150, 3: 200}.get(mode)
    errors = machine.get("exception_status")
    if isinstance(errors, list):
        tel.hms_codes = [str(value) for value in errors]
        tel.error_code = _integer(errors[0]) or 0 if errors else 0
    return tel


def apply_canvas(result: dict[str, Any], telemetry: Telemetry) -> Telemetry:
    tel = copy.deepcopy(telemetry)
    info = result.get("canvas_info") if isinstance(result.get("canvas_info"), dict) else {}
    active_canvas, active_tray = _integer(info.get("active_canvas_id")), _integer(info.get("active_tray_id"))
    groups: list[FilamentGroup] = []
    for canvas in info.get("canvas_list", []) if isinstance(info.get("canvas_list"), list) else []:
        if not isinstance(canvas, dict) or _integer(canvas.get("connected")) == 0: continue
        canvas_id = _integer(canvas.get("canvas_id")) or 0
        slots: list[FilamentSlot] = []
        trays = canvas.get("tray_list") if isinstance(canvas.get("tray_list"), list) else []
        by_id = {(_integer(t.get("tray_id")) or 0): t for t in trays if isinstance(t, dict)}
        for tray_id in range(4):
            tray = by_id.get(tray_id, {})
            present = (_integer(tray.get("status")) or 0) > 0
            material = str(tray.get("filament_type") or tray.get("filament_name") or "") or None
            color = str(tray.get("filament_color") or "").lstrip("#") or None
            if color and len(color) == 6: color += "FF"
            slots.append(FilamentSlot(
                slot_id=f"canvas-{canvas_id}-{tray_id}", label=f"{chr(65 + canvas_id)}{tray_id + 1}",
                material=material if present else None, color=color if present else None,
                remaining=None, active=present and canvas_id == active_canvas and tray_id == active_tray,
            ))
        groups.append(FilamentGroup(group_id=f"canvas-{canvas_id}", source_type="canvas",
                                    display_name="CANVAS" if canvas_id == 0 else f"CANVAS {chr(65 + canvas_id)}",
                                    declared_capacity=4, slots=slots))
    if groups:
        tel.filament_groups = groups
        tel.ams_slots = [slot for group in groups for slot in _legacy_slots(group)]
    return tel


def _legacy_slots(group: FilamentGroup):
    from .core import AmsSlot
    for slot in group.slots:
        yield AmsSlot(slot_id=slot.slot_id, label=slot.label, material=slot.material or "—",
                      color=slot.color or "8E8E93FF", remaining=None, active=slot.active)


def _find_dict(value: Any, key: str) -> dict[str, Any] | None:
    if isinstance(value, dict):
        candidate = value.get(key)
        if isinstance(candidate, dict): return candidate
        for child in value.values():
            found = _find_dict(child, key)
            if found is not None: return found
    elif isinstance(value, list):
        for child in value:
            found = _find_dict(child, key)
            if found is not None: return found
    return None


def parse_cc1_message(message: str | bytes, previous: Telemetry | None = None) -> Telemetry | None:
    try: root = json.loads(message)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError): return None
    status = _find_dict(root, "Status")
    if status is None: return None
    tel = copy.deepcopy(previous) if previous is not None else Telemetry()
    print_info = status.get("PrintInfo") if isinstance(status.get("PrintInfo"), dict) else {}
    current_status = status.get("CurrentStatus", [])
    current_values = current_status if isinstance(current_status, list) else [current_status]
    print_status = _integer(print_info.get("Status")) or 0
    if _integer(print_info.get("ErrorNumber")) or print_status == 14:
        tel.state = PrinterState.ERROR
    elif print_status in {5, 6}:
        tel.state = PrinterState.PAUSED
    elif print_status in {1, 7, 13, 15, 16} or any((_integer(v) or 0) in {1, 5, 6, 7, 13, 15, 16} for v in current_values):
        tel.state = PrinterState.PRINTING
    elif print_status == 9:
        tel.state = PrinterState.FINISHED
    else:
        tel.state = PrinterState.IDLE
    for key, attr in (("TempOfNozzle", "nozzle"), ("TempTargetNozzle", "nozzle_target"),
                      ("TempOfHotbed", "bed"), ("TempTargetHotbed", "bed_target"),
                      ("TempOfBox", "chamber")):
        if key in status: setattr(tel, attr, _number(status.get(key)))
    for key, attr in (("Progress", "progress"), ("CurrentLayer", "current_layer"), ("TotalLayer", "total_layers")):
        if key in print_info: setattr(tel, attr, _integer(print_info.get(key)))
    if "Filename" in print_info: tel.job_name = str(print_info.get("Filename") or "") or None
    current, total = _number(print_info.get("CurrentTicks")), _number(print_info.get("TotalTicks"))
    if current is not None and total is not None: tel.remaining_minutes = max(0, round((total - current) / 60))
    fans = status.get("CurrentFanSpeed") if isinstance(status.get("CurrentFanSpeed"), dict) else {}
    for key, attr in (("ModelFan", "part_fan"), ("AuxiliaryFan", "aux_fan"), ("BoxFan", "chamber_fan")):
        raw = _number(fans.get(key))
        if raw is not None: setattr(tel, attr, max(0, min(100, round(raw if raw <= 100 else raw / 255 * 100))))
    tel.error_code = _integer(print_info.get("ErrorNumber")) or 0
    return tel


def parse_cc1_video_reply(message: str | bytes) -> tuple[str | None, int] | None:
    """The printer's answer to Cmd 386 as (RequestID, Ack), or None for any other frame."""
    try: root = json.loads(message)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError): return None
    envelope = root.get("Data") if isinstance(root, dict) else None
    if not isinstance(envelope, dict) or envelope.get("Cmd") != 386: return None
    data = envelope.get("Data")
    ack = data.get("Ack") if isinstance(data, dict) else None
    if not isinstance(ack, int) or isinstance(ack, bool): return None
    request_id = envelope.get("RequestID")
    return (request_id if isinstance(request_id, str) else None), ack


class ElegooVideoGate:
    """The CC1 camera is not just a URL. Its MJPEG server on port 3031 only serves pictures after Cmd 386
    {"Enable": 1}, the printer answers with an Ack (0 started, 1 too many viewers, 2 no camera, 3 unknown)
    and it allows a single stream at a time. A stream enabled and never disabled keeps that slot taken, so
    the Elegoo app, the slicer or Gantry's next viewer is refused until the printer restarts.

    One gate per CC1 connection, shared by every viewer of that printer (details, edge dock, Telegram
    snapshots). The first viewer enables the stream and waits for the Ack; later viewers ride on it; the
    last one to leave disables it after a short grace, so a watchdog restart does not toggle the camera.
    Every acquire() must be matched by exactly one release(). Mirrors macOS and Windows ElegooVideoGate."""

    def __init__(self, send: Callable[[bool, str], object], reply_timeout: float = 6.0,
                 resend_interval: float = 1.5, release_grace: float = 5.0) -> None:
        self._send = send
        self.reply_timeout, self.resend_interval, self.release_grace = reply_timeout, resend_interval, release_grace
        self._lock = threading.Lock()
        self._holders = 0
        self._enabled = False
        self._waiters: list[list[Any]] = []
        self._request_ids: set[str] = set()
        self._attempt = 0
        self._release_generation = 0

    def acquire(self) -> int | None:
        """Counts the caller as a viewer and blocks until the Ack: None when the printer did not answer in
        time (older firmware, a socket still connecting), which is not a refusal."""
        waiter: list[Any] = [threading.Event(), None]
        with self._lock:
            self._holders += 1; self._release_generation += 1
            if self._enabled: return 0
            self._waiters.append(waiter)
            starting = len(self._waiters) == 1
            if starting: self._attempt += 1; self._request_ids.clear()
            attempt = self._attempt
        if starting:
            threading.Thread(target=self._request, args=(attempt, time.monotonic() + self.reply_timeout),
                             name="elegoo-video-request", daemon=True).start()
        waiter[0].wait(self.reply_timeout + 2.0)
        return waiter[1]

    def release(self) -> None:
        with self._lock:
            self._holders = max(0, self._holders - 1)
            if self._holders or not self._enabled: return
            self._release_generation += 1; generation = self._release_generation
        self._schedule_disable(generation)

    def handle_reply(self, request_id: str | None, ack: int) -> None:
        """Replies to requests this gate did not send (an Elegoo app on the same printer, an earlier
        disable) are ignored; a reply without a RequestID is taken at its word."""
        with self._lock:
            if not self._waiters or (request_id is not None and request_id not in self._request_ids): return
            attempt = self._attempt
        self._finish(ack, attempt)

    def reset(self) -> None:
        """The connection dropped: whatever the printer had enabled may be gone with it."""
        with self._lock: self._enabled = False

    def _request(self, attempt: int, deadline: float) -> None:
        while True:
            with self._lock:
                if attempt != self._attempt or not self._waiters: return
                remaining = deadline - time.monotonic()
                request_id = uuid.uuid4().hex
                if remaining > 0: self._request_ids.add(request_id)
            if remaining <= 0:
                self._finish(None, attempt); return
            # Sent again until answered: a command written while the socket is still connecting is dropped,
            # and the printer tolerates a repeated enable.
            self._send(True, request_id)
            time.sleep(min(self.resend_interval, remaining))

    def _finish(self, ack: int | None, attempt: int) -> None:
        generation = None
        with self._lock:
            if attempt != self._attempt or not self._waiters: return
            waiters, self._waiters = self._waiters, []
            self._attempt += 1
            if ack == 0: self._enabled = True
            # Every viewer may have left while the Ack was on its way; the stream must not stay on for nobody.
            if ack == 0 and self._holders == 0:
                self._release_generation += 1; generation = self._release_generation
        if generation is not None: self._schedule_disable(generation)
        for waiter in waiters:
            waiter[1] = ack; waiter[0].set()

    def _schedule_disable(self, generation: int) -> None:
        def disable() -> None:
            with self._lock:
                if generation != self._release_generation or self._holders or not self._enabled: return
                self._enabled = False
            self._send(False, uuid.uuid4().hex)
        timer = threading.Timer(self.release_grace, disable); timer.daemon = True; timer.start()


class ElegooCC1Connection:
    def __init__(self, printer: Printer, on_event: Callable[[str, object | None], None]) -> None:
        self.printer, self.on_event = printer, on_event
        self.telemetry = Telemetry()
        self._stop = threading.Event(); self._socket: Any | None = None
        #: Cmd 386 handshake and the single stream slot, shared by every camera viewer of this printer.
        self.video_gate = ElegooVideoGate(
            lambda enable, request_id: self.send_method(386, {"Enable": 1 if enable else 0}, request_id))

    def start(self) -> None:
        self._stop.clear(); threading.Thread(target=self._run, name=f"elegoo-cc1-{self.printer.serial}", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        try:
            if self._socket: self._socket.close()
        except Exception: pass

    def send_method(self, command: int, data: dict[str, Any] | None = None, request_id: str | None = None) -> bool:
        if self._socket is None: return False
        request_id = request_id or uuid.uuid4().hex
        payload = {"Id": self.printer.serial, "Data": {
            "Cmd": command, "Data": data or {}, "RequestID": request_id,
            "MainboardID": self.printer.serial, "TimeStamp": int(time.time() * 1000), "From": 1,
        }, "Topic": f"sdcp/request/{self.printer.serial}"}
        try: self._socket.send(json.dumps(payload)); return True
        except Exception: return False

    def send_command(self, value: str) -> bool:
        try:
            payload = json.loads(value)
            return self.send_method(int(payload["method"]), payload.get("params") or {})
        except (ValueError, TypeError, KeyError, json.JSONDecodeError): return False

    def _run(self) -> None:
        delay = 2.0
        while not self._stop.is_set():
            try:
                import websocket  # type: ignore[import-not-found]
                self._socket = websocket.create_connection(f"ws://{self.printer.host}:{self.printer.port}/websocket", timeout=5)
                self.video_gate.reset()
                self.on_event("connected", None); self.send_method(0); self.send_method(1); self.send_method(512, {"TimePeriod": 5000})
                last_status = time.monotonic()
                while not self._stop.is_set():
                    try: message = self._socket.recv()
                    except websocket.WebSocketTimeoutException:
                        if time.monotonic() - last_status >= 10:
                            self.send_method(0); last_status = time.monotonic()
                        continue
                    if not message: raise ConnectionError("connection-closed")
                    reply = parse_cc1_video_reply(message)
                    if reply is not None: self.video_gate.handle_reply(*reply)
                    updated = parse_cc1_message(message, self.telemetry)
                    if updated is not None:
                        self.telemetry = updated; self.on_event("telemetry", updated); last_status = time.monotonic()
            except Exception as error:
                if not self._stop.is_set(): self.on_event("disconnected", str(error)); self._stop.wait(delay); delay = min(30, delay * 1.7)
            finally: self._socket = None; self.video_gate.reset()


class ElegooCC2Connection:
    def __init__(self, printer: Printer, access_code: str, on_event: Callable[[str, object | None], None]) -> None:
        self.printer, self.access_code, self.on_event = printer, access_code or "123456", on_event
        self.telemetry = Telemetry(); self._status: dict[str, Any] = {}
        self._stop = threading.Event(); self._socket: socket.socket | None = None
        self._send_lock = threading.Lock(); self._sequence = 0
        self._last_status_id: int | None = None; self._status_gaps = 0
        self.client_id = f"1_PC_{uuid.uuid4().hex[:10]}"
        self.request_id = f"{self.client_id}_req"

    def start(self) -> None:
        self._stop.clear(); threading.Thread(target=self._run, name=f"elegoo-cc2-{self.printer.serial}", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        try:
            if self._socket: self._socket.close()
        except OSError: pass

    def send_method(self, method: int, params: dict[str, Any] | None = None) -> bool:
        self._sequence += 1
        return self._publish(f"elegoo/{self.printer.serial}/{self.client_id}/api_request",
                             {"id": self._sequence, "method": method, "params": params or {}})

    def send_command(self, value: str) -> bool:
        try:
            payload = json.loads(value)
            return self.send_method(int(payload["method"]), payload.get("params") or {})
        except (ValueError, TypeError, KeyError, json.JSONDecodeError): return False

    def _publish(self, topic: str, value: dict[str, Any]) -> bool:
        stream = self._socket
        if stream is None: return False
        try:
            with self._send_lock: stream.sendall(publish_packet(topic, json.dumps(value, separators=(",", ":")).encode()))
            return True
        except OSError: return False

    def _run(self) -> None:
        delay = 2.0
        while not self._stop.is_set():
            try: self._connect_and_read(); delay = 2.0
            except Exception as error:
                if not self._stop.is_set(): self.on_event("disconnected", str(error)); self._stop.wait(delay); delay = min(30, delay * 1.7)

    def _connect_and_read(self) -> None:
        with socket.create_connection((self.printer.host, self.printer.port), timeout=10) as stream:
            self._socket = stream; stream.settimeout(2)
            stream.sendall(connect_packet("elegoo", self.access_code, self.client_id))
            header, body = read_packet(stream)
            if header >> 4 != 2 or len(body) < 2 or body[1] != 0: raise PermissionError(i18n.t("The Elegoo printer rejected the access code"))
            register_topic = f"elegoo/{self.printer.serial}/{self.request_id}/register_response"
            stream.sendall(subscribe_packet(register_topic))
            self._publish(f"elegoo/{self.printer.serial}/api_register", {"client_id": self.client_id, "request_id": self.request_id})
            registered = False; last_heartbeat = 0.0; last_refresh = 0.0
            while not self._stop.is_set():
                now = time.monotonic()
                if registered and now - last_heartbeat >= 30:
                    self._publish(f"elegoo/{self.printer.serial}/{self.client_id}/api_request", {"type": "PING"}); last_heartbeat = now
                if registered and now - last_refresh >= 300:
                    self.send_method(1002); self.send_method(2005); last_refresh = now
                try: header, body = read_packet(stream)
                except socket.timeout: continue
                topic, raw = publish_topic(header, body), publish_payload(header, body)
                if topic is None or raw is None: continue
                try: message = json.loads(raw)
                except (json.JSONDecodeError, UnicodeDecodeError): continue
                if topic == register_topic:
                    error = str(message.get("error") or "fail")
                    if error != "ok": raise ConnectionError(i18n.t("Elegoo client limit exceeded") if "too many" in error
                                                   else i18n.t("Elegoo registration: {0}").format(error))
                    registered = True
                    stream.sendall(subscribe_packet(f"elegoo/{self.printer.serial}/api_status", 2))
                    stream.sendall(subscribe_packet(f"elegoo/{self.printer.serial}/{self.client_id}/api_response", 3))
                    self.on_event("connected", None); self.send_method(1002); self.send_method(2005)
                    last_heartbeat = last_refresh = time.monotonic()
                    continue
                method = _integer(message.get("method"))
                result = message.get("result") if isinstance(message.get("result"), dict) else {}
                if method in {6000, 6008, 1002}:
                    event_id = _integer(message.get("id"))
                    if method in {6000, 6008} and event_id is not None and self._last_status_id is not None:
                        self._status_gaps = 0 if event_id == self._last_status_id + 1 else self._status_gaps + 1
                        if self._status_gaps >= 5: self.send_method(1002); self._status_gaps = 0
                    if method in {6000, 6008} and event_id is not None: self._last_status_id = event_id
                    self._status = deep_merge(self._status, result)
                    self.telemetry = parse_cc2_status(self._status, self.telemetry)
                    self.on_event("telemetry", self.telemetry)
                elif method == 2005:
                    self.telemetry = apply_canvas(result, self.telemetry); self.on_event("telemetry", self.telemetry)
        self._socket = None
