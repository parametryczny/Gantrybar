"""Per-printer advanced overrides, stored in Gantry's regular config JSON."""
from __future__ import annotations

from typing import Any

FIELDS = ("cameraHost", "ledOn", "ledOff", "nozzleObject", "bedObject", "chamberObject", "fanObject")


def overrides_for(config: Any, serial: str) -> dict[str, str]:
    all_values = config.data.get("printer_overrides_v1", {})
    raw = all_values.get(serial, {}) if isinstance(all_values, dict) else {}
    return {field: str(raw.get(field, "")).strip() for field in FIELDS if str(raw.get(field, "")).strip()}


def set_overrides(config: Any, serial: str, values: dict[str, str]) -> None:
    all_values = dict(config.data.get("printer_overrides_v1", {}))
    cleaned = {field: str(values.get(field, "")).strip() for field in FIELDS
               if str(values.get(field, "")).strip()}
    if cleaned:
        all_values[serial] = cleaned
    else:
        all_values.pop(serial, None)
    config.data["printer_overrides_v1"] = all_values
    config.save()


def moonraker_objects(values: dict[str, str]) -> dict[str, str | None]:
    return {
        "nozzle": values.get("nozzleObject") or "extruder",
        "bed": values.get("bedObject") or "heater_bed",
        "chamber": values.get("chamberObject") or None,
        "fan": values.get("fanObject") or "fan",
    }
