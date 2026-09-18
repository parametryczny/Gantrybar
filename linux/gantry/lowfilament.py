"""Which loaded rolls are running low, and which roll ran out (port of LowFilament.swift).

Two sources Gantry can trust: a roll assigned in Spoolbase, whose grams Gantry counts down itself, and
otherwise a Bambu roll with an RFID/NFC tag, whose percentage comes from the printer. A chipless roll
without a Spoolbase assignment has no reliable level and is never reported (issue #27).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from .physicalspool import location_for

# A tagged roll at or below this share of its weight is low.
PERCENT_THRESHOLD = 15
# A Spoolbase roll at or below this many grams is low.
GRAMS_THRESHOLD = 100.0
# Bambu print stage 6: paused because the filament ran out.
RUNOUT_STAGE = 6


@dataclass(frozen=True)
class LowSlot:
    key: str        # unit index and slot index, stable within one printer
    label: str
    material: str
    amount: str     # "12%" for a tagged roll, "85 g" for a Spoolbase roll

    def describe(self) -> str:
        return " • ".join(part for part in (self.label, self.material, self.amount) if part)


def low_slots(serial: str, groups: list[Any],
              assigned_spool: Callable[[dict[str, Any]], dict[str, Any] | None]) -> list[LowSlot]:
    result: list[LowSlot] = []
    for group_index, group in enumerate(groups):
        for slot_index, slot in enumerate(group.slots):
            key = f"{group_index}-{slot_index}"
            spool = assigned_spool(location_for(serial, group.external, group_index, slot_index))
            # Spoolbase first: an assignment is the user's own record of the roll and outranks the tag.
            if spool is not None:
                grams = float(spool.get("remainingWeightGrams", 0) or 0)
                if grams <= GRAMS_THRESHOLD:
                    material = (slot.material if slot.present else None) or str(spool.get("id", ""))
                    result.append(LowSlot(key, slot.label, material, f"{int(grams + 0.5)} g"))
                continue
            if (slot.present and slot.remaining_weight_g is not None and slot.remaining is not None
                    and slot.remaining <= PERCENT_THRESHOLD):
                result.append(LowSlot(key, slot.label, slot.material or "", f"{slot.remaining}%"))
    return result


def feeding_slot(previous: list[Any] | None, current: list[Any]) -> Any | None:
    """The roll that was feeding when the printer stopped: the active slot of the last report that had
    one, because the report that carries the pause may already have cleared it."""
    for groups in (current, previous or []):
        for group in groups:
            for slot in group.slots:
                if slot.active:
                    return slot
    return None
