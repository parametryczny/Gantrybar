"""Physical filament rolls for Spoolbase (grams), with the same on-disk JSON as macOS/Windows so the
same store file reads on every platform. Pure Python (no GTK) so it stays unit-testable.

State belongs to the roll, not the slot: a roll carries its grams wherever it is assigned. Files live
in ``$XDG_DATA_HOME/Spoolbase/`` next to the filament catalogue.
"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))) / "Spoolbase"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(value: Any) -> datetime:
    if not isinstance(value, str) or not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    text = value.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def same_slot(a: dict[str, Any], b: dict[str, Any]) -> bool:
    """Two SpoolLocation dicts point at the same physical slot (never true for storage)."""
    if not a or not b:
        return False
    if a.get("printerSerial") is None or b.get("printerSerial") is None:
        return False
    return (a.get("printerSerial") == b.get("printerSerial")
            and a.get("feeder") == b.get("feeder")
            and a.get("amsIndex") == b.get("amsIndex")
            and a.get("slot") == b.get("slot"))


def location_for(serial: str, external: bool, ams_index: int, slot: int) -> dict[str, Any]:
    return {"printerSerial": serial, "feeder": "ext" if external else "ams", "amsIndex": ams_index, "slot": slot}


class PhysicalSpoolStore:
    """Spools and their consumption history, as lists of plain dicts (the JSON shape itself)."""

    def __init__(self, spools_path: Path | None = None, usage_path: Path | None = None) -> None:
        self._spools_path = spools_path or (_DATA_DIR / "spools-v1.json")
        self._usage_path = usage_path or (_DATA_DIR / "usage-v1.json")
        self.spools: list[dict[str, Any]] = _load(self._spools_path)
        self.usage: list[dict[str, Any]] = _load(self._usage_path)
        self.on_change = None  # optional callback

    # --- lookup ---------------------------------------------------------------
    def spool_at(self, location: dict[str, Any]) -> dict[str, Any] | None:
        if not location or location.get("printerSerial") is None:
            return None
        return next((s for s in self.spools if same_slot(s.get("location", {}), location)), None)

    def spool(self, spool_id: str) -> dict[str, Any] | None:
        return next((s for s in self.spools if s.get("id") == spool_id), None)

    @staticmethod
    def percent(spool: dict[str, Any]) -> int:
        nominal = float(spool.get("nominalWeightGrams", 0) or 0)
        if nominal <= 0:
            return 0
        return int(round(float(spool.get("remainingWeightGrams", 0) or 0) / nominal * 100))

    def spools_for_definition(self, definition_id: str) -> list[dict[str, Any]]:
        return [s for s in self.spools if s.get("filamentDefinitionID") == definition_id]

    def next_spool_id(self) -> str:
        highest = 0
        for spool in self.spools:
            sid = str(spool.get("id", ""))
            if sid.startswith("SP-") and sid[3:].isdigit():
                highest = max(highest, int(sid[3:]))
        return f"SP-{highest + 1:05d}"

    # --- mutation -------------------------------------------------------------
    def add(self, spool: dict[str, Any]) -> None:
        self.spools.append(spool)
        self._save()
        if callable(self.on_change):
            self.on_change()

    def create_rolls(self, definition_id: str, count: int, weight: float,
                     remaining: float | None = None) -> list[dict[str, Any]]:
        """Create real rolls for a Spoolbase definition and leave them in storage."""
        created: list[dict[str, Any]] = []
        nominal = max(0.0, float(weight))
        for _ in range(max(0, int(count))):
            rest = nominal if remaining is None else max(0.0, min(float(remaining), nominal))
            now = _now_iso()
            spool = {
                "id": self.next_spool_id(),
                "filamentDefinitionID": definition_id,
                "nominalWeightGrams": nominal,
                "remainingWeightGrams": rest,
                "status": "new" if rest >= nominal else "active",
                "location": {},
                "notes": "",
                "createdAt": now,
                "updatedAt": now,
                "openedAt": None if rest >= nominal else now,
                "totalConsumedGrams": 0.0,
            }
            self.spools.append(spool)
            created.append(spool)
        if created:
            self._save()
            if callable(self.on_change):
                self.on_change()
        return created

    def delete(self, spool_id: str) -> None:
        before = len(self.spools)
        self.spools = [spool for spool in self.spools if spool.get("id") != spool_id]
        if len(self.spools) == before:
            return
        self._save()
        if callable(self.on_change):
            self.on_change()

    def create_spool(self, definition_id: str | None, nominal: float, remaining: float,
                     location: dict[str, Any]) -> dict[str, Any]:
        """Make a new physical roll and drop it straight into a slot (bumping whatever was there)."""
        now = _now_iso()
        spool = {
            "id": self.next_spool_id(),
            "filamentDefinitionID": definition_id,
            "nominalWeightGrams": float(nominal),
            "remainingWeightGrams": max(0.0, min(float(remaining), float(nominal))),
            "status": "active",
            "location": {},
            "notes": "",
            "createdAt": now,
            "updatedAt": now,
            "openedAt": now,
            "totalConsumedGrams": 0.0,
        }
        self.spools.append(spool)
        self.assign(spool["id"], location)   # assign saves + notifies
        return spool

    def assign(self, spool_id: str, location: dict[str, Any]) -> None:
        """Move a roll into a slot. One roll per slot: anything already there goes back to storage."""
        target = self.spool(spool_id)
        if target is None:
            return
        is_storage = location.get("printerSerial") is None
        if not is_storage:
            for other in self.spools:
                if other is not target and same_slot(other.get("location", {}), location):
                    other["location"] = {}
                    if other.get("status") == "active":
                        other["status"] = "stored"
                    other["updatedAt"] = _now_iso()
        target["location"] = dict(location)
        if not is_storage:
            target["status"] = "empty" if float(target.get("remainingWeightGrams", 0) or 0) <= 0 else "active"
            target.setdefault("openedAt", _now_iso())
        elif target.get("status") == "active":
            target["status"] = "stored"
        target["updatedAt"] = _now_iso()
        self._save()
        if callable(self.on_change):
            self.on_change()

    def set_remaining(self, spool_id: str, grams: float) -> None:
        spool = self.spool(spool_id)
        if spool is None:
            return
        nominal = float(spool.get("nominalWeightGrams", 0) or 0)
        value = max(0.0, min(float(grams), nominal) if nominal > 0 else float(grams))
        spool["remainingWeightGrams"] = value
        if value <= 0:
            spool["status"] = "empty"
        spool["updatedAt"] = _now_iso()
        self._save()
        if callable(self.on_change):
            self.on_change()

    def correct_weight(self, spool_id: str, net_grams: float, tare: float | None = None) -> None:
        spool = self.spool(spool_id)
        if spool is None:
            return
        nominal = float(spool.get("nominalWeightGrams", 0) or 0)
        spool["remainingWeightGrams"] = max(0.0, min(float(net_grams), nominal))
        if tare is not None:
            spool["tareGrams"] = max(0.0, float(tare))
        spool["weighedAt"] = _now_iso()
        if spool["remainingWeightGrams"] <= 0:
            spool["status"] = "empty"
            spool["emptiedAt"] = _now_iso()
        elif spool.get("status") == "empty":
            spool["status"] = "stored" if spool.get("location", {}).get("printerSerial") is None else "active"
            spool.pop("emptiedAt", None)
        spool["updatedAt"] = _now_iso()
        self._save()
        if callable(self.on_change):
            self.on_change()

    def reset_to_full(self, spool_id: str, nominal: float | None = None) -> None:
        spool = self.spool(spool_id)
        if spool is None:
            return
        full = max(0.0, float(nominal if nominal is not None else spool.get("nominalWeightGrams", 0) or 0))
        spool["nominalWeightGrams"] = full
        spool["remainingWeightGrams"] = full
        spool["totalConsumedGrams"] = 0.0
        spool["openedAt"] = None
        spool.pop("emptiedAt", None)
        spool.pop("weighedAt", None)
        spool["status"] = "new" if spool.get("location", {}).get("printerSerial") is None else "active"
        spool["updatedAt"] = _now_iso()
        self._save()
        if callable(self.on_change):
            self.on_change()

    # --- mutation -------------------------------------------------------------
    def clear_slot(self, location: dict[str, Any]) -> None:
        spool = self.spool_at(location)
        if spool is None:
            return
        spool["location"] = {}
        if spool.get("status") == "active":
            spool["status"] = "stored"
        spool["updatedAt"] = _now_iso()
        self._save()
        if callable(self.on_change):
            self.on_change()

    def detach_assignments_replaced_by_nfc(self, serial: str, previous_groups: list, current_groups: list) -> list[tuple[str, str]]:
        """A newly-inserted RFID/NFC roll supersedes a stale manual assignment in that slot: send the
        assigned roll back to storage. Fires only on the insert transition. Returns (spool_id, slot)."""
        detached: list[tuple[str, str]] = []
        for gi, group in enumerate(current_groups):
            for si, slot in enumerate(getattr(group, "slots", [])):
                if getattr(slot, "remaining_weight_g", None) is None:
                    continue
                had_nfc = (gi < len(previous_groups) and si < len(getattr(previous_groups[gi], "slots", []))
                           and getattr(previous_groups[gi].slots[si], "remaining_weight_g", None) is not None)
                if had_nfc:
                    continue
                loc = location_for(serial, getattr(group, "external", False), gi, si)
                assigned = self.spool_at(loc)
                if assigned is not None:
                    label = group.display_name if getattr(group, "external", False) else f"{group.display_name} {slot.label}"
                    self.clear_slot(loc)
                    detached.append((assigned.get("id", "?"), label))
        return detached

    def consume(self, spool_id: str, grams: float, printer_serial: str, print_job_id: str) -> bool:
        """Subtract filament for a finished job. Idempotent per (printJobID, spoolID) so a reconnect or a
        second machine watching the same printer never double-counts."""
        if grams <= 0:
            return False
        if any(u.get("printJobID") == print_job_id and u.get("spoolID") == spool_id for u in self.usage):
            return False
        spool = self.spool(spool_id)
        if spool is None:
            return False
        remaining = max(0.0, float(spool.get("remainingWeightGrams", 0) or 0) - grams)
        spool["remainingWeightGrams"] = remaining
        spool["totalConsumedGrams"] = float(spool.get("totalConsumedGrams", 0) or 0) + grams
        spool["lastUsedAt"] = _now_iso()
        spool["updatedAt"] = _now_iso()
        if remaining <= 0:
            spool["status"] = "empty"
            spool["emptiedAt"] = _now_iso()
        self.usage.append({"id": str(uuid.uuid4()), "spoolID": spool_id, "printerSerial": printer_serial,
                           "printJobID": print_job_id, "consumedGrams": grams, "timestamp": _now_iso()})
        self._save()
        if callable(self.on_change):
            self.on_change()
        return True

    def _save(self) -> None:
        _save(self._spools_path, self.spools)
        _save(self._usage_path, self.usage)


def _load(path: Path) -> list[dict[str, Any]]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return []


def _save(path: Path, value: list[dict[str, Any]]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=True))
    except Exception:
        pass
