from __future__ import annotations

import ipaddress
import json
import re
import urllib.parse
from dataclasses import asdict, dataclass, field
from enum import Enum
from typing import Any


class PrinterState(str, Enum):
    OFFLINE = "offline"
    IDLE = "idle"
    PRINTING = "printing"
    PAUSED = "paused"
    FINISHED = "finished"
    ERROR = "error"


# Temperature STATE map (design/kolorystyka.md §3) — the same states drive nozzle, bed and chamber
# colour. `hold` = printing while at the setpoint; `err` comes from a firmware alarm, not a threshold.
TEMP_SYMBOLS = {
    "err": "!", "unavail": "—", "idle": "○",
    "heat": "↑", "ready": "●", "hold": "●", "cool": "↓",
}


def temp_state(cur: float | None, tgt: float | None, printing: bool, error: bool) -> str:
    if error:
        return "err"
    if cur is None:
        return "unavail"
    target = tgt or 0
    if target <= 5 and cur <= 30:
        return "idle"
    if target > 5 and cur < target - 3:
        return "heat"
    if cur > max(target, 0) + 5 and cur > 30:
        return "cool"
    return "hold" if printing else "ready"


class PrinterKind(str, Enum):
    BAMBU = "bambu"
    KLIPPER = "klipper"
    PRUSA = "prusa"
    SNAPMAKER = "snapmaker"
    ELEGOO_CC1 = "elegoo_cc1"
    ELEGOO_CC2 = "elegoo_cc2"
    ANYCUBIC_KOBRA_S1 = "anycubic_kobra_s1"

    @property
    def default_port(self) -> int:
        return {
            self.BAMBU: 8883,
            self.KLIPPER: 7125,
            self.PRUSA: 80,
            self.SNAPMAKER: 8080,
            self.ELEGOO_CC1: 3030,
            self.ELEGOO_CC2: 1883,
            self.ANYCUBIC_KOBRA_S1: 18910,
        }[self]


@dataclass(slots=True)
class AmsSlot:
    slot_id: str
    label: str
    material: str = "—"
    color: str = "8E8E93FF"
    remaining: int | None = None
    active: bool = False
    external: bool = False
    remaining_weight_g: float | None = None


@dataclass(slots=True)
class FilamentSlot:
    slot_id: str
    label: str                       # A1, B3, T6, EXT
    material: str | None = None      # None/empty => empty slot
    color: str | None = None
    remaining: int | None = None
    active: bool = False
    # Remaining grams from the AMS NFC/RFID tag (tray_weight * remain%); None for a chipless spool.
    remaining_weight_g: float | None = None

    @property
    def present(self) -> bool:
        return bool(self.material) and self.material != "—"


@dataclass(slots=True)
class FilamentGroup:
    group_id: str
    source_type: str                 # ams / amsHT / cfs / mmu / external
    display_name: str                # AMS A, AMS HT, CFS 1, MMU, EXT
    declared_capacity: int
    external: bool = False
    humidity: int | None = None      # per-module
    temperature: float | None = None
    slots: list["FilamentSlot"] = field(default_factory=list)

    def legacy_slots(self) -> list["AmsSlot"]:
        """Flat legacy representation still used by compact rows / notifications."""
        return [
            AmsSlot(
                slot_id=s.slot_id,
                label=s.label,
                material=s.material if s.present else "—",
                color=s.color or "8E8E93FF",
                remaining=s.remaining,
                active=s.active,
                external=self.external,
                remaining_weight_g=s.remaining_weight_g,
            )
            for s in self.slots
        ]


@dataclass(slots=True)
class NozzleTelemetry:
    position: str                    # single / left / right
    current: float | None = None
    target: float | None = None


