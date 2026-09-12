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
        rf"basePanelWidth:\s*CGFloat\s*=\s*useCompactMode\s*\?\s*{compact}\s*:\s*\(expandedColumnCount\s*==\s*1\s*\?\s*{one}\s*:\s*{two}\)",
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
        r"func snappedFloatingContentSize[\s\S]*?columnPitch:\s*CGFloat\s*=\s*293[\s\S]*?height:\s*proposed\.height",
        "macOS floating window width is not snapped to whole card columns")
require("Sources/Gantry/Views/FloatingDashboardWindowController.swift",
        r"windowDidEndLiveResize[\s\S]*?snapWindowToTiles[\s\S]*?fitHeightToCards",
        "macOS does not snap columns and fit the real card-row height after resize")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"magnification = scale",
        "macOS printer card scale does not magnify the real cards")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"measuredContent \* cardScale",
        "macOS popover height does not include printer card magnification")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"cardScaleRow[\s\S]*?dockScaleRow",
        "macOS settings are missing card and edge-dock scale controls")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"edgeDockScalePercent[\s\S]*?Self\.collapsedWidth \* scale",
        "macOS edge dock does not apply its selected scale")

# Issue #34, macOS first: the strip can stay unfolded and carry one live camera under its rows.
# Windows and GNU/Linux still expand on hover only, so they are deliberately not required here yet.
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"var pinned = false[\s\S]*?isExpanded: Bool \{ pinned \|\| isHovering \}",
        "macOS edge dock cannot stay open without the pointer")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"settings\.edgeDockCamera[\s\S]*?edgeDockCameraSerials[\s\S]*?CameraFeedController\(store: store, serial: serial\)",
        "macOS edge dock cameras are not driven by the per-printer selection")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"cameraViews\[metric\.entry\.serial\]",
        "macOS edge dock does not place each picture under its own printer row")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"dockPrinterCameraToggled[\s\S]*?edgeDockCameraSerials",
        "macOS settings cannot choose which printers show a picture")
require("Sources/Gantry/Views/CameraFeed.swift",
        r"final class CameraFeedController[\s\S]*?func start\(\)[\s\S]*?func stop\(\)",
        "the camera feed is not reusable outside the detail view")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"dockPinnedRow[\s\S]*?dockCameraRow",
        "macOS settings are missing the edge-dock pin and camera switches")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"pinButtonRect\(\)[\s\S]*?onUnpin\?\(\)",
        "macOS pinned edge dock cannot be released from the strip itself")

# Issue #34, the second half: the detail panel must take the height its cards need, capped by the
# screen, instead of the constant it used to be nailed to. GNU/Linux already sizes to content through
# set_propagate_natural_height, so only the two ports that hard-coded a number are checked here.
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"minimumPopoverHeight[\s\S]*?func updatePreferredHeight\(\)[\s\S]*?visibleFrame\.height",
        "macOS detail popover height is not driven by its cards and the screen")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"private void FitPanel\(\)[\s\S]*?double\.PositiveInfinity[\s\S]*?WorkArea\.Height",
        "Windows bounded panel height is not measured from its content and the work area")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"CardColumnPitch\s*=>\s*293 \* AppSettings\.CardScalePercent / 100\.0[\s\S]*?SnapWindowToTiles\(\)[\s\S]*?columnPitch = CardColumnPitch[\s\S]*?FitHeightToContent",
        "Windows floating window is not snapped to card columns with content-driven height")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"if \(WindowMode\) return false;.*full card tiles",
        "Windows still switches to compact rows while resizing the window")
require("linux/gantry/presentation.py",
        r"def _snapped_tile_size[\s\S]*?pitch = 293 \* scale[\s\S]*?columns \* pitch[\s\S]*?content_height_for_width",
        "Linux floating window does not snap columns and fit the real card-row height")
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
# The Windows side reads the stored key through AppSettings.FloatingWindowEnabled (which also pins the
# mode off in the LITE build), so either form counts as "the mode is still here".
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r'floating-window-enabled|AppSettings\.FloatingWindowEnabled',
        "Windows is missing persistent window mode")
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

