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
    # Linux calls it as i18n.t(...), so the dot must be allowed here, unlike the bare t() on macOS.
    ("linux/gantry", "*.py", r'(?<![A-Za-z0-9_])(?:i18n\.)?t\(\s*"((?:[^"\\]|\\.)*)"\s*[,)]'),
    ("linux/gantry", "*.py", r"(?<![A-Za-z0-9_])(?:i18n\.)?t\(\s*'((?:[^'\\]|\\.)*)'\s*[,)]"),
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


# Some keys never appear inside a lookup call: they sit in a table (printer stages, card titles,
# notification labels) that is indexed at runtime and passed to the lookup as a variable. A key that
# appears verbatim anywhere in the sources therefore counts as used.
#
# This is a plain text search rather than a literal parser on purpose: matching quotes across a whole
# file goes wrong on docstrings and multi-line literals, and a mis-paired quote silently hides every
# key after it.
def sources_blob() -> str:
    parts: list[str] = []
    for folder, glob in (("Sources/Gantry", "*.swift"), ("windows/Gantry.Windows", "*.cs"),
                         ("linux/gantry", "*.py")):
        for path in (ROOT / folder).rglob(glob):
            if any(part in SKIP_PARTS for part in path.parts):
                continue
            parts.append(path.read_text(encoding="utf-8", errors="ignore"))
    return "\n".join(parts)


def mentioned_keys(catalog: set[str], blob: str) -> set[str]:
    found = set()
    for key in catalog:
        if key in blob:
            found.add(key)
            continue
        # A key carrying a newline or a quote appears escaped in the source.
        escaped = key.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        if escaped in blob:
            found.add(key)
    return found


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
    # CI runs with --strict, which fails on a catalog entry nothing references any more. Without the
    # flag those are only a warning, which is handy while a migration is half done.
    strict = "--strict" in sys.argv
    catalogs = sorted(CATALOG_DIR.glob("*.json"))
    if not catalogs:
        print("Brak katalogow w i18n/.", file=sys.stderr)
        return 1

    used = used_keys()
    blob = sources_blob()
    problems = 0
    for path in catalogs:
        entries = json.loads(path.read_text(encoding="utf-8"))
        translatable = {k for k in entries if not k.startswith("@")}
        referenced = used | mentioned_keys(translatable, blob)
        missing = sorted(used - translatable)
        # A key that is a strict prefix of another key and ends with a space is an extraction
        # artifact: the substring search above would always call it used, so flag it separately.
        truncated = sorted(k for k in translatable
                           if k.endswith(" ") and k not in used
                           and any(o != k and o.startswith(k) for o in translatable))
        dead = sorted(translatable - referenced)
        if "@name" not in entries:
            print(f"{path.name}: brak klucza @name, jezyk nie pokaze sie z nazwa w ustawieniach",
                  file=sys.stderr)
            problems += 1
        if missing:
            problems += len(missing)
            print(f"{path.name}: {len(missing)} kluczy uzywanych w kodzie bez wpisu:", file=sys.stderr)
            for key in missing[:20]:
                print(f"    {key!r}", file=sys.stderr)
        if truncated:
            problems += len(truncated)
            print(f"{path.name}: {len(truncated)} kluczy urwanych w polowie:", file=sys.stderr)
            for key in truncated[:10]:
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
