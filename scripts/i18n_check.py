#!/usr/bin/env python3
"""Fail CI when a translated string drifts away from the catalog.

Two failure modes this catches, both silent at runtime because a missing key falls back to English:

  * a call site uses a key the catalog does not have (typo, or the English wording was edited without
    updating i18n/pl.json), so that text quietly stops being translated;
  * a catalog entry no longer matches any call site, so translators keep maintaining dead text.

Keys starting with "@" are catalog metadata ("@name" is the language name shown in Settings) and are
neither expected in the sources nor reported as dead.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG_DIR = ROOT / "i18n"
SKIP_PARTS = {".build", "obj", "bin", "__pycache__", "node_modules", "build", "dist"}

# One pattern per platform's lookup call. Group 1 is the English key.
CALL_PATTERNS: list[tuple[str, str, str]] = [
    ("Sources/Gantry", "*.swift", r'(?<![A-Za-z0-9_])t\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]'),
    ("Sources/Gantry", "*.swift", r'(?<![A-Za-z0-9_])t\(\s*"""\n(.*?)\n\s*"""\s*\)'),
    ("windows/Gantry.Windows", "*.cs", r'(?<![A-Za-z0-9_])T\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]'),
    ("linux/gantry", "*.py", r'(?<![A-Za-z0-9_.])t\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]'),
    ("linux/gantry", "*.py", r"(?<![A-Za-z0-9_.])t\(\s*'((?:[^'\\]|\\.)*)'\s*[,)]"),
]


def unescape(text: str) -> str:
    """Turn a source literal back into the runtime string, so it can be compared with the catalog."""
    return text.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def dedent_block(text: str) -> str:
    """Swift strips the closing delimiter's indentation from a multi-line literal; mirror that."""
    lines = text.split("\n")
    indents = [len(line) - len(line.lstrip()) for line in lines if line.strip()]
    cut = min(indents) if indents else 0
    return "\n".join(line[cut:] if line.strip() else "" for line in lines)


def used_keys() -> set[str]:
    keys: set[str] = set()
    for folder, glob, pattern in CALL_PATTERNS:
        for path in (ROOT / folder).rglob(glob):
            if any(part in SKIP_PARTS for part in path.parts):
                continue
            source = path.read_text(encoding="utf-8", errors="ignore")
            for match in re.finditer(pattern, source, re.S):
                raw = match.group(1)
                keys.add(dedent_block(raw) if "\n" in raw else unescape(raw))
    return keys


def main() -> int:
    # Until Windows and Linux call sites are migrated too, their pairs still live in the catalog with
    # no t() call pointing at them. Dead entries are therefore a warning by default and only fail the
    # build under --strict, which CI turns on once every platform is migrated.
    strict = "--strict" in sys.argv
    catalogs = sorted(CATALOG_DIR.glob("*.json"))
    if not catalogs:
        print("Brak katalogow w i18n/.", file=sys.stderr)
        return 1

    used = used_keys()
    problems = 0
    for path in catalogs:
        entries = json.loads(path.read_text(encoding="utf-8"))
        translatable = {k for k in entries if not k.startswith("@")}
        missing = sorted(used - translatable)
        dead = sorted(translatable - used)
        if "@name" not in entries:
            print(f"{path.name}: brak klucza @name, jezyk nie pokaze sie z nazwa w ustawieniach",
                  file=sys.stderr)
            problems += 1
        if missing:
            problems += len(missing)
            print(f"{path.name}: {len(missing)} kluczy uzywanych w kodzie bez wpisu:", file=sys.stderr)
            for key in missing[:20]:
                print(f"    {key!r}", file=sys.stderr)
        if dead:
            if strict:
                problems += len(dead)
            label = "" if strict else " (ostrzezenie)"
            print(f"{path.name}: {len(dead)} wpisow bez uzycia w kodzie{label}", file=sys.stderr)
            for key in dead[:20] if strict else dead[:5]:
                print(f"    {key!r}", file=sys.stderr)

    if problems:
        print("\nUzupelnij katalog albo popraw klucz w kodzie.", file=sys.stderr)
        return 1
    print(f"i18n OK — {len(used)} kluczy, katalogi: {', '.join(p.stem for p in catalogs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
