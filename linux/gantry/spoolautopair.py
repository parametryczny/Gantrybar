"""Pairs a Bambu RFID roll loaded in an AMS with its roll in Spoolbase, so what the print used is
charged to that roll and priced with what you paid for it, not with the slicer's price. Port of
macOS ``SpoolAutoPair``; pure Python (no GTK) so it stays unit-testable.

A roll with an RFID tag carries its own id. The first time a tag shows up, Gantry looks for the
product in Spoolbase (same material, closest colour, Bambu Lab first, the tag's product name
preferred) and takes a roll of it from storage, or adds one priced like that product. The tag is
kept on the roll (``tagUID``), so the next time that roll goes into any slot of any printer it is
recognised straight away. A roll you assigned by hand to a slot is never replaced, and rolls without
a tag (third-party filament) are left for you to assign.
"""

from __future__ import annotations

from typing import Any, Iterable

from . import i18n
from .farm import color_distance
from .physicalspool import _parse_iso, location_for


def pair(serial: str, groups: Iterable[Any], spools: Any, filaments: list[Any]) -> list[str]:
    """Pairs every tagged, unpaired roll in these groups and returns one line per pairing, for the
    card. The caller checks that Spoolbase and the pairing setting are both on."""
    notices: list[str] = []
    for group_index, group in enumerate(groups):
        external = bool(getattr(group, "external", False))
        for slot_index, slot in enumerate(getattr(group, "slots", [])):
            uid = getattr(slot, "spool_uid", None)
            if not slot.present or not uid:
                continue
            location = location_for(serial, external, group_index, slot_index)
            current = spools.spool_at(location)
            if current is not None and current.get("tagUID") == uid:
                continue
            # A roll assigned by hand stays: only an empty slot or one holding another tagged roll
            # (taken out and replaced) is paired again.
            if current is not None and not current.get("tagUID"):
                continue
            slot_name = group.display_name if external else f"{group.display_name} {slot.label}"

            known = next((s for s in spools.spools if s.get("tagUID") == uid), None)
            if known is not None:
                spools.assign(known["id"], location)
                notices.append(i18n.t("{0} recognised in {1}").format(known["id"], slot_name))
                continue
            product = best_product(slot, filaments)
            if product is None:
                continue
            waiting = [s for s in spools.spools_for_definition(product.id)
                       if not (s.get("location") or {}).get("printerSerial") and not s.get("tagUID")
                       and s.get("status") not in ("empty", "archived")]
            # An opened roll first, then the oldest: the one most likely to be the roll in hand.
            waiting.sort(key=lambda s: (s.get("openedAt") is None, _parse_iso(s.get("createdAt"))))
            if waiting:
                roll = waiting[0]
            else:
                weight = slot.nominal_grams if slot.nominal_grams is not None else 1000.0
                price = product.pricePerRoll if product.pricePerRoll is not None else spools.last_price(product.id)
                created = spools.create_rolls(product.id, 1, weight, remaining=slot.remaining_weight_g, price=price)
                if not created:
                    continue
                roll = created[0]
            spools.set_tag(roll["id"], uid)
            spools.assign(roll["id"], location)
            notices.append(i18n.t("{0} ({1}) paired with {2}").format(
                roll["id"], f"{product.brand} {product.name}", slot_name))
    return notices


def best_product(slot: Any, filaments: list[Any]) -> Any | None:
    """The Spoolbase product a tagged roll most likely is: same material, colour within reach, then
    Bambu Lab and a name that contains the tag's product name."""
    material = (getattr(slot, "material", None) or "").strip()
    if not material:
        return None
    wanted = (getattr(slot, "product_name", None) or "").upper()
    best: tuple[float, Any] | None = None
    for filament in filaments:
        if filament.type.casefold() != material.casefold():
            continue
        distance = color_distance(filament.colorHex, getattr(slot, "color", None) or "")
        if distance is None or distance > 60:
            continue
        score = distance
        if "bambu" not in filament.brand.casefold():
            score += 100
        if wanted and wanted not in f"{filament.brand} {filament.name}".upper():
            score += 40
        if best is None or score < best[0]:
            best = (score, filament)
    return best[1] if best is not None else None
