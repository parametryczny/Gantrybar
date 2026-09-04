#!/usr/bin/env python3
"""Build i18n/pl.json from the English/Polish pairs still written inline in the sources.

The catalog is keyed by the **English** string, the way gettext keys by msgid. Two reasons: a missing
translation then degrades to readable English instead of a raw key like `settings.launchAtLogin`, and
620-odd keys need no invented names, so the migration can be mechanical.

Run it while call sites are still being migrated; once every platform calls `t(...)`, the catalog is
edited by hand and this script only verifies that nothing was left behind.
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "i18n" / "pl.json"

# One pattern per idiom the code still uses. Group 1 is Polish, group 2 English.
SOURCES: list[tuple[str, str, str]] = [
    ("Sources/Gantry", "*.swift",
     r'(?<![A-Za-z0-9_])text\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)'),
    ("windows/Gantry.Windows", "*.cs",
     r'(?<![A-Za-z0-9_])Text\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)'),
    ("windows/Gantry.Windows", "*.cs",
     r'\b_?[Pp]l\s*\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"'),
    ("linux/gantry", "*.py",
     r'"((?:[^"\\]|\\.)*)"\s+if\s+[^\n]*?\bpl\b[^\n]*?\s+else\s+"((?:[^"\\]|\\.)*)"'),
]
SKIP_PARTS = {".build", "obj", "bin", "__pycache__", "node_modules"}


def collect() -> tuple[dict[str, str], dict[str, set[str]]]:
    catalog: dict[str, str] = {}
    clashes: dict[str, set[str]] = defaultdict(set)
    for folder, glob, pattern in SOURCES:
        for path in (ROOT / folder).rglob(glob):
            if any(part in SKIP_PARTS for part in path.parts):
                continue
            for match in re.finditer(pattern, path.read_text(encoding="utf-8", errors="ignore")):
                polish, english = match.group(1), match.group(2)
                if not english or not polish:
                    continue
                clashes[english].add(polish)
                catalog[english] = polish
    return catalog, {k: v for k, v in clashes.items() if len(v) > 1}


def main() -> int:
    catalog, clashes = collect()
    if clashes:
        print("Ten sam angielski tekst ma rozne polskie odpowiedniki:", file=sys.stderr)
        for english, polish in sorted(clashes.items()):
            print(f"  {english!r} -> {sorted(polish)}", file=sys.stderr)
        print("Ujednolic je w zrodlach, inaczej katalog zgubi jeden z wariantow.", file=sys.stderr)
        return 1
    OUT.parent.mkdir(exist_ok=True)
    # Keys starting with "@" are catalog metadata, not translatable text: "@name" carries the language
    # name shown in Settings. Preserve whatever the existing file declares.
    if OUT.exists():
        previous = json.loads(OUT.read_text(encoding="utf-8"))
        catalog.update({k: v for k, v in previous.items() if k.startswith("@")})
    OUT.write_text(json.dumps(dict(sorted(catalog.items())), ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8")
    print(f"Zapisano {OUT.relative_to(ROOT)}: {len(catalog)} hasel")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
