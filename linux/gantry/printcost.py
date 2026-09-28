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
#: PrintCostSettings.Business on macOS, in the order the Pricing pane lists them.
BUSINESSES = ("unregistered", "company", "companyVAT")


@dataclass
class PrintCostSettings:
    currency: str = "PLN"
    filamentPerKg: float = 80.0
    materialPerKg: dict[str, float] | None = None
    electricityPerKWh: float = 1.0
    printerWatts: float = 150.0
    watts: dict[str, float] | None = None
    machinePerHour: float = 0.0
    # Selling (Settings → Pricing). Same names and defaults as macOS, so one JSON serves all three.
    #: "unregistered" (no VAT, PIT scale), "company" (VAT-exempt) or "companyVAT" (charges VAT).
    business: str = "unregistered"
    #: Income tax in percent, from the profit, or from the revenue when taxOnRevenue (ryczałt).
    incomeTaxPercent: float = 12.0
    taxOnRevenue: bool = False
    vatPercent: float = 23.0
    #: Mark-up on everything it costs to make and ship one print.
    marginPercent: float = 30.0
    #: A marketplace's cut of the gross price (Allegro, Etsy).
    platformFeePercent: float = 0.0
    laborPerHour: float = 0.0
    laborMinutes: float = 10.0
    #: Box, filler and label per order.
    packaging: float = 0.0
    #: Extra material and machine time set aside for prints that fail, in percent.
    failurePercent: float = 5.0

    @classmethod
    def from_dict(cls, data: Any) -> "PrintCostSettings":
        value = cls()
        if not isinstance(data, dict):
            return value
        for key in ("filamentPerKg", "electricityPerKWh", "printerWatts", "machinePerHour",
                    "incomeTaxPercent", "vatPercent", "marginPercent", "platformFeePercent",
                    "laborPerHour", "laborMinutes", "packaging", "failurePercent"):
            if isinstance(data.get(key), bool):
                continue
            try:
                setattr(value, key, max(0.0, float(data.get(key, getattr(value, key)))))
            except (TypeError, ValueError):
                pass
        if isinstance(data.get("currency"), str) and data["currency"].strip():
            value.currency = data["currency"].strip()[:8]
        if data.get("business") in BUSINESSES:
            value.business = data["business"]
        if isinstance(data.get("taxOnRevenue"), bool):
            value.taxOnRevenue = data["taxOnRevenue"]
        for key in ("materialPerKg", "watts"):
            raw = data.get(key)
            if isinstance(raw, dict):
                setattr(value, key, {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float))})
        return value

    def to_dict(self) -> dict[str, Any]:
        return {"currency": self.currency, "filamentPerKg": self.filamentPerKg,
                "materialPerKg": self.materialPerKg or {}, "electricityPerKWh": self.electricityPerKWh,
                "printerWatts": self.printerWatts, "watts": self.watts or {}, "machinePerHour": self.machinePerHour,
                "business": self.business, "incomeTaxPercent": self.incomeTaxPercent,
                "taxOnRevenue": self.taxOnRevenue, "vatPercent": self.vatPercent,
                "marginPercent": self.marginPercent, "platformFeePercent": self.platformFeePercent,
                "laborPerHour": self.laborPerHour, "laborMinutes": self.laborMinutes,
                "packaging": self.packaging, "failurePercent": self.failurePercent}

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


