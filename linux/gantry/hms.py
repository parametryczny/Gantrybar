"""Resolve Bambu HMS codes using Bambu Studio's local message catalogue."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

_CACHE: dict[tuple[str, str], dict[str, str]] = {}


def _normalize(value: str) -> str:
    return value.replace("_", "").upper()


def _roots() -> list[Path]:
    configured = os.environ.get("BAMBU_STUDIO_RESOURCES")
    values = [
        Path(configured) if configured else None,
        Path("/usr/share/bambu-studio/resources"), Path("/usr/share/BambuStudio/resources"),
        Path("/opt/bambu-studio/resources"), Path("/opt/BambuStudio/resources"),
        Path.home() / ".local/share/BambuStudio/resources",
        Path("/var/lib/flatpak/app/com.bambulab.BambuStudio/current/active/files/extra/BambuStudio/resources"),
    ]
    return [value for value in values if value is not None]


def _collect(value: Any, language: str, result: dict[str, str]) -> None:
    if isinstance(value, list):
        for child in value:
            _collect(child, language, result)
    elif isinstance(value, dict):
        code, intro = value.get("ecode"), value.get("intro")
        if isinstance(code, str) and isinstance(intro, str) and intro:
            result[_normalize(code)] = intro
        if language in value:
            _collect(value[language], language, result)
        for key, child in value.items():
            if key not in {language, "ecode", "intro"}:
                _collect(child, language, result)


def _messages(prefix: str, language: str) -> dict[str, str]:
    key = (prefix, language)
    if key in _CACHE:
        return _CACHE[key]
    result: dict[str, str] = {}
    filename = f"hms_{language}_{prefix}.json"
    for root in _roots():
        path = root / "hms" / filename
        if not path.exists():
            path = root / filename
        try:
            _collect(json.loads(path.read_text(encoding="utf-8")), language, result)
            break
        except (FileNotFoundError, OSError, ValueError):
            continue
    _CACHE[key] = result
    return result


def description(codes: list[str], serial: str, language: str) -> str | None:
    if not codes:
        return None
    messages = _messages(serial[:3].upper(), "pl" if language == "pl" else "en")
    for code in codes:
        if message := messages.get(_normalize(code)):
            return message
    return f"HMS {codes[0]}"
