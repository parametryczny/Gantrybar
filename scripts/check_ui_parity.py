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
floating = CONTRACT["floatingWindow"]

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
require("Sources/Gantry/Views/SettingsWindowController.swift",
        rf"contentRect:\s*NSRect\(x:\s*0,\s*y:\s*0,\s*width:\s*{settings['width']},\s*height:\s*{settings['height']}\)",
        "settings window size differs from the contract")

# Floating dashboard: fixed card geometry and whole-tile window snapping on every platform.
require("Sources/Gantry/Views/FloatingDashboardWindowController.swift",
        rf"width:\s*{floating['initialSize']['width']},\s*height:\s*{floating['initialSize']['height']}",
        "floating window initial size differs from the contract")
require("Sources/Gantry/Views/FloatingDashboardWindowController.swift",
        rf"contentMinSize\s*=\s*NSSize\(width:\s*{floating['minimumSize']['width']},\s*height:\s*{floating['minimumSize']['height']}\)",
        "floating window minimum size differs from the contract")
require("Sources/Gantry/Views/FloatingDashboardWindowController.swift",
        rf'frameAutosaveName\s*=\s*"{re.escape(floating["frameAutosaveName"])}"',
        "floating window frame is not persisted")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"func snappedFloatingContentSize[\s\S]*?columnPitch:\s*CGFloat\s*=\s*293[\s\S]*?rowPitch:\s*CGFloat\s*=\s*182",
        "macOS floating window is not snapped to whole card tiles")
require("Sources/Gantry/Views/FloatingDashboardWindowController.swift",
        r"windowDidEndLiveResize[\s\S]*?snapWindowToTiles",
        "macOS does not snap to tiles after native resize")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"SnapWindowToTiles\(\)[\s\S]*?columnPitch = 293[\s\S]*?rowPitch = 182",
        "Windows floating window is not snapped to whole card tiles")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"if \(WindowMode\) return false;.*full card tiles",
        "Windows still switches to compact rows while resizing the window")
require("linux/gantry/presentation.py",
        r"def _snapped_tile_size[\s\S]*?columns \* 293[\s\S]*?visible_rows \* 182",
        "Linux floating window is not snapped to whole card tiles")
require("linux/gantry/app.py",
        r"if not getattr\(self\.window, \"tray_mode\", True\):[\s\S]*?return False.*full card tiles",
        "Linux still switches to compact rows while resizing the window")
require("Sources/Gantry/App/AppSettings.swift",
        r'floatingWindowEnabled = defaults\.object\(forKey: "floating-window-enabled"\) as\? Bool \?\? false',
        "floating window must remain opt-in")

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

# Compact card variant B (macOS is authoritative): percentage is part of the status row, the
# segmented bar shares one row with ETA/layers, temperatures are 22 px and the Details shortcut is
# opt-in. These checks intentionally cover structure, not only the outer fleet geometry.
percent_size = CONTRACT["statusRow"]["percentLabel"]["size"]
temp_height = CONTRACT["tempBento"]["height"]
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"percentLabel\.font\s*=.*ofSize:\s*{percent_size},\s*weight:\s*\.bold",
        "macOS percentage typography differs from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"statusRow = NSStackView\(views: \[jobStateDot, statusLabel, jobSeparator, jobLabel,[\s\S]*?percentLabel\]\)",
        "macOS percentage is not on the status row")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"\[progress, etaMetric, layerMetric\]\.forEach \{ progressSummary\.addArrangedSubview",
        "macOS progress bar does not share a row with ETA and layers")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"heightAnchor\.constraint\(equalToConstant:\s*{temp_height}\)",
        "macOS temperature row height differs from the contract")
require("Sources/Gantry/App/AppSettings.swift",
        r'cardShowDetailsChip = defaults\.object\(forKey: "card-show-details-chip"\) as\? Bool \?\? false',
        "macOS Details chip is not opt-in")

require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", rf"_percent = new TextBlock \{{ FontSize = {percent_size},",
        "Windows percentage typography differs from macOS")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"_progressRow\.Children\.Add\(_bar\)[\s\S]*?_progressRow\.Children\.Add\(_eta\)[\s\S]*?_progressRow\.Children\.Add\(layersCluster\)",
        "Windows progress bar does not share a row with ETA and layers")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", rf"Orientation = Orientation\.Horizontal, Height = {temp_height}",
        "Windows temperature row height differs from macOS")
require("windows/Gantry.Windows/Services/Storage.cs",
        r'Defaults\.GetBool\("card-show-details-chip", false\)',
        "Windows Details chip is not opt-in")

require("linux/gantry/dashboard.py", rf"font-size:\s*{percent_size}px;\s*font-weight:\s*700",
        "Linux percentage typography differs from macOS")
require("linux/gantry/dashboard.py",
        r"metrics\.pack_start\(self\.progress,[\s\S]*?metrics\.pack_start\(self\.eta,[\s\S]*?metrics\.pack_start\(self\.layers",
        "Linux progress bar does not share a row with ETA and layers")
require("linux/gantry/dashboard.py", rf"min-height:\s*{temp_height}px",
        "Linux temperature row height differs from macOS")
