from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from typing import Any

from .core import (
    AmsSlot,
    FilamentGroup,
    FilamentSlot,
    NozzleTelemetry,
    Printer,
    PrinterKind,
    PrinterState,
    Telemetry,
)


EventHandler = Callable[[str, object | None], None]


def _number(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _integer(value: Any) -> int | None:
    value = _number(value)
    return int(value) if value is not None else None


def _color(value: Any) -> str:
    raw = str(value or "").lstrip("#")
    if len(raw) == 7:
        raw = raw[1:]
    if len(raw) == 6 and all(character in "0123456789abcdefABCDEF" for character in raw):
        return raw.upper() + "FF"
    if len(raw) == 8 and all(character in "0123456789abcdefABCDEF" for character in raw):
        return raw.upper()
    return "8E8E93FF"


def _copy(previous: Telemetry | None) -> Telemetry:
    old = previous or Telemetry()
    return Telemetry(**{name: getattr(old, name) for name in Telemetry.__dataclass_fields__})


def parse_moonraker(payload: bytes | str | dict[str, Any], previous: Telemetry | None = None) -> Telemetry | None:
    try:
        root = json.loads(payload) if isinstance(payload, (bytes, str)) else payload
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(root, dict):
        return None
    result = root.get("result") if isinstance(root.get("result"), dict) else root
    status = result.get("status") if isinstance(result, dict) else None
    if not isinstance(status, dict):
        return None
    telemetry = _copy(previous)
    stats = status.get("print_stats") if isinstance(status.get("print_stats"), dict) else {}
    state = str(stats.get("state", "")).lower()
    telemetry.state = {
        "printing": PrinterState.PRINTING,
        "paused": PrinterState.PAUSED,
        "complete": PrinterState.FINISHED,
        "completed": PrinterState.FINISHED,
        "error": PrinterState.ERROR,
    }.get(state, PrinterState.IDLE)
    filename = str(stats.get("filename") or "").replace("\\", "/").rsplit("/", 1)[-1]
    if filename:
        telemetry.job_name = filename
    info = stats.get("info") if isinstance(stats.get("info"), dict) else {}
    telemetry.current_layer = _integer(info.get("current_layer")) or telemetry.current_layer
    telemetry.total_layers = _integer(info.get("total_layer")) or telemetry.total_layers
    display = status.get("display_status") if isinstance(status.get("display_status"), dict) else {}
    virtual = status.get("virtual_sdcard") if isinstance(status.get("virtual_sdcard"), dict) else {}
    progress = _number(display.get("progress"))
    if progress is None:
        progress = _number(virtual.get("progress"))
    if progress is not None:
        telemetry.progress = min(max(round(progress * 100), 0), 100)
    duration = _number(stats.get("print_duration"))
    if duration and progress and progress > .01:
        telemetry.remaining_minutes = round(duration * (1 - progress) / progress / 60)
    extruder = status.get("extruder") if isinstance(status.get("extruder"), dict) else {}
    bed = status.get("heater_bed") if isinstance(status.get("heater_bed"), dict) else {}
    telemetry.nozzle = _number(extruder.get("temperature"))
    telemetry.nozzle_target = _number(extruder.get("target"))
    telemetry.bed = _number(bed.get("temperature"))
    telemetry.bed_target = _number(bed.get("target"))
    for key, value in status.items():
        lowered = key.lower()
        if "chamber" in lowered and lowered.startswith(("temperature_sensor", "heater_generic")) and isinstance(value, dict):
            telemetry.chamber = _number(value.get("temperature"))
            break
    mmu = status.get("mmu") if isinstance(status.get("mmu"), dict) else None
    if mmu and mmu.get("enabled", True):
        # Happy Hare is one dynamic module: num_gates gates T0..Tn, never split into fours.
        count = _integer(mmu.get("num_gates")) or 0
        materials = mmu.get("gate_material") if isinstance(mmu.get("gate_material"), list) else []
        colors = mmu.get("gate_color") if isinstance(mmu.get("gate_color"), list) else []
        statuses = mmu.get("gate_status") if isinstance(mmu.get("gate_status"), list) else []
        active = _integer(mmu.get("gate"))
        slots: list[FilamentSlot] = []
        for index in range(count):
            occupied = _integer(statuses[index]) if index < len(statuses) else -1
            material = str(materials[index] if index < len(materials) else "")
            present = occupied != 0 and bool(material)
            slots.append(FilamentSlot(
                slot_id=f"mmu-{index}", label=f"T{index}",
                material=material if present else None,
                color=_color(colors[index] if index < len(colors) else None) if present else None,
                active=index == active,
            ))
        if slots:
            group = FilamentGroup(
                group_id="mmu", source_type="mmu", display_name="MMU",
                declared_capacity=count, external=False, slots=slots,
            )
            telemetry.filament_groups = [group]
            telemetry.ams_slots = group.legacy_slots()
    # Single-nozzle Klipper machine: expose one nozzle entry for the shared collection.
    telemetry.nozzles = [NozzleTelemetry("single", telemetry.nozzle, telemetry.nozzle_target)]
    return telemetry


def parse_cfs(payload: bytes | str | dict[str, Any]) -> list[FilamentGroup]:
    """Each materialBoxs element is its own module: type 1 is the external spool (EXT), the rest are
    CFS 1, CFS 2, … keeping four fixed positions."""
    try:
        root = json.loads(payload) if isinstance(payload, (bytes, str)) else payload
    except (json.JSONDecodeError, UnicodeDecodeError):
        return []
    if not isinstance(root, dict):
        return []
    container = root.get("boxsInfo") or root.get("result") or root
    boxes = container.get("materialBoxs") if isinstance(container, dict) else None
    if not isinstance(boxes, list):
        return []
    groups: list[FilamentGroup] = []
    cfs_number = 0
    slot_number = 0
    for box_index, box in enumerate(boxes):
        if not isinstance(box, dict):
            continue
        spool = _integer(box.get("type")) == 1
        raw_materials = box.get("materials") if isinstance(box.get("materials"), list) else []
        capacity = 1 if spool else 4
        slots: list[FilamentSlot] = []
        for slot_index in range(capacity):
            material = raw_materials[slot_index] if slot_index < len(raw_materials) and isinstance(raw_materials[slot_index], dict) else {}
            raw_name = material.get("type") or material.get("name")
            name = str(raw_name) if raw_name else None
            if spool:
                label = "EXT"
            else:
                label = f"T{slot_number}"
                slot_number += 1
            slots.append(FilamentSlot(
                slot_id=f"cfs-{box_index}-{slot_index}", label=label,
                material=name,
                color=_color(material.get("color")) if name else None,
                remaining=_integer(material.get("percent")),
                active=_integer(material.get("selected")) == 1,
            ))
        if spool:
            groups.append(FilamentGroup(
                group_id=f"cfs-ext-{box_index}", source_type="external", display_name="EXT",
                declared_capacity=1, external=True, slots=slots,
            ))
        else:
            cfs_number += 1
            groups.append(FilamentGroup(
                group_id=f"cfs-{box_index}", source_type="cfs", display_name=f"CFS {cfs_number}",
                declared_capacity=capacity, external=False, slots=slots,
            ))
    return groups


def parse_prusalink(status_payload: bytes | str | dict[str, Any],
                    job_payload: bytes | str | dict[str, Any] | None = None,
                    previous: Telemetry | None = None) -> Telemetry | None:
    try:
        root = json.loads(status_payload) if isinstance(status_payload, (bytes, str)) else status_payload
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(root, dict):
        return None
    telemetry = _copy(previous)
    printer = root.get("printer") if isinstance(root.get("printer"), dict) else {}
    state = str(printer.get("state", "")).upper()
    telemetry.state = {
        "PRINTING": PrinterState.PRINTING, "PAUSED": PrinterState.PAUSED,
        "FINISHED": PrinterState.FINISHED, "ERROR": PrinterState.ERROR,
        "ATTENTION": PrinterState.ERROR,
    }.get(state, PrinterState.IDLE)
    telemetry.nozzle = _number(printer.get("temp_nozzle"))
    telemetry.nozzle_target = _number(printer.get("target_nozzle"))
    telemetry.bed = _number(printer.get("temp_bed"))
    telemetry.bed_target = _number(printer.get("target_bed"))
    job = root.get("job") if isinstance(root.get("job"), dict) else {}
    progress = _number(job.get("progress"))
    if progress is not None:
        telemetry.progress = min(max(round(progress), 0), 100)
    remaining = _number(job.get("time_remaining"))
    if remaining and remaining > 0:
        telemetry.remaining_minutes = round(remaining / 60)
    try:
        job_root = json.loads(job_payload) if isinstance(job_payload, (bytes, str)) else job_payload
    except (json.JSONDecodeError, UnicodeDecodeError):
        job_root = None
    if isinstance(job_root, dict) and isinstance(job_root.get("file"), dict):
        name = str(job_root["file"].get("display_name") or job_root["file"].get("name") or "")
        if name:
            telemetry.job_name = name.replace("\\", "/").rsplit("/", 1)[-1]
    return telemetry


class HttpConnection:
    def __init__(self, printer: Printer, api_key: str | None, on_event: EventHandler) -> None:
        self.printer, self.api_key, self.on_event = printer, api_key, on_event
        self.telemetry = Telemetry()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._cfs_groups: list[FilamentGroup] = []

    def start(self) -> None:
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name=f"http-{self.printer.serial}", daemon=True)
        self._thread.start()
        if self.printer.kind == PrinterKind.KLIPPER:
            threading.Thread(target=self._run_cfs, name=f"cfs-{self.printer.serial}", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()

    def _get(self, path: str) -> bytes:
        request = urllib.request.Request(f"http://{self.printer.host}:{self.printer.port}{path}")
        request.add_header("Cache-Control", "no-cache")
        if self.api_key:
            request.add_header("X-Api-Key", self.api_key)
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status != 200:
                raise ConnectionError(f"HTTP {response.status}")
            return response.read()

    def _moonraker_path(self) -> str:
        wanted = ["print_stats", "virtual_sdcard", "display_status", "extruder", "heater_bed", "mmu"]
        try:
            root = json.loads(self._get("/printer/objects/list"))
            objects = root.get("result", {}).get("objects", [])
            if isinstance(objects, list):
                available = set(str(value) for value in objects)
                wanted = [value for value in wanted if value in available]
                wanted.extend(value for value in available if "chamber" in value.lower()
                              and value.startswith(("temperature_sensor", "heater_generic")))
        except (OSError, ValueError, urllib.error.URLError):
            pass
        if not wanted:
            raise ConnectionError("moonraker-objects-not-found")
        return "/printer/objects/query?" + "&".join(urllib.parse.quote(value, safe="") for value in wanted)

    def _run(self) -> None:
        delay = 2.0
        path: str | None = None
        while not self._stop.is_set():
            try:
                if self.printer.kind == PrinterKind.KLIPPER:
                    path = path or self._moonraker_path()
                    updated = parse_moonraker(self._get(path), self.telemetry)
                    if updated and self._cfs_groups:
                        # A Creality CFS overrides the (absent) Happy Hare gates with its own modules.
                        groups = list(self._cfs_groups)
                        updated.filament_groups = groups
                        updated.ams_slots = [slot for group in groups for slot in group.legacy_slots()]
                else:
                    status = self._get("/api/v1/status")
                    try:
                        job = self._get("/api/v1/job")
                    except (OSError, urllib.error.URLError):
                        job = None
                    updated = parse_prusalink(status, job, self.telemetry)
                if updated:
                    self.telemetry = updated
                    self.on_event("connected", None)
                    self.on_event("telemetry", updated)
                delay = 2.0
            except (OSError, ValueError, urllib.error.URLError) as error:
                if not self._stop.is_set():
                    self.on_event("disconnected", str(error))
                    self._stop.wait(delay)
                    delay = min(delay * 1.7, 30.0)
                continue
            self._stop.wait(2.0)

    def _run_cfs(self) -> None:
        try:
            import websocket  # type: ignore[import-not-found]
        except ImportError:
            return
        request = '{"method":"get","params":{"boxsInfo":1}}'
        while not self._stop.is_set():
            socket = None
            try:
                socket = websocket.create_connection(f"ws://{self.printer.host}:9999", timeout=5)
                socket.settimeout(6)
                while not self._stop.is_set():
                    socket.send(request)
                    groups = parse_cfs(socket.recv())
                    if groups:
                        self._cfs_groups = groups
                    self._stop.wait(5)
            except Exception:
                self._stop.wait(30)
            finally:
                if socket:
                    try:
                        socket.close()
                    except Exception:
                        pass