@dataclass(slots=True)
class Telemetry:
    state: PrinterState = PrinterState.OFFLINE
    progress: int = 0
    remaining_minutes: int | None = None
    nozzle: float | None = None
    nozzle_target: float | None = None
    nozzle2: float | None = None
    nozzle2_target: float | None = None
    bed: float | None = None
    bed_target: float | None = None
    chamber: float | None = None
    # Only machines with a heated chamber (H2D) report a setpoint.
    chamber_target: float | None = None
    current_layer: int | None = None
    total_layers: int | None = None
    stage: int | None = None
    job_name: str | None = None
    error_code: int = 0
    hms_codes: list[str] = field(default_factory=list)
    # Physical filament modules (AMS / AMS HT / CFS / MMU / external); primary source for the card.
    filament_groups: list[FilamentGroup] = field(default_factory=list)
    # One entry for a single nozzle, two (left/right) for dual-nozzle printers like the H2D.
    nozzles: list[NozzleTelemetry] = field(default_factory=list)
    ams_slots: list[AmsSlot] = field(default_factory=list)
    ams_humidity: int | None = None
    ams_temperature: float | None = None
    # Consumption sources: Klipper reports real extruded length (mm); Bambu names the printed file so we
    # can read its per-filament used_g from the 3mf. Used to auto-decrement the assigned physical spool.
    filament_used_mm: float | None = None
    gcode_file: str | None = None
    # Cooling fans as a percentage (Bambu reports a 0-15 gear; aux = big_fan1, chamber = big_fan2),
    # speed level (Bambu spd_lvl: 1 Silent .. 4 Ludicrous) and magnitude, and nozzle diameter. Shown in
    # the Details view; not every model/firmware reports each one.
    part_fan: int | None = None
    aux_fan: int | None = None
    chamber_fan: int | None = None
    speed_level: int | None = None
    speed_percent: int | None = None
    nozzle_diameter: float | None = None


@dataclass(slots=True)
class Printer:
    serial: str
    name: str
    host: str
    model: str = "Bambu Lab"
    port: int = 8883
    kind: PrinterKind = PrinterKind.BAMBU

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Printer":
        try:
            kind = PrinterKind(str(value.get("kind", "bambu")).lower())
        except ValueError:
            kind = PrinterKind.BAMBU
        return cls(
            serial=str(value.get("serial", "")),
            name=str(value.get("name", "")),
            host=str(value.get("host", "")),
            model=str(value.get("model", "Bambu Lab")),
            port=int(value.get("port") or kind.default_port),
            kind=kind,
        )


