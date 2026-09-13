#!/usr/bin/env python3
"""Fail before CI when a WPF window's markup and its code-behind disagree about a control name.

A control that a code-behind names but the markup no longer declares is a build error (CS0103), and
it only shows up on a Windows runner — a slow way to learn that a rewrite dropped an x:Name. This
checks the pairing directly, without a C# compiler and without guessing which identifiers are WPF
types (enumerating those is hopeless, and every attempt produces false alarms):

  - the markup is well-formed XML;
  - every x:Name the committed markup declared and the working tree no longer does is gone from the
    code-behind too.

The second rule is the one that catches a rewrite. Names the markup declares and no code uses are
reported as a note, never a failure: XAML uses some itself (a template part, a row a sibling binds
to). Pass --base <rev> to compare against something other than HEAD.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = ROOT / "windows" / "Gantry.Windows"
NAME = re.compile(r'x:Name="([A-Za-z_][A-Za-z0-9_]*)"')


def names_in(markup: str) -> set[str]:
    return set(NAME.findall(markup))


def committed(path: Path, base: str) -> str | None:
    """The file as of `base`, or None when it did not exist there."""
    result = subprocess.run(["git", "show", f"{base}:{path.relative_to(ROOT).as_posix()}"],
                            cwd=ROOT, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def strip_code(cs: str) -> str:
    """Comments and string bodies would both give false hits."""
    cs = re.sub(r'"(?:[^"\\]|\\.)*"', '""', cs)
    cs = re.sub(r'//[^\n]*', '', cs)
    return re.sub(r'/\*.*?\*/', '', cs, flags=re.S)


def check(xaml_path: Path, cs_path: Path, base: str) -> list[str]:
    markup = xaml_path.read_text(encoding="utf-8")
    try:
        ElementTree.fromstring(markup)
    except ElementTree.ParseError as exc:
        return [f"{xaml_path.name}: markup is not well-formed XML — {exc}"]

    declared = names_in(markup)
    code = strip_code(cs_path.read_text(encoding="utf-8"))

    problems = []
    previous = committed(xaml_path, base)
    if previous is not None:
        for dropped in sorted(names_in(previous) - declared):
            if re.search(rf'(?<![.\w]){dropped}\b', code):
                problems.append(f"{cs_path.name}: still uses '{dropped}', which "
                                f"{xaml_path.name} no longer declares")

    unused = sorted(n for n in declared if not re.search(rf'(?<![.\w]){n}\b', code))
    if unused:
        print(f"  note — declared in markup, unused in code: {', '.join(unused)}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="HEAD", help="revision to compare the markup against")
    args = parser.parse_args()

    if not WINDOWS.exists():
        print("no Windows project here; nothing to check")
        return 0
    pairs = [(x, x.with_suffix(".xaml.cs")) for x in sorted(WINDOWS.rglob("*.xaml"))
             if "obj" not in x.parts and "bin" not in x.parts and x.with_suffix(".xaml.cs").exists()]
    if not pairs:
        print("no XAML/code-behind pairs found")
        return 0

    failures: list[str] = []
    for xaml_path, cs_path in pairs:
        print(xaml_path.relative_to(ROOT).as_posix())
        failures += check(xaml_path, cs_path, args.base)
    if failures:
        print("\nXAML/code-behind mismatch:")
        for line in failures:
            print(f"  {line}")
        return 1
    print(f"\nXAML names OK — {len(pairs)} window(s) checked against {args.base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
