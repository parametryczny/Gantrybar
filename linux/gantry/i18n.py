from __future__ import annotations

"""Translation catalogs, keyed by the English source string the way gettext keys by msgid.

Three consequences worth knowing. A key missing from a catalog falls back to the English string
itself, so a forgotten entry degrades to readable text instead of showing `settings.launch` to the
user. English needs no catalog at all, because it *is* the key. And a new language is one file
dropped into `i18n/`: nothing here or in Settings enumerates languages by hand.

Each catalog names itself under the `@name` key ("Polski", "Deutsch"), so the Settings list needs no
table of language names in code. Keys starting with `@` are metadata, never lookup text.
"""

import json
from pathlib import Path

_language = "en"
_tables: dict[str, dict[str, str]] = {}
_files: dict[str, Path] | None = None


def _search_paths() -> list[Path]:
    here = Path(__file__).resolve().parent
    return [
        here / "data" / "i18n",          # installed package
        here.parents[1] / "i18n",        # running from the checkout
        here.parents[2] / "i18n",
    ]


def _catalog_files() -> dict[str, Path]:
    """Catalog files by language code, taking the first directory that has any."""
    global _files
    if _files is not None:
        return _files
    for directory in _search_paths():
        try:
            found = {path.stem: path for path in sorted(directory.glob("*.json"))}
        except OSError:
            continue
        if found:
            _files = found
            return _files
    _files = {}
    return _files


def _table(code: str) -> dict[str, str]:
    if code in _tables:
        return _tables[code]
    table: dict[str, str] = {}
    path = _catalog_files().get(code)
    if path is not None:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                table = {str(k): str(v) for k, v in data.items()}
        except (OSError, ValueError):
            table = {}
    _tables[code] = table
    return table


def available() -> list[tuple[str, str]]:
    """Every language the app can offer as (code, name). English is always present and first."""
    found = [("en", "English")]
    for code in sorted(_catalog_files()):
        if code == "en":
            continue
        found.append((code, _table(code).get("@name", code.upper())))
    return found


def set_language(code: str) -> None:
    """Called by the app whenever the language changes."""
    global _language
    _language = code if any(code == entry[0] for entry in available()) else "en"


def language() -> str:
    return _language


def t(english: str) -> str:
    """Text for an English source string in the current language."""
    if _language == "en":
        return english
    return _table(_language).get(english, english)


def loaded_count(code: str | None = None) -> int:
    """Entry count, used by diagnostics; never needed at runtime."""
    return len(_table(code or _language))