require("linux/gantry/storage.py", r'"card_show_details_chip": False',
        "Linux Details chip is not opt-in")

# Temperature identity and printer errors follow the macOS 1.4 card: icons replace long labels,
# current + smaller target remain on one line, and an error overlays the AMS area without a jump.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r'ThermalZoneView\(label: zone\.0,[\s\S]*?icon: icon,[\s\S]*?side:',
        "macOS temperatures are missing sensor icons or dual-nozzle suffixes")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r'printErrorPanel[\s\S]*?filamentSection[\s\S]*?filamentDock\.isHidden = showPrintError',
        "macOS print error does not replace the filament dock")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r'Geometry\.Parse\(icon switch[\s\S]*?"nozzle"[\s\S]*?"bed"',
        "Windows temperatures do not use sensor icons")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r'_filamentSection\.Children\.Add\(_ams\)[\s\S]*?_filamentSection\.Children\.Add\(_printErrorPanel\)',
        "Windows print error does not occupy the AMS layer")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r'_ams\.Visibility = showPrintError \? Visibility\.Hidden',
        "Windows does not preserve AMS height while showing an error")
require("linux/gantry/dashboard.py",
        r'icon_name = \{"nozzle":[\s\S]*?"bed":[\s\S]*?"chamber":',
        "Linux temperatures do not use sensor icons")
require("linux/gantry/dashboard.py",
        r'self\.filament_section = Gtk\.Overlay\(\)[\s\S]*?add\(self\.ams\)[\s\S]*?add_overlay\(self\.print_error\)',
        "Linux print error does not occupy the AMS layer")
require("linux/gantry/dashboard.py",
        r'self\.ams\.set_opacity\(0\.0 if show_print_error else 1\.0\)',
        "Linux does not preserve AMS height while showing an error")

# Offline cards must keep the header/actions reachable, and the browser UI is one canonical resource
# loaded by all three packages.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"disconnectOverlay\.topAnchor\.constraint\(equalTo: header\.bottomAnchor",
        "macOS offline overlay hides the card header")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", r"Margin = new Thickness\(0, 28, 0, 0\)",
        "Windows offline overlay hides the card header")
require("linux/gantry/dashboard.py", r"offline_overlay\.set_margin_top\(28\)",
        "Linux offline overlay hides the card header")
for relative in ("Sources/Gantry/Services/GantryWebServer.swift",
                 "windows/Gantry.Windows/Services/GantryWebServer.cs",
                 "linux/gantry/webserver.py"):
    require(relative, r"web-dashboard\.html", "does not load the canonical web dashboard")

if FLEET["lastOddCardSpansFullWidth"] == "popoverOnly":
    require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
            r"presentation == \.popover, index == cards\.count - 1, used == 0.*span = columns",
            "macOS last odd card is not limited to the popover")
    require("linux/gantry/layout.py",
            r"stretch_last and not compact and index == len\(serials\) - 1 and column == 0",
            "Linux last odd card cannot be disabled in window mode")
    require("linux/gantry/app.py", r"stretch_last=self\.window\.tray_mode",
            "Linux last odd card is not limited to the popover")
    require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
            r"!WindowMode && idx == printers\.Count - 1 && column == 0.*span = cols",
            "Windows last odd card is not limited to the popover")

if FLEET.get("wideCardWhen") == "twoOrMoreNonExternalFilamentModules":
    require("Sources/Gantry/Views/PrinterDashboardViewController.swift", r"return amsCount >= 2",
            "macOS still widens multi-nozzle printers")
    require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", r"return moduleCount >= 2;",
            "Windows still widens multi-nozzle printers")
    require("linux/gantry/layout.py", r"return ams_count >= 2",
            "Linux still widens multi-nozzle printers")

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

require("Sources/Gantry/Views/FloatingDashboardWindowController.swift",
        r"panel\.isMovableByWindowBackground = false", "macOS background drag steals printer reordering")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"class PrinterDragHandle: NSView \{[\s\S]*?mouseDownCanMoveWindow: Bool \{ false \}",
        "macOS printer grip must not initiate a window drag")

# Presentation ports: keep session state and actual card previews, not separate demo components.
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r'floating-window-enabled', "Windows is missing persistent window mode")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r'new PrinterCard\(this, printer', "Windows guide must use production printer cards")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r'_store\.DashboardPrinters', "Windows must filter cards until telemetry arrives")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r'gantry\.onboarding\.v1\.seen', "Windows guide is not remembered")
require("linux/gantry/presentation.py", r'floating-window-enabled', "Linux is missing window mode")
require("linux/gantry/presentation.py", r'card = PrinterCard\(self.app, printer\)',
        "Linux guide must use production printer cards")
require("linux/gantry/app.py", r'p.serial in self.startup.received',
        "Linux must filter cards until telemetry arrives")
require("linux/gantry/presentation.py", r'gantry\.onboarding\.v1\.seen', "Linux guide is not remembered")

if ERRORS:
    print("UI parity check failed:", file=sys.stderr)
    for error in ERRORS:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print(f"UI parity OK — macOS/Windows/Linux match contract {CONTRACT['meta']['version']}")