# Windows issue #32: hover ownership, WinForms/WPF focus hand-off and first automatic window size.
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        r"_canvas\.Background = Brushes\.Transparent",
        "Windows edge dock has transparent hit-test holes")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        r"MouseLeave[\s\S]*?_collapseTimer\.Start",
        "Windows edge dock collapses synchronously and can enter a hover loop")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        r"double ringX = left \? \(ExpandedPadX \+ Ring / 2\) \* scale : width - \(ExpandedPadX \+ Ring / 2\) \* scale",
        "Windows edge dock ring does not stay anchored to its screen edge")
require("windows/Gantry.Windows/UI/TrayIcon.cs",
        r"ShowOnboardingAfterMenuCloses[\s\S]*?menu\.Closed \+= closed",
        "Windows onboarding opens before the tray menu releases mouse capture")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"floating-window-size-user-set[\s\S]*?automaticColumns[\s\S]*?automaticRows",
        "Windows untouched floating window does not fit its initial printer grid")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"WmExitSizeMove[\s\S]*?floating-window-size-user-set",
        "Windows cannot distinguish manual resize from automatic sizing")

# Windows issue #33: late AMS content must resize both surfaces; edge dock needs manual DPI relief.
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"FitHeightToContent\(\)[\s\S]*?CardsPanel\.Measure\([\s\S]*?SystemParameters\.WorkArea\.Height - 16",
        "Windows dashboard height is not measured from the real post-telemetry card grid")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"if \(!WindowMode\)[\s\S]*?Top = area\.Bottom - Height - 8",
        "Windows content fitting no longer preserves popover anchoring")
require("windows/Gantry.Windows/Services/Storage.cs",
        r"EdgeDockScalePercent[\s\S]*?Round\(value / 5\.0\)[\s\S]*?100, 150",
        "Windows edge dock is missing five-percent size steps")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml",
        r"DockSizeMinusButton[\s\S]*?DockSizeValue[\s\S]*?DockSizePlusButton",
        "Windows settings are missing edge-dock minus/plus controls")
for relative in ("windows/Gantry.Windows/Services/Storage.cs", "linux/gantry/storage.py"):
    require(relative, r"card-scale-percent|card_scale_percent", "printer-card scale is not persisted")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml.cs", r"ChangeCardScale\(-5\)[\s\S]*?ChangeCardScale\(5\)",
        "Windows card scale does not use five-percent steps")
require("linux/gantry/settings.py", r'_scale_row\(i18n\.t\("Card size"\), "card_scale_percent", 75, 150\)',
        "Linux settings are missing printer-card scale controls")

# Object skipping stays end-to-end on both ports: discovery, protected UI and printer command.
require("windows/Gantry.Windows/Services/MoonrakerStatusParser.cs", r'exclude_object[\s\S]*?PrintObjects',
        "Windows is missing Klipper object discovery")
require("windows/Gantry.Windows/Services/PrinterStore.cs", r'LoadPrintObjectLayoutAsync[\s\S]*?SkipPrintObjects[\s\S]*?EXCLUDE_OBJECT[\s\S]*?skip_objects',
        "Windows object skipping is not wired to both Klipper and Bambu")
require("windows/Gantry.Windows/UI/SkipObjectsPanel.cs", r'class SkipObjectsPanel[\s\S]*?Confirm skip[\s\S]*?SkipPrintObjects',
        "Windows is missing the protected object-skipping panel")
require("linux/gantry/http_clients.py", r'exclude_object[\s\S]*?print_objects',
        "Linux is missing Klipper object discovery")
require("linux/gantry/skipobjects.py", r'class SkipObjectsPanel[\s\S]*?Confirm skip[\s\S]*?skip_objects',
        "Linux is missing the protected object-skipping panel")

if ERRORS:
    print("UI parity check failed:", file=sys.stderr)
    for error in ERRORS:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print(f"UI parity OK — macOS/Windows/Linux match contract {CONTRACT['meta']['version']}")
