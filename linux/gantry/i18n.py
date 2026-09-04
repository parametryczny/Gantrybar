from __future__ import annotations

"""The shipped translation catalog, keyed by the English source string the way gettext keys by msgid.

Two consequences worth knowing. A key missing from the catalog falls back to the English string
itself, so a forgotten entry degrades to readable text instead of showing `settings.launch` to the
user. And adding a language means adding one JSON file, without touching any call site.

The catalog is the repository's `i18n/pl.json`; packaging copies it into `gantry/data/`.
"""

import json
from pathlib import Path

_language = "pl"
_catalog: dict[str, str] | None = None


def _candidates() -> list[Path]:
    here = Path(__file__).resolve().parent
    return [
        here / "data" / "i18n-pl.json",          # installed package
        here.parents[1] / "i18n" / "pl.json",    # running from the checkout
        here.parents[2] / "i18n" / "pl.json",
    ]


def _load() -> dict[str, str]:
    for path in _candidates():
        try:
            if not path.is_file():
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and data:
                return {str(k): str(v) for k, v in data.items()}
        except (OSError, ValueError):
            continue
    return {}


def set_language(code: str) -> None:
    """Called by the app whenever the language changes."""
    global _language
    _language = "pl" if code == "pl" else "en"


def t(english: str) -> str:
    """Polish text for an English source string, or the string itself outside Polish."""
    global _catalog
    if _language != "pl":
        return english
    if _catalog is None:
        _catalog = _load()
    return _catalog.get(english, english)


def loaded_count() -> int:
    """Entry count, used by diagnostics; never needed at runtime."""
    global _catalog
    if _catalog is None:
        _catalog = _load()
    return len(_catalog)
