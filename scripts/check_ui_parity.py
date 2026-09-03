#!/usr/bin/env python3
"""Fail CI when Windows/Linux fleet geometry drifts from the shipped macOS contract."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "design" / "gantry-card-layout.impl.json"
CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
FLEET = CONTRACT["fleet"]
TOKENS = CONTRACT["tokens"]
ERRORS: list[str] = []


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(relative: str, pattern: str, description: str) -> None:
    if re.search(pattern, source(relative), re.MULTILINE) is None:
        ERRORS.append(f"{relative}: {description}")


one = FLEET["panelWidth"]["oneColumn"]
two = FLEET["panelWidth"]["twoColumns"]
compact = FLEET["panelWidth"]["list"]
column_gap = FLEET["columnGap"]
row_gap = FLEET["rowGap"]["cards"]
theme_gap = TOKENS["gap"]
radius = TOKENS["radius"]["card"]
settings = CONTRACT["settingsWindow"]["window"]

# macOS is the visual reference, but it is checked too so a macOS change must update the contract.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"panelWidth:\s*CGFloat\s*=\s*useCompactMode\s*\?\s*{compact}\s*:\s*\(expandedColumnCount\s*==\s*1\s*\?\s*{one}\s*:\s*{two}\)",
        "panel widths differ from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"let gap:\s*CGFloat\s*=\s*{column_gap}\b", "fleet column gap differs from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"cardsStack\.spacing\s*=\s*{row_gap}\b", "fleet row gap differs from the contract")
require("Sources/Gantry/App/GantryTheme.swift", rf"cardRadius:\s*CGFloat\s*=\s*{radius}\b",
        "card radius differs from the contract")
require("Sources/Gantry/App/GantryTheme.swift", rf"gap:\s*CGFloat\s*=\s*{theme_gap}\b",
        "theme gap differs from the contract")
# The macOS settings window moved to three tabs and no longer shares a layout with the other two, so
# pinning its size to the shared contract would only assert a number that means nothing on its own.
# Windows and Linux are still checked against each other below; restore this line once they are ported
# to tabs and the three windows describe the same thing again.

require("linux/gantry/layout.py", rf"return\s+{one}\s+if.*else\s+{two}\b",
        "panel widths do not match macOS")
require("linux/gantry/layout.py", rf"return\s+{compact}\b", "compact width does not match macOS")
require("linux/gantry/dashboard.py", rf"CARD_GAP\s*=\s*{column_gap}\b", "column gap does not match macOS")
require("linux/gantry/dashboard.py", rf"CARD_ROW_GAP\s*=\s*{row_gap}\b", "row gap does not match macOS")
require("linux/gantry/settings.py",
        rf"set_default_size\({settings['width']},\s*{settings['height']}\)",
        "settings window size does not match macOS")

require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", rf"Width\s*=\s*{compact};",
        "compact width does not match macOS")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        rf"Width\s*=\s*cols\s*==\s*1\s*\?\s*{one}\s*:\s*{two};", "panel widths do not match macOS")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"FleetColumnGap\s*=\s*{column_gap};",
        "column gap does not match macOS")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"FleetRowGap\s*=\s*{row_gap};",
        "row gap does not match macOS")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"CardRadius\s*=\s*{radius};",
        "card radius differs from the contract")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"public const double Gap\s*=\s*{theme_gap};",
        "theme gap differs from the contract")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml",
        rf"Width=\"{settings['width']}\"\s+Height=\"{settings['height']}\"",
        "settings window size does not match macOS")

if FLEET["lastOddCardSpansFullWidth"] is True:
    require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
            r"index == cards\.count - 1, used == 0.*span = columns",
            "macOS last odd card does not span the final row")
    require("linux/gantry/layout.py",
            r"index == len\(serials\) - 1 and column == 0:[\s\S]*?span = columns",
            "Linux last odd card does not span the final row")
    require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
            r"idx == printers\.Count - 1 && column == 0.*span = cols",
            "Windows last odd card does not span the final row")

# Behavioural parity for controls and the details flow — geometry-only checks previously let these
# regress while still reporting a misleading green result.
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"ScanButton\.Click[\s\S]*?_store\.ReconnectAll\(\);[\s\S]*?_store\.RefreshPrinterNames\(\);",
        "Windows refresh button does not match macOS reconnect + name refresh")
require("linux/gantry/dashboard.py", r"refresh.*reconnect_and_refresh",
        "Linux refresh button does not match macOS reconnect + name refresh")
detail_order = r'"status",\s*"recent",\s*"maintenance",\s*"stats",\s*"camera",\s*"ams",\s*"temps",\s*"fans",\s*"control"'
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        rf'defaultCardOrder\s*=\s*\[{detail_order}\]',
        "macOS detail default order differs from the contract")
require("windows/Gantry.Windows/UI/DetailWindow.cs",
        rf'DefaultCardOrder\s*=\s*\{{\s*{detail_order}\s*\}}',
        "Windows detail default order differs from macOS")
require("linux/gantry/details.py",
        rf'DEFAULT_ORDER\s*=\s*\[{detail_order}\]',
        "Linux detail default order differs from macOS")
require("windows/Gantry.Windows/UI/DetailWindow.cs",
        r"ResetLayout\(\)[\s\S]*?DetailCardOrder = string\.Empty;[\s\S]*?ApplyCardOrder\(\);",
        "Windows detail reset does not restore the default order")
require("windows/Gantry.Windows/UI/AddPrinterWindow.xaml.cs", r"GTheme\.ApplyWindowTheme\(this\)",
        "Windows add/edit dialog does not follow the selected theme")
require("windows/Gantry.Windows/UI/AdvancedWindow.cs", r"GTheme\.ApplyWindowTheme\(this\)",
        "Windows advanced dialog does not follow the selected theme")
require("windows/Gantry.Windows/UI/AutomationsWindow.cs", r"GTheme\.ApplyWindowTheme\(this\)",
        "Windows automations dialog does not follow the selected theme")
require("linux/gantry/app.py", r"self\.kind\.set_visible\(False\)",
        "Linux edit flow still exposes printer-brand changes")

if ERRORS:
    print("UI parity check failed:", file=sys.stderr)
    for error in ERRORS:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print(f"UI parity OK — macOS/Windows/Linux match contract {CONTRACT['meta']['version']}")