@dataclass
class SaleQuote:
    """What a print should sell for, built up from what it cost. Mirrors macOS SaleQuote.

    Costs first: the print itself (filament, electricity, machine time), an allowance for prints that
    fail, the hands-on work and the packaging. The mark-up is the profit wanted on top of those, after
    tax. The price is then solved so that, once the marketplace has taken its cut and the tax office
    its share, exactly that profit is left; VAT, when charged, goes on top::

        income tax on profit:     net = (costs + profit / (1 − tax)) / (1 − fee)
        tax on revenue (ryczałt): net = (costs + profit) / (1 − fee − tax)
        gross = net × (1 + VAT)

    The marketplace fee is charged on the gross price, which is how Allegro and Etsy bill it.
    An estimate for pricing, not tax advice.
    """
    print: float
    failures: float
    labor: float
    packaging: float
    profit: float
    fee: float
    tax: float
    vat: float
    net: float      # price without VAT
    gross: float    # what the customer pays
    complete: bool  # False when the filament use is unknown, so the price leaves the material out

    @property
    def costs(self) -> float:
        return self.print + self.failures + self.labor + self.packaging

    @classmethod
    def compute(cls, cost: PrintCost, settings: PrintCostSettings) -> "SaleQuote":
        s = settings
        printed = cost.total
        failures = printed * max(0.0, s.failurePercent) / 100
        labor = max(0.0, s.laborPerHour) * max(0.0, s.laborMinutes) / 60
        packaging = max(0.0, s.packaging)
        costs = printed + failures + labor + packaging
        profit = costs * max(0.0, s.marginPercent) / 100
        vat_rate = max(0.0, s.vatPercent) / 100 if s.business == "companyVAT" else 0.0
        tax_rate = min(0.9, max(0.0, s.incomeTaxPercent) / 100)
        # The fee is a share of the gross price; as a share of the net it is that times (1 + VAT).
        fee_rate = min(0.9, max(0.0, s.platformFeePercent) / 100)
        if s.taxOnRevenue:
            net = (costs + profit) / max(0.05, 1 - fee_rate - tax_rate)
        else:
            net = (costs + profit / max(0.05, 1 - tax_rate)) / max(0.05, 1 - fee_rate)
        gross = net * (1 + vat_rate)
        fee = gross * fee_rate / (1 + vat_rate)
        tax = net * tax_rate if s.taxOnRevenue else max(0.0, net - fee - costs) * tax_rate
        return cls(printed, failures, labor, packaging, profit, fee, tax, gross - net, net, gross,
                   cost.filament is not None)

    def breakdown(self, currency: str, t: Any = None) -> str:
        """The price and where it comes from, one line each, for the calculator."""
        if t is None:
            from . import i18n
            t = i18n.t

        def money(value: float) -> str:
            return f"{value:.2f} {currency}"
        lines = [t("Print (filament, power, machine): {0}").format(money(self.print)),
                 t("Failed prints allowance: {0}").format(money(self.failures)),
                 t("Labour: {0}").format(money(self.labor)),
                 t("Packaging: {0}").format(money(self.packaging)),
                 t("Profit after tax: {0}").format(money(self.profit)),
                 t("Marketplace fee: {0}").format(money(self.fee)),
                 t("Income tax: {0}").format(money(self.tax))]
        if self.vat > 0:
            lines.append(t("VAT: {0}").format(money(self.vat)))
            lines.append(t("Sell for {0} gross ({1} net)").format(money(self.gross), money(self.net)))
        else:
            lines.append(t("Sell for {0}").format(money(self.gross)))
        return "\n".join(lines)


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


def roll_price_per_kg(spool: dict[str, Any]) -> float | None:
    """Price of one kilogram of a roll's filament, from what the roll cost and its full weight."""
    price = spool.get("price")
    nominal = float(spool.get("nominalWeightGrams", 0) or 0)
    if not isinstance(price, (int, float)) or price < 0 or nominal <= 0:
        return None
    return float(price) / nominal * 1000


def spoolbase_price_per_kg(filament: Any, spools: Any) -> float | None:
    """What a kilogram of this Spoolbase product costs: the average over its rolls that have a price,
    otherwise the product's price per roll (a roll is taken as 1 kg when no roll says otherwise)."""
    rolls = [] if spools is None else [value for value in (roll_price_per_kg(spool) for spool in
                                                              spools.spools_for_definition(filament.id))
                                       if value is not None]
    if rolls:
        return sum(rolls) / len(rolls)
    price = getattr(filament, "pricePerRoll", None)
    return float(price) if isinstance(price, (int, float)) else None


def entry_times(item: dict[str, Any]) -> tuple[datetime, datetime]:
    """(started, ended) of a history entry; a missing start is the end minus the duration."""
    ended = _date(item.get("endedAt")) or datetime.min.replace(tzinfo=timezone.utc)
    started = _date(item.get("startedAt"))
    if started is None:
        started = ended - timedelta(seconds=float(item.get("durationSeconds", 0) or 0))
    return started, ended


def entry_cost(app: Any, serial: str, item: dict[str, Any], settings: PrintCostSettings) -> PrintCost:
    """What one history entry cost, with the filament Spoolbase recorded for it."""
    started, ended = entry_times(item)
    return compute(float(item.get("durationSeconds", 0) or 0), uses(app, serial, started, ended), serial, settings)


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