def _number(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _integer(value: Any) -> int | None:
    number = _number(value)
    return int(number) if number is not None else None


def _fan_percent(value: Any) -> int | None:
    """Bambu reports fan speed as a 0-15 gear; convert to a percentage. A value already above 15 is
    treated as a direct percentage (some firmwares/models)."""
    raw = _integer(value)
    if raw is None:
        return None
    if raw > 15:
        return min(raw, 100)
    return int(round(raw / 15.0 * 100))


def _nfc_grams(tray: dict[str, Any]) -> float | None:
    """Remaining grams from an AMS NFC/RFID tray: tray_weight (nominal grams) scaled by remain (%).
    None for a spool whose tag carries no weight (non-RFID / third-party)."""
    nominal = _number(tray.get("tray_weight"))
    if nominal is None or nominal <= 0:
        return None
    remain = _integer(tray.get("remain"))
    remain = 100 if remain is None else max(0, min(remain, 100))
    return nominal * remain / 100.0


def _display_name(value: str) -> str:
    value = urllib.parse.unquote(value)
    if any(marker in value for marker in ("Ã", "Å", "Ä")):
        try:
            value = value.encode("cp1252").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    return value


def _state(value: Any) -> PrinterState:
    name = str(value or "").upper()
    if name in {"RUNNING", "PREPARE"}:
        return PrinterState.PRINTING
    if name in {"PAUSE", "PAUSED"}:
        return PrinterState.PAUSED
    if name in {"FINISH", "FINISHED"}:
        return PrinterState.FINISHED
    if name in {"FAILED", "ERROR"}:
        return PrinterState.ERROR
    return PrinterState.IDLE


def _parse_ams_groups(value: dict[str, Any], external_trays: list[dict[str, Any]],
                      external_authoritative: bool,
                      previous: list[FilamentGroup]) -> list[FilamentGroup] | None:
    """One FilamentGroup per physical unit (ams.ams[]) plus EXT groups for the external spools
    (vt_tray / vir_slot, gathered by the caller). Returns None for a pure-partial report so the
    caller keeps its previous groups untouched."""
    has_tray_now = "tray_now" in value
    active_raw = str(value.get("tray_now", ""))
    # Only trust tray_now when it names a real slot; otherwise fall back to the previously active slot
    # so a report carrying the tray list without tray_now does not clear the active ring.
    active_authoritative = has_tray_now and active_raw not in ("", "255")
    previous_active = next((s.slot_id for g in previous for s in g.slots if s.active), None)

    def resolve_active(slot_id: str, matches: bool) -> bool:
        return matches if active_authoritative else slot_id == previous_active

    groups: list[FilamentGroup] = []
    has_ams_payload = "ams" in value
    units = value.get("ams") if isinstance(value.get("ams"), list) else []
    for unit_index, unit in enumerate(units):
        if not isinstance(unit, dict):
            continue
        unit_id = str(unit.get("id", unit_index))
        letter = chr(65 + min(unit_index, 25))
        trays = unit.get("tray") if isinstance(unit.get("tray"), list) else []
        is_single = unit_id == "128" or (len(trays) == 1 and unit_id != str(unit_index))
        capacity = 1 if is_single else 4
        slots: list[FilamentSlot] = []
        for tray_index in range(capacity):
            tray = trays[tray_index] if tray_index < len(trays) and isinstance(trays[tray_index], dict) else {}
            tray_id = str(tray.get("id", tray_index))
            raw_material = tray.get("tray_type") or tray.get("tray_sub_brands")
            material = str(raw_material) if raw_material else None
            slot_id = f"ams-{unit_id}-{tray_id}"
            global_index = unit_index * 4 + tray_index
            matches = active_raw in {str(global_index), f"{unit_id}{tray_id}"}
            slots.append(FilamentSlot(
                slot_id=slot_id,
                label=f"{letter}{tray_index + 1}",
                material=material,
                color=str(tray.get("tray_color") or "8E8E93FF") if material else None,
                remaining=_integer(tray.get("remain")) if material else None,
                active=resolve_active(slot_id, matches),
                remaining_weight_g=_nfc_grams(tray) if material else None,
            ))
        # Keep the last known humidity/temperature when a mid-print report omits them.
        previous_unit = next((g for g in previous if g.group_id == f"ams-{unit_id}"), None)
        humidity = _integer(unit.get("humidity_raw", unit.get("humidity")))
        if humidity is None and previous_unit is not None:
            humidity = previous_unit.humidity
        temperature = _number(unit.get("temp"))
        if temperature is None and previous_unit is not None:
            temperature = previous_unit.temperature
        groups.append(FilamentGroup(
            group_id=f"ams-{unit_id}",
            source_type="amsHT" if is_single else "ams",
            display_name="AMS HT" if unit_id == "128" else f"AMS {letter}",
            declared_capacity=capacity,
            external=False,
            humidity=humidity,
            temperature=temperature,
            slots=slots,
        ))

    multiple_externals = len(external_trays) > 1
    for ext_index, external in enumerate(external_trays):
        raw_material = external.get("tray_type") or external.get("tray_sub_brands")
        material = str(raw_material) if raw_material else None
        tray_id = str(external.get("id", "254"))
        slot_id = f"external-{tray_id}"
        matches = active_raw in {tray_id, "254", "255"}
        # Show when a spool is loaded, or when actively fed even if this partial report lacks the type.
        if material is None and not (active_authoritative and matches):
            continue
        label = f"EXT {ext_index + 1}" if multiple_externals else "EXT"
        groups.append(FilamentGroup(
            group_id=slot_id,
            source_type="external",
            display_name=label,
            declared_capacity=1,
            external=True,
            slots=[FilamentSlot(
                slot_id=slot_id, label=label, material=material,
                color=(str(external.get("tray_color") or "E8E8E8FF")) if material else None,
                remaining=_integer(external.get("remain")) if material else None,
                active=resolve_active(slot_id, matches),
                remaining_weight_g=_nfc_grams(external) if material else None,
            )],
        ))

    # Bambu sends AMS and external-tray data in independent partial reports. A report carrying only
    # vt_tray / vir_slot must update EXT without temporarily deleting every AMS unit; conversely an
    # AMS-only report must not make EXT blink out. Preserve the side missing from this packet and
    # replace only the authoritative side, otherwise the card changes height and springs back.
    if not has_ams_payload:
        groups[:0] = [g for g in previous if not g.external]
    if not external_authoritative:
        groups.extend(g for g in previous if g.external)

    # Pure-partial report (no unit list, no external): keep the previously known modules.
    if not groups:
        return previous or None
    return groups


def parse_telemetry(payload: bytes | str | dict[str, Any], previous: Telemetry | None = None) -> Telemetry | None:
    try:
        root = json.loads(payload) if isinstance(payload, (bytes, str)) else payload
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(root, dict):
        return None
    report = root.get("print") or root.get("pushing")
    if not isinstance(report, dict):
        return None
    old = previous or Telemetry()
    result = Telemetry(**{name: getattr(old, name) for name in Telemetry.__dataclass_fields__})
    if "gcode_state" in report:
        result.state = _state(report["gcode_state"])
    value = _integer(report.get("mc_percent"))
    if value is not None:
        result.progress = min(max(value, 0), 100)
    mappings = {
        "mc_remaining_time": "remaining_minutes", "nozzle_temper": "nozzle",
        "nozzle_target_temper": "nozzle_target", "bed_temper": "bed",
        "bed_target_temper": "bed_target", "layer_num": "current_layer",
        "total_layer_num": "total_layers",
    }
    for source, target in mappings.items():
        if source in report:
            setattr(result, target, _integer(report[source]) if "layer" in source or source == "mc_remaining_time" else _number(report[source]))
    device = report.get("device")
    modern_chamber = False
    if isinstance(device, dict):
        ctc = device.get("ctc")
        info = ctc.get("info") if isinstance(ctc, dict) else None
        if isinstance(info, dict) and _number(info.get("temp")) is not None:
            # A heated chamber (H2D) packs this field like the nozzles: current reading in the low
            # 16 bits, setpoint in the high ones. Machines that only measure the chamber send a
            # plain reading, which never reaches one packed unit. Read raw, a 65 degree setpoint
            # showed up as 4259904.
            raw = _number(info["temp"])
            packed = _integer(info["temp"])
            if raw is not None and raw >= 65536 and packed is not None:
                result.chamber = float(packed & 0xFFFF)
                result.chamber_target = float((packed >> 16) & 0xFFFF)
            else:
                result.chamber = raw
            modern_chamber = True
        extruder = device.get("extruder")
        items = extruder.get("info") if isinstance(extruder, dict) else None
        if isinstance(items, list):
            by_id: dict[int, tuple[int, int]] = {}
            for item in items:
                if not isinstance(item, dict):
                    continue
                index, packed = _integer(item.get("id")), _integer(item.get("temp"))
                if index is not None and packed is not None:
                    by_id[index] = (packed & 0xFFFF, (packed >> 16) & 0xFFFF)
            # On the H2D / X2D the LEFT (main) nozzle is id 1 and the RIGHT is id 0, so the primary
            # reading (nozzle, shown as "L") comes from id 1.
            if 1 in by_id:
                result.nozzle, result.nozzle_target = by_id[1]        # left / main nozzle
                if 0 in by_id:
                    result.nozzle2, result.nozzle2_target = by_id[0]  # right nozzle
            elif 0 in by_id:
                result.nozzle, result.nozzle_target = by_id[0]
    if not modern_chamber and (fallback := _number(report.get("chamber_temper"))) is not None and fallback > 10:
        result.chamber = fallback
    # Fans (part / aux / chamber), speed level+magnitude and nozzle diameter for the Details view.
    if "cooling_fan_speed" in report:
        result.part_fan = _fan_percent(report.get("cooling_fan_speed"))
    if "big_fan1_speed" in report:
        result.aux_fan = _fan_percent(report.get("big_fan1_speed"))
    if "big_fan2_speed" in report:
        result.chamber_fan = _fan_percent(report.get("big_fan2_speed"))
    if "spd_lvl" in report:
        result.speed_level = _integer(report.get("spd_lvl"))
    if "spd_mag" in report:
        result.speed_percent = _integer(report.get("spd_mag"))
    diameter = _number(report.get("nozzle_diameter"))
    if diameter is not None and diameter > 0:
        result.nozzle_diameter = diameter
    stage = report.get("stage")
    result.stage = _integer(stage.get("_id")) if isinstance(stage, dict) else _integer(report.get("stg_cur"))
    if str(report.get("print_type", "")).lower() == "idle" and result.stage == 0:
        result.stage = 255
    if report.get("subtask_name"):
        result.job_name = _display_name(str(report["subtask_name"]))
    # The printed file, e.g. "vase.gcode.3mf" — needed to fetch its per-filament used_g after a finish.
    gcode_file = report.get("gcode_file") or report.get("subtask_name")
    if gcode_file:
        result.gcode_file = str(gcode_file)
    if "print_error" in report:
        try:
            result.error_code = int(str(report["print_error"]), 0)
        except ValueError:
            try:
                result.error_code = int(str(report["print_error"]).removeprefix("0x"), 16)
            except ValueError:
                result.error_code = 0
    if isinstance(report.get("hms"), list):
        codes: list[str] = []
        for item in report["hms"]:
            if not isinstance(item, dict):
                continue
            if item.get("ecode"):
                codes.append(str(item["ecode"]).replace("_", "").upper())
                continue
            code, attr = _integer(item.get("code")), _integer(item.get("attr")) or 0
            if code is not None:
                codes.append(f"{attr:08X}{code:08X}")
        result.hms_codes = codes
    # External spools live in different places: older firmwares use a single vt_tray dict (inside
    # print.ams or at the top level); the H2D family (AMS HT models) uses a print.vir_slot list.
    ams_obj = report.get("ams") if isinstance(report.get("ams"), dict) else None
    external_trays: list[dict[str, Any]] = []
    seen_ext_ids: set[str] = set()
    has_external_payload = ("vir_slot" in report or "vt_tray" in report
                            or (ams_obj is not None and "vt_tray" in ams_obj))

    def _add_external(candidate: Any) -> None:
        if not isinstance(candidate, dict):
            return
        ext_id = str(candidate.get("id", ""))
        if ext_id:
            if ext_id in seen_ext_ids:
                return
            seen_ext_ids.add(ext_id)
        external_trays.append(candidate)

    if isinstance(report.get("vir_slot"), list):
        for slot in report["vir_slot"]:
            _add_external(slot)
    _add_external((ams_obj or {}).get("vt_tray") or report.get("vt_tray"))

    if ams_obj is not None or external_trays:
        groups = _parse_ams_groups(ams_obj or {}, external_trays, has_external_payload,
                                   result.filament_groups)
        if groups is not None:
            result.filament_groups = groups
        # Flat compatibility view + legacy humidity/temp for compact rows / notifications.
        flat = [slot for group in result.filament_groups for slot in group.legacy_slots()]
        if flat:
            result.ams_slots = flat
        humidity = next((g.humidity for g in result.filament_groups if g.humidity is not None), None)
        if humidity is not None:
            result.ams_humidity = humidity
        temperature = next((g.temperature for g in result.filament_groups if g.temperature is not None), None)
        if temperature is not None:
            result.ams_temperature = temperature
    # Publish the nozzle collection the card renders; starting from `previous` means a partial report
    # that omits the second extruder keeps the last known right-nozzle values.
    if result.nozzle2 is not None or result.nozzle2_target is not None:
        result.nozzles = [
            NozzleTelemetry("left", result.nozzle, result.nozzle_target),
            NozzleTelemetry("right", result.nozzle2, result.nozzle2_target),
        ]
    else:
        result.nozzles = [NozzleTelemetry("single", result.nozzle, result.nozzle_target)]
    if result.error_code:
        result.state = PrinterState.ERROR
    return result


MAX_SCAN_HOSTS = 1024


def expand_scan_targets(text: str) -> list[str]:
    hosts: list[str] = []
    seen: set[str] = set()
    for raw in re.split(r"[,;\n\s]+", text.strip()):
        if not raw:
            continue
        expanded: list[ipaddress.IPv4Address]
        if "-" in raw:
            left, right = raw.split("-", 1)
            start, end = ipaddress.IPv4Address(left), ipaddress.IPv4Address(right)
            if int(end) < int(start) or int(end) - int(start) + 1 > MAX_SCAN_HOSTS:
                raise ValueError("range-too-large")
            expanded = [ipaddress.IPv4Address(value) for value in range(int(start), int(end) + 1)]
        elif "/" in raw:
            network = ipaddress.IPv4Network(raw, strict=False)
            count = network.num_addresses if network.prefixlen >= 31 else network.num_addresses - 2
            if count > MAX_SCAN_HOSTS:
                raise ValueError("range-too-large")
            expanded = list(network if network.prefixlen >= 31 else network.hosts())
        else:
            expanded = [ipaddress.IPv4Address(raw)]
        for address in expanded:
            value = str(address)
            if value not in seen:
                seen.add(value)
                hosts.append(value)
            if len(hosts) > MAX_SCAN_HOSTS:
                raise ValueError("range-too-large")
    return hosts


def studio_devices_from_content(content: str) -> list[tuple[str, str, str | None]]:
    stripped = content.lstrip("\ufeff \t\r\n")
    sections: dict[str, dict[str, str]] = {}
    if stripped.startswith("{"):
        end = stripped.rfind("}")
        if end < 0:
            raise ValueError("invalid-studio-config")
        root = json.loads(stripped[:end + 1])
        sections = {key: {str(k): str(v) for k, v in value.items() if isinstance(v, str)}
                    for key, value in root.items() if isinstance(value, dict)}
    else:
        current: dict[str, str] | None = None
        for raw in content.splitlines():
            line = raw.strip()
            if not line or line.startswith(("#", ";")):
                continue
            if line.startswith("[") and line.endswith("]"):
                current = sections.setdefault(line[1:-1].strip(), {})
            elif current is not None and "=" in line:
                key, value = line.split("=", 1)
                current[key.strip()] = value.strip()
    codes = dict(sections.get("access_code", {}))
    codes.update(sections.get("user_access_code", {}))
    addresses = dict(sections.get("ip_address", {}))
    for serial, host in sections.get("user_access_dev_ip", {}).items():
        try:
            ipaddress.ip_address(host)
            addresses[serial] = host
        except ValueError:
            pass
    return [(serial, code, addresses.get(serial)) for serial, code in codes.items() if serial and code]


def printer_to_dict(printer: Printer) -> dict[str, Any]:
    return asdict(printer)
