"""GUI-free Spoolbase catalogue and inventory model shared by GTK and sync code."""
from __future__ import annotations

import json
import os
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

TYPES = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "ESD", "PVA", "Support"]

_DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "Spoolbase"
_INVENTORY = _DATA_DIR / "inventory-v2.json"
_CATALOG_EDIT = _DATA_DIR / "catalog.json"
_CATALOG_BUNDLED = Path(__file__).resolve().parent / "data" / "filament-catalog.json"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_iso(value: Any) -> datetime:
    if not isinstance(value, str) or not value:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def normalized_hex(value: str) -> str:
    filtered = (value or "").strip().lstrip("#").upper()
    if len(filtered) == 6 and all(character in "0123456789ABCDEF" for character in filtered):
        return filtered
    return "8E8E93"


@dataclass
class Filament:
    brand: str
    name: str
    type: str
    colorName: str
    colorHex: str
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    catalogID: str | None = None
    manufacturerCode: str = ""
    spoolCount: int = 0
    notes: str = ""
    updatedAt: str = field(default_factory=_now)

    def __post_init__(self) -> None:
        self.colorHex = normalized_hex(self.colorHex)
        self.spoolCount = max(0, int(self.spoolCount))

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Filament":
        return cls(
            brand=data.get("brand", ""), name=data.get("name", ""), type=data.get("type", ""),
            colorName=data.get("colorName", ""), colorHex=data.get("colorHex", "8E8E93"),
            id=data.get("id", str(uuid.uuid4())), catalogID=data.get("catalogID"),
            manufacturerCode=data.get("manufacturerCode", ""), spoolCount=data.get("spoolCount", 0),
            notes=data.get("notes", ""), updatedAt=data.get("updatedAt", _now()),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def load_catalog() -> list[dict[str, Any]]:
    for path in (_CATALOG_EDIT, _CATALOG_BUNDLED):
        try:
            if path.exists():
                items = json.loads(path.read_text())
                if isinstance(items, list):
                    return items
        except (OSError, ValueError):
            continue
    return []


def save_catalog(catalog: list[dict[str, Any]]) -> None:
    try:
        _DATA_DIR.mkdir(parents=True, exist_ok=True)
        _CATALOG_EDIT.write_text(json.dumps(catalog, indent=2, sort_keys=True))
    except OSError:
        pass


class FilamentStore:
    """Loads/saves the inventory and notifies on change."""

    def __init__(self, inventory_path: Path | None = None) -> None:
        self._inventory_path = inventory_path or _INVENTORY
        self.filaments: list[Filament] = []
        self.on_change: Callable[[], None] | None = None
        try:
            if self._inventory_path.exists():
                self.filaments = [Filament.from_dict(item)
                                  for item in json.loads(self._inventory_path.read_text())]
            else:
                self._save()
        except (OSError, ValueError):
            self.filaments = []

    def add(self, filament: Filament) -> Filament:
        if filament.catalogID is not None:
            for existing in self.filaments:
                if existing.catalogID == filament.catalogID:
                    existing.spoolCount += max(1, filament.spoolCount)
                    existing.updatedAt = _now()
                    self._changed()
                    return existing
        self.filaments.append(filament)
        self._changed()
        return filament

    def update(self, filament: Filament) -> None:
        for index, existing in enumerate(self.filaments):
            if existing.id == filament.id:
                self.filaments[index] = filament
                self._changed()
                return

    def delete(self, filament_id: str) -> None:
        self.filaments = [filament for filament in self.filaments if filament.id != filament_id]
        self._changed()

    def adjust(self, filament_id: str, spools: int) -> None:
        for existing in self.filaments:
            if existing.id == filament_id:
                existing.spoolCount = max(0, existing.spoolCount + spools)
                existing.updatedAt = _now()
                self._changed()
                return

    def merge_remote(self, remote: list[dict[str, Any]]) -> bool:
        """Reconcile a peer's catalogue by id, last-write-wins on updatedAt."""
        by_id = {filament.id: filament for filament in self.filaments}
        changed = False
        for data in remote or []:
            incoming = Filament.from_dict(data)
            local = by_id.get(incoming.id)
            if local is None:
                self.filaments.append(incoming)
                by_id[incoming.id] = incoming
                changed = True
            elif _parse_iso(incoming.updatedAt) > _parse_iso(local.updatedAt):
                self.filaments[self.filaments.index(local)] = incoming
                by_id[incoming.id] = incoming
                changed = True
        if changed:
            self._changed()
        return changed

    def _changed(self) -> None:
        self._save()
        if self.on_change:
            self.on_change()

    def _save(self) -> None:
        try:
            self._inventory_path.parent.mkdir(parents=True, exist_ok=True)
            self._inventory_path.write_text(json.dumps(
                [asdict(filament) for filament in self.filaments], indent=2, sort_keys=True))
        except OSError:
            pass
