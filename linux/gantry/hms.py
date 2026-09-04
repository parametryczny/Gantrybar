"""Resolve Bambu HMS codes using all Bambu Studio model catalogues installed locally."""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from . import i18n

_CACHE: dict[str, dict[str, str]] = {}


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
    result: list[Path] = []
    for value in values:
        if value is not None:
            result.extend((value, value / "hms"))
    return result


def _collect(value: Any, language: str, result: dict[str, str]) -> None:
    if isinstance(value, list):
        for child in value:
            _collect(child, language, result)
    elif isinstance(value, dict):
        code, intro = value.get("ecode"), value.get("intro")
        if isinstance(code, str) and isinstance(intro, str):
            key = _normalize(code)
            if key not in result or (not result[key] and intro):
                result[key] = intro
        if language in value:
            _collect(value[language], language, result)
        for key, child in value.items():
            if key not in {language, "ecode", "intro"}:
                _collect(child, language, result)


def _messages(language: str, serial: str = "") -> dict[str, str]:
    key = f"{language}-all-models"
    if key in _CACHE:
        return _CACHE[key]
    prefix = serial[:3].upper()
    exact = f"hms_{language}_{prefix}.json"
    paths: set[Path] = set()
    for root in _roots():
        for directory in (root, root / "hms"):
            try:
                paths.update(directory.glob(f"hms_{language}_*.json"))
            except OSError:
                pass
    result: dict[str, str] = {}
    for path in sorted(paths, key=lambda item: (item.name != exact, item.name)):
        try:
            _collect(json.loads(path.read_text(encoding="utf-8")), language, result)
        except (OSError, ValueError):
            continue
    _CACHE[key] = result
    return result


def actionable_codes(codes: list[str], serial: str, language: str) -> list[str]:
    messages = _messages(i18n.t("en"), serial)
    return [code for code in codes if _normalize(code) not in messages or messages[_normalize(code)].strip()]


def description(codes: list[str], serial: str, language: str) -> str | None:
    actionable = actionable_codes(codes, serial, language)
    if not actionable:
        return None
    messages = _messages(i18n.t("en"), serial)
    for code in actionable:
        if message := messages.get(_normalize(code), "").strip():
            return message
    return f"HMS {actionable[0]}"
