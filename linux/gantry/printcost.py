from __future__ import annotations

"""What a print cost: filament, electricity and machine time. Mirrors macOS PrintCost.

Settings share the JSON of macOS and Windows (``print-cost-settings-v1`` in the config). No GTK here, so
the arithmetic is unit-tested headless; fleetstats draws it.
"""

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

CONFIG_KEY = "print-cost-settings-v1"


@dataclass
class PrintCostSettings:
    currency: str = "PLN"
    filamentPerKg: float = 80.0
    materialPerKg: dict[str, float] | None = None
    electricityPerKWh: float = 1.0
    printerWatts: float = 150.0
    watts: dict[str, float] | None = None
    machinePerHour: float = 0.0

    @classmethod
    def from_dict(cls, data: Any) -> "PrintCostSettings":
        value = cls()
        if not isinstance(data, dict):
            return value
        for key in ("filamentPerKg", "electricityPerKWh", "printerWatts", "machinePerHour"):
            try:
                setattr(value, key, max(0.0, float(data.get(key, getattr(value, key)))))
            except (TypeError, ValueError):
                pass
        if isinstance(data.get("currency"), str) and data["currency"].strip():
            value.currency = data["currency"].strip()[:8]
        for key in ("materialPerKg", "watts"):
            raw = data.get(key)
            if isinstance(raw, dict):
                setattr(value, key, {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float))})
        return value

    def to_dict(self) -> dict[str, Any]:
        return {"currency": self.currency, "filamentPerKg": self.filamentPerKg,
                "materialPerKg": self.materialPerKg or {}, "electricityPerKWh": self.electricityPerKWh,
                "printerWatts": self.printerWatts, "watts": self.watts or {}, "machinePerHour": self.machinePerHour}

    def price_per_kg(self, material: str | None) -> float:
        return (self.materialPerKg or {}).get((material or "").strip().upper(), self.filamentPerKg)

    def power(self, serial: str) -> float:
        return (self.watts or {}).get(serial, self.printerWatts)


def load(config: Any) -> PrintCostSettings:
    return PrintCostSettings.from_dict(config.data.get(CONFIG_KEY))


def save(config: Any, settings: PrintCostSettings) -> None:
    config.data[CONFIG_KEY] = settings.to_dict()
    config.save()


def parse_material_prices(text: str) -> dict[str, float]:
    """"PETG=90, ASA=119,50; TPU = 140" → {"PETG": 90, "ASA": 119.5, "TPU": 140}."""
    result: dict[str, float] = {}
    for key, value in re.findall(r"([A-Za-z][A-Za-z0-9+\-]*)\s*=\s*([0-9]+(?:[.,][0-9]+)?)", text or ""):
        result[key.upper()] = float(value.replace(",", "."))
    return result


def parse_amount(text: str) -> float | None:
    try:
        value = float((text or "").strip().replace(",", "."))
    except ValueError:
        return None
    return value if value >= 0 else None


@dataclass
class Use:
    grams: float
    material: str | None = None
    price_per_kg: float | None = None


@dataclass
class PrintCost:
    filament: float | None
    grams: float | None
    energy: float
    machine: float
    kwh: float

    @property
    def total(self) -> float:
        return (self.filament or 0.0) + self.energy + self.machine


def compute(duration_seconds: float, uses: list[Use], serial: str, settings: PrintCostSettings) -> PrintCost:
    hours = max(0.0, float(duration_seconds)) / 3600
    kwh = hours * max(0.0, settings.power(serial)) / 1000
    grams = None if not uses else sum(max(0.0, use.grams) for use in uses)
    filament = None if not uses else sum(
        max(0.0, use.grams) / 1000 * max(0.0, use.price_per_kg if use.price_per_kg is not None else settings.price_per_kg(use.material))
        for use in uses)
    return PrintCost(filament, grams, kwh * max(0.0, settings.electricityPerKWh),
                     hours * max(0.0, settings.machinePerHour), kwh)


def _date(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def uses(app: Any, serial: str, started: datetime, ended: datetime) -> list[Use]:
    """Filament the print used, from Spoolbase's usage records written for this printer while it ran
    (a short grace after the end covers a late FINISH packet)."""
    spools = getattr(app, "physical_spools", None)
    filaments = getattr(getattr(app, "filament_store", None), "filaments", None) or []
    if spools is None:
        return []
    begin, finish = started - timedelta(minutes=1), ended + timedelta(minutes=10)
    by_id = {getattr(item, "id", None): item for item in filaments}
    result: list[Use] = []
    for event in getattr(spools, "usage", []):
        if not isinstance(event, dict) or event.get("printerSerial") != serial:
            continue
        when = _date(event.get("timestamp"))
        if when is None or when < begin or when > finish:
            continue
        spool = spools.spool(str(event.get("spoolID", ""))) if hasattr(spools, "spool") else None
        definition = by_id.get((spool or {}).get("filamentDefinitionID"))
        nominal = float((spool or {}).get("nominalWeightGrams", 0) or 0)
        per_kg = None
        price = (spool or {}).get("price")
        if isinstance(price, (int, float)) and price >= 0 and nominal > 0:
            per_kg = float(price) / nominal * 1000
        elif definition is not None and isinstance(getattr(definition, "pricePerRoll", None), (int, float)) and nominal > 0:
            per_kg = float(definition.pricePerRoll) / nominal * 1000
        result.append(Use(float(event.get("consumedGrams", 0) or 0), getattr(definition, "type", None), per_kg))
    return result


def ean_plausible(value: str) -> bool:
    """EAN-8 / UPC-A / EAN-13 / GTIN-14 check digit. Other code types (Code 128, QR) are left alone."""
    digits = "".join(ch for ch in value if not ch.isspace() and ch != "-")
    if not digits.isascii() or not digits.isdigit():
        return True
    if len(digits) not in (8, 12, 13, 14):
        return False
    numbers = [int(ch) for ch in digits]
    body = list(reversed(numbers[:-1]))
    total = sum(n * (3 if i % 2 == 0 else 1) for i, n in enumerate(body))
    return (10 - total % 10) % 10 == numbers[-1]
