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


def forbid(relative: str, pattern: str, description: str) -> None:
    """For a shape that was removed on purpose and must not come back."""
    if re.search(pattern, source(relative), re.MULTILINE) is not None:
        ERRORS.append(f"{relative}: {description}")


def require_count(relative: str, pattern: str, expected: int, description: str) -> None:
    """Counts occurrences in Python instead of asking one regex to. A repeated group wrapped around
    a wildcard bridge — (?:[\\s\\S]*?X[\\s\\S]*?){n} — backtracks exponentially the moment it fails
    to match, which turns a broken rule into a hung check instead of a reported one."""
    found = len(re.findall(pattern, source(relative), re.MULTILINE))
    if found != expected:
        ERRORS.append(f"{relative}: {description} (found {found}, expected {expected})")


one = FLEET["panelWidth"]["oneColumn"]
two = FLEET["panelWidth"]["twoColumns"]
compact = FLEET["panelWidth"]["list"]
column_gap = FLEET["columnGap"]
row_gap = FLEET["rowGap"]["cards"]
theme_gap = TOKENS["gap"]
radius = TOKENS["radius"]["card"]
settings_window = CONTRACT["settingsWindow"]
settings_metrics = settings_window["metrics"]
floating = CONTRACT["floatingWindow"]
panel_window = CONTRACT["panelWindow"]
edge_dock = CONTRACT["edgeDock"]
slot_assignment = panel_window["slotAssignment"]

# macOS is the visual reference, but it is checked too so a macOS change must update the contract.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"basePanelWidth:\s*CGFloat\s*=\s*useCompactMode\s*\?\s*{compact}\s*:\s*\(expandedColumnCount\s*==\s*1\s*\?\s*{one}\s*:\s*{two}\)",
        "panel widths differ from the contract")
# One gap between cards, across and down (fleet.cardSeparation), and the lighter card with its firmer edge.
if column_gap != row_gap:
    ERRORS.append("design contract: macOS uses one card gap across and down, but columnGap and rowGap.cards differ")
require("Sources/Gantry/App/GantryTheme.swift", rf"static let cardGap: CGFloat = {column_gap}\b",
        "fleet card gap differs from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"let effectiveGap = GantryTheme\.cardGap", "fleet column gap differs from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"cardsStack\.spacing = GantryTheme\.cardGap", "fleet row gap differs from the contract")
fleet_card = TOKENS["surface"]["fleetCard"].lstrip("#")
fleet_card_alpha = TOKENS["surface"]["fleetCardAlpha"]
require("Sources/Gantry/App/GantryTheme.swift", rf"fleetCard\s*=\s*NSColor\(hex: 0x{fleet_card}\)[\s\S]{{0,80}}fleetCardAlpha: CGFloat = {fleet_card_alpha}"
        r"[\s\S]{0,80}fleetCardLine = NSColor\.white\.withAlphaComponent\(0\.16\)", "macOS printer card colours differ from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"GantryTheme\.fleetCard\.withAlphaComponent\(GantryTheme\.fleetCardAlpha\)[\s\S]{0,120}GantryTheme\.fleetCardLine",
        "the macOS printer card does not use the fleet card colours")
require("linux/gantry/dashboard.py", rf'fleet_card, fleet_card_line = "alpha\(#{fleet_card.lower()}, {fleet_card_alpha}\)", "alpha\(#ffffff, 0\.16\)"',
        "GNU/Linux printer card colours differ from the contract")
require("linux/gantry/dashboard.py", r"\.card \{ background: %\(fleet_card\)s; border: 1px solid %\(fleet_card_line\)s;",
        "the GNU/Linux printer card does not use the fleet card colours")
require("windows/Gantry.Windows/UI/GantryTheme.cs",
        rf"FleetCard => IsLight \? Color\.FromArgb\(A\(0\.86\), 0xFF, 0xFF, 0xFF\) : Color\.FromArgb\(A\({fleet_card_alpha}\), 0x{fleet_card[0:2]}, 0x{fleet_card[2:4]}, 0x{fleet_card[4:6]}\)",
        "Windows printer card colours differ from the contract")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"Background = GTheme\.Brush\(GTheme\.FleetCard\),[\s\S]{0,120}BorderBrush = GTheme\.Brush\(GTheme\.FleetCardLine\)",
        "the Windows printer card does not use the fleet card colours")
require("Sources/Gantry/App/GantryTheme.swift", rf"cardRadius:\s*CGFloat\s*=\s*{radius}\b",
        "card radius differs from the contract")
require("Sources/Gantry/App/GantryTheme.swift", rf"gap:\s*CGFloat\s*=\s*{theme_gap}\b",
        "theme gap differs from the contract")
# No platform pins a settings-window size any more: the window fits whichever pane is showing,
# which is what a system settings window does. The per-platform chrome rules live further down.
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"tabStyle = \.toolbar",
        "macOS settings window does not use the system's toolbar-style pane switcher")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"toolbarStyle = \.preference",
        "macOS settings window lays its toolbar out like a document window's")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        rf"enum SettingsPaneID: String \{{\s*case (?:\w+, ){{{len(settings_window['panes']) - 1}}}\w+",
        "macOS settings pane count differs from the contract")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"\.general, \.appearance, \.notifications, \.windows, \.integrations, \.advanced",
        "macOS settings panes are not in the contract's order")
require("Sources/Gantry/Views/SettingsRowKit.swift",
        rf"captionColumn: CGFloat = {settings_metrics['captionColumn']}[\s\S]*?"
        rf"controlColumn: CGFloat = {settings_metrics['controlColumn']}",
        "macOS settings columns differ from the contract")
require("Sources/Gantry/Views/SettingsRowKit.swift",
        r"NSGridView\(numberOfColumns: 2[\s\S]*?column\(at: 0\)\.xPlacement = \.trailing"
        r"[\s\S]*?column\(at: 1\)\.xPlacement = \.leading",
        "macOS settings do not use the two-column preferences grid")
require("Sources/Gantry/Views/SettingsRowKit.swift",
        r"NSButton\(checkboxWithTitle:",
        "macOS settings booleans are not checkboxes")
# The two things that make the window fit its pane. Both were bugs first, both are one line, and both
# fail silently: the content simply sits at the wrong offset and runs off the bottom edge. A height
# constraint on the content view controller's own view is the only mechanism the window honours
# (preferredContentSize did nothing on the child and raced on the parent), and a pane root view must
# keep autoresizing because NSTabView positions its children by frame, not by constraint.
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"heightAnchor\.constraint\(equalToConstant:[\s\S]*?paneHeight = height",
        "macOS settings window height is not driven by a constraint on the content view controller")
require("Sources/Gantry/Views/SettingsRowKit.swift",
        r"root\.autoresizingMask = \[\.width, \.height\]",
        "macOS settings pane opts out of autoresizing, so NSTabView cannot reposition it")
# One refresh per run loop turn and only for the pane on screen. Measured before this: a single
# notification click wrote six @Published properties and cost six whole-window refreshes, a
# card-content click seven, and every one of them re-rendered the dashboard QR code.
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"guard !refreshScheduled else \{ return \}[\s\S]*?refreshScheduled = true",
        "macOS settings refresh once per written setting instead of once per run loop turn")
# Every pane is filled on every refresh, and every pane whose content changed is measured in the same
# pass. Filling only the visible one was audited and cost eight controls across five of the six panes
# that were wrong until visited, so the switch itself was when they visibly changed.
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"for id in SettingsPaneID\.visible \{ refreshPane\(id\) \}[\s\S]*?"
        r"for pane in panes\.values \{ pane\.updatePreferredSize\(\) \}",
        "macOS settings leave hidden panes showing stale values until they are switched to")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"onWillSelect = \{ \[weak self\] index in self\?\.resizeToPane\(at: index\) \}",
        "macOS settings resize the window after the new pane is already on screen")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"if qrCache\?\.url != target",
        "macOS settings re-render the dashboard QR code on unrelated refreshes")
# The edge-dock choices are two plain columns of checkboxes, laid out like every other group in the
# window. They were a bordered, scrolling list with a camera glyph button hanging off each row, which
# read as a widget from another program and put a scroller next to five items that had room to sit
# in the open.
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"grid\.field\(dockPrintersCaption, dockPrintersHolder\)[\s\S]*?"
        r"grid\.field\(dockCamerasCaption, dockCamerasHolder\)",
        "macOS edge-dock printers and cameras are not two plain checkbox columns")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"NSButton\(checkboxWithTitle: printer\.name[\s\S]*?"
        r"NSButton\(checkboxWithTitle: printer\.name",
        "macOS edge-dock camera choice is not a checkbox like the printer choice")
# Switching a pane is dominated by laying it out and measuring it, and almost nothing a user clicks
# changes any pane's height. Writes that can are counted, and a refresh that touched none of them
# leaves the measured height alone: measured, this took layout and fitting from 18 ms to zero.
require("Sources/Gantry/Views/SettingsRowKit.swift",
        r"enum SettingsLayoutTouches[\s\S]*?static func touch\(\)",
        "macOS settings do not track which writes can change a pane's height")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"let touchesBefore = SettingsLayoutTouches\.count[\s\S]*?"
        r"if SettingsLayoutTouches\.count != touchesBefore \{ panes\[id\]\?\.contentDirty = true \}",
        "macOS settings re-measure a pane whose content did not change")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"let info = webInfo \?\?",
        "macOS settings re-read the network interfaces every time the Integrations pane opens")

# The same window on Windows and GNU/Linux: the system's own frame, a sidebar of panes in the
# contract's order, captions in a fixed trailing column, plain check boxes, and a height that
# follows the pane instead of one size for all six.
pane_count = len(settings_window["panes"])
require("windows/Gantry.Windows/UI/SettingsWindow.xaml", r'WindowStyle="SingleBorderWindow"',
        "the Windows settings window still draws its own chrome, so the system title bar, dark "
        "mode and rounded corners it asks DWM for do nothing")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml", r'SizeToContent="Height"',
        "the Windows settings window does not fit the pane on screen")
require_count("windows/Gantry.Windows/UI/SettingsWindow.xaml", r'<ListBoxItem x:Name="PaneItem',
              pane_count,
              "the Windows settings sidebar does not carry one row per contract pane")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml",
        rf'x:Key="PaneCaption"[\s\S]*?Value="{settings_metrics["captionColumn"]}"',
        "the Windows settings caption column differs from the contract")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml",
        r'x:Key="PaneCaption"[\s\S]*?Property="TextAlignment" Value="Right"',
        "Windows settings captions are not trailing in their column")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml.cs",
        r'"General", "Appearance", "Notifications", "Windows and strip", "Integrations", "Advanced"',
        "the Windows settings panes are not in the contract's order")
# The hand-drawn switch track is what made it look like something other than a Windows window.
forbid("windows/Gantry.Windows/UI/SettingsWindow.xaml", r'x:Name="track"',
       "the Windows settings booleans are switch rows again instead of check boxes")

require("linux/gantry/settings.py", r"use_header_bar=True",
        "the GNU/Linux settings window is not a header-bar preferences window")
require("linux/gantry/settings.py", r"Gtk\.StackSidebar\(\)",
        "the GNU/Linux settings panes are not picked from a sidebar")
require("linux/gantry/settings.py", r"set_vhomogeneous\(False\)",
        "the GNU/Linux settings stack asks for the tallest pane's height, so the window cannot fit "
        "the pane on screen")
require("linux/gantry/settings.py",
        rf"CAPTION_COLUMN = {settings_metrics['captionColumn']}[\s\S]*?"
        rf"CONTROL_COLUMN = {settings_metrics['controlColumn']}",
        "the GNU/Linux settings columns differ from the contract")
require("linux/gantry/settings.py",
        rf"PANES = \((?:\s*\"\w[\w ]*\",){{{pane_count - 1}}}\s*\"\w[\w ]*\",?\s*\)",
        "the GNU/Linux settings pane count differs from the contract")
require("linux/gantry/settings.py", r"xalign=1[\s\S]*?set_size_request\(self\.CAPTION_COLUMN",
        "GNU/Linux settings captions are not trailing in a fixed column")

# Ported with the settings window: the panel stops laying itself out when nobody is looking at it,
# and catches up before it comes back. The tray text and the strip keep running either way.
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"if \(!IsVisible\) \{ _dashboardStale = true; return; \}",
        "the Windows panel rebuilds its cards while hidden")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"IsVisibleChanged \+= .*_dashboardStale.*Rebuild\(\)",
        "the Windows panel does not catch up on telemetry it skipped while hidden")
require("linux/gantry/app.py", r"if not self\.dashboard_visible\(\):\s*\n\s*self\._dashboard_stale = True",
        "the GNU/Linux panel updates its cards while hidden")
require("linux/gantry/app.py",
        r"if getattr\(self, \"_dashboard_stale\", False\):[\s\S]*?self\.rebuild_cards\(\)",
        "the GNU/Linux panel does not catch up on telemetry it skipped while hidden")
require("linux/gantry/edgedock.py", r"signature == getattr\(self, \"_drawn_signature\", None\)",
        "the GNU/Linux strip repositions and redraws for telemetry that says nothing new")
require("linux/gantry/edgedock.py", r"_expanded_width_cache",
        "the GNU/Linux strip re-measures every row through Pango on every draw")

# A camera that produced frames and then went silent is restarted, with a growing delay. The X1
# stops without an error or an EOS, so nothing else notices.
require("windows/Gantry.Windows/UI/DetailWindow.cs",
        r"MinimumCameraRestartDelay = 8[\s\S]*?MaximumCameraRestartDelay = 30",
        "the Windows camera has no silence watchdog")
require("windows/Gantry.Windows/UI/DetailWindow.cs",
        r"private void StopCamera\(\)\s*\{[\s\S]{0,400}?_cameraStarted = false;",
        "Windows StopCamera leaves _cameraStarted set, so the camera cannot be restarted")
require("windows/Gantry.Windows/Services/BambuCameraStream.cs",
        r"timeout=\", StringComparison\.OrdinalIgnoreCase",
        "the Windows RTSP client ignores the session timeout the printer declares")
require("linux/gantry/camera.py",
        r"MINIMUM_RESTART_DELAY = 8\.0[\s\S]*?MAXIMUM_RESTART_DELAY = 30\.0",
        "the GNU/Linux camera has no silence watchdog")
require("linux/gantry/camera.py", r"def _run\(self, stop: threading\.Event\)",
        "a restarted GNU/Linux camera worker shares the stop flag with the run it replaced")

# The state belongs beside the printer's name, in the card, not at the end of a navigation row.
require("windows/Gantry.Windows/UI/DetailWindow.cs",
        r"titleRow\.Children\.Add\(_name\);\s*\n\s*Grid\.SetColumn\(_state, 1\)",
        "the Windows detail state is not beside the printer's name")
require("windows/Gantry.Windows/UI/DetailWindow.cs", r"_name\.MaxWidth = room > 40",
        "a long printer name can push the Windows detail state out of its card")
require("linux/gantry/details.py",
        r"top\.pack_start\(self\.name[\s\S]{0,200}?top\.pack_start\(self\.state_dot"
        r"[\s\S]{0,120}?top\.pack_start\(self\.state_label",
        "the GNU/Linux detail state is not beside the printer's name")
require("linux/gantry/details.py", r"if color != getattr\(self, \"_state_color\", None\)",
        "the GNU/Linux detail view attaches a new style provider per telemetry packet")

# Found by sampling the live macOS app: the detail popover was where the main thread's busy time
# went, and most of it was rebuilding the history/maintenance/statistics labels behind a popover
# nobody had open. Same two guards as the dashboard: visibility, then rebuild only on a change.
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"guard self\.view\.window\?\.isVisible == true else \{[\s\S]{0,120}?refreshStale = true",
        "the macOS detail view refreshes behind a dismissed popover")
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"override func viewWillAppear\(\)[\s\S]{0,400}?if refreshStale \{",
        "the macOS detail view does not catch up on telemetry it skipped while dismissed")
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"guard signature != renderedInsightsSignature else \{ return \}",
        "macOS detail insights are rebuilt per telemetry packet instead of on a real change")

# Remaining percent, grams and the active slot change on every telemetry packet, so a signature that
# includes them can never spare the dock a rebuild — and rebuilding it tore down and recreated every
# filament chip on every card, several times a second. The readings are written into the views that
# are already there; only a shape change (a spool appears or goes, a setting flips) rebuilds.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"if !filamentDock\.apply\(groups, settings: settings\) \{",
        "the macOS filament dock is rebuilt for a reading change instead of updated in place")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"func apply\(slot: FilamentSlot, isExternal: Bool, showRemaining: Bool,",
        "a macOS filament slot cannot take a new reading without being rebuilt")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"var shape: String \{[\s\S]{0,200}?showsLowWarning",
        "the macOS filament slot does not separate its shape from its readings")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"static func settingsKey\(_ settings: AppSettings\) -> String",
        "the macOS filament dock does not notice the settings that change what a slot is made of")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"func apply\(color: NSColor, fraction: CGFloat\)",
        "the macOS filament swatch needs a new view for a new level")

# Every auxiliary panel is its own screen-centred window, not an overlay on the fleet panel. As an
# overlay the slot-assignment list could not be larger than the popover, and growing the popover to
# fit it threw the whole menu-bar window down the screen in one step.
require("Sources/Gantry/Views/PanelWindowController.swift",
        r"window\.center\(\)[\s\S]{0,120}?makeKeyAndOrderFront",
        "a detached panel does not open centred on the screen")
require("Sources/Gantry/Views/PanelWindowController.swift",
        r"window\.level = PanelWindowController\.companionWindow\?\(\)\?\.level",
        "a detached panel does not borrow the fleet panel's window level, so it opens behind it")
require("Sources/Gantry/Views/PanelWindowController.swift",
        r"if holds == 1 \{ onHoldChanged\?\(true\) \}[\s\S]{0,240}?if holds == 0 \{ onHoldChanged\?\(false\) \}",
        "the fleet-panel hold is not reference counted, so closing one of two panels drops it")
forbid("Sources/Gantry/Views/PanelWindowController.swift",
       r"(?:onPreferredContentSize|popover\.contentSize)",
       "a detached panel resizes the fleet panel again, which jumps the whole window")
require("Sources/Gantry/Views/MenuBarController.swift",
        r"popover\.behavior = held \? \.applicationDefined : \.transient",
        "the fleet popover is not held open while a panel is on screen, so it closes under it")
require("Sources/Gantry/Views/MenuBarController.swift",
        r"PanelWindowController\.onHoldChanged = \{[\s\S]{0,200}?PanelWindowController\.companionWindow = \{",
        "the panel hooks are not installed, so panels cannot reach the live fleet presentation")
for panel_name, panel_file in (
    ("FleetStatsViewController", "Sources/Gantry/Views/FleetStatsViewController.swift"),
    ("DiagnosticCenterViewController", "Sources/Gantry/Views/DiagnosticCenterWindowController.swift"),
    ("MaintenancePanelViewController", "Sources/Gantry/Views/MaintenancePanelWindowController.swift"),
):
    require(panel_file, r"activePanel = PanelWindowController\.present\(",
            f"{panel_name} is not presented as its own window")
    # The static is emptied before the window closes; closing it runs the dismissal callback, which
    # lands back in dismiss(), and the empty static is the only thing that stops the recursion.
    require(panel_file, r"let panel = activePanel\s*\n\s*activePanel = nil[\s\S]{0,160}?panel\?\.dismiss\(\)",
            f"{panel_name}.dismiss() closes the window before clearing its static, which recurses")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"PrinterCardView\.activeSpoolPanel = PanelWindowController\.present\(",
        "the slot-assignment panel is not its own window")
require("Sources/Gantry/Spoolbase/SpoolbaseController.swift",
        r"panel = PanelWindowController\.present\(",
        "Spoolbase is not its own window")

# GNU/Linux: the same detachment, with the tray panel's focus-out hide held off instead of a
# popover's behaviour. Measured here: focus-out with a panel open leaves the fleet up, and with
# nothing open it still hides, which is what a tray panel is supposed to do.
require("linux/gantry/panelwindow.py", r"self\.set_position\(Gtk\.WindowPosition\.CENTER\)",
        "a GNU/Linux panel window is not centred on the screen")
require("linux/gantry/panelwindow.py", r"if event\.keyval == Gdk\.KEY_Escape",
        "a GNU/Linux panel window cannot be closed with Escape")
require("linux/gantry/panelwindow.py", r"app\.window\.hold_fleet_panel\(self\)",
        "a GNU/Linux panel window does not hold the fleet panel open")
require("linux/gantry/dashboard.py",
        r"self\._hide_holds = max\(0, self\._hide_holds \+ \(1 if value else -1\)\)",
        "the GNU/Linux fleet hold is a flag, so closing one of two dialogs lets the panel hide")
require("linux/gantry/dashboard.py",
        r'widget\.connect\("map"[\s\S]{0,160}?widget\.connect\("unmap"',
        "the GNU/Linux fleet hold is not bound to the panel being on screen")
require("linux/gantry/dashboard.py", r"from \.panelwindow import PanelWindow",
        "GNU/Linux maintenance is not presented as its own window")
# embed_dialog pulled a dialog apart and re-hosted its child as a dimmed overlay in the fleet window.
forbid("linux/gantry/presentation.py", r"def embed_dialog",
       "the GNU/Linux dialog-into-overlay host is back")
forbid("linux/gantry/app.py", r"embed_dialog",
       "a GNU/Linux dialog is embedded in the fleet window again")
forbid("linux/gantry/spoolassign.py", r"embed_dialog",
       "the GNU/Linux slot-assignment dialog is embedded in the fleet window again")
require("linux/gantry/spoolassign.py", r"app\.window\.hold_fleet_panel\(dialog\)",
        "the GNU/Linux slot-assignment dialog does not hold the fleet panel open")
require("linux/gantry/spoolbase.py", r"app\.window\.hold_fleet_panel\(self\)",
        "the GNU/Linux Spoolbase window does not hold the fleet panel open")
forbid("linux/gantry/spoolbase.py", r"_position_top_right",
       "GNU/Linux Spoolbase is pinned to the corner again instead of centred")
for holder in ("open_diagnostics", "open_fleet_stats"):
    require("linux/gantry/app.py",
            rf"def {holder}\(self\)[\s\S]{{0,900}}?hold_fleet_panel\(dialog\)",
            f"GNU/Linux {holder} does not hold the fleet panel open")
# Statistics are a panel like the others (audit A22): a modal run() locked the fleet and closed on export.
forbid("linux/gantry/app.py", r"def open_fleet_stats\(self\)[\s\S]{0,900}?dialog\.run\(\)",
       "GNU/Linux statistics run as a modal loop again")
require("linux/gantry/fleetstats.py", r"transient_for=app\.window, modal=False",
        "GNU/Linux statistics dialog is modal again")

# Windows: the same detachment. The hold is the dashboard's own Deactivated handler, which walks
# OwnedWindows and refuses to hide while any of them is visible — so it is only a hold if every
# panel actually sets Owner, which nothing on the auxiliary path did before.
require("windows/Gantry.Windows/UI/PanelWindow.cs",
        r"WindowStartupLocation = WindowStartupLocation\.CenterScreen",
        "a Windows panel window is not centred on the screen")
require("windows/Gantry.Windows/UI/PanelWindow.cs", r"if \(owner\.IsLoaded\) Owner = owner;",
        "a Windows panel window is not owned by the fleet panel, so it hides from under it")
require("windows/Gantry.Windows/UI/PanelWindow.cs", r"if \(e\.Key != Key\.Escape\) return;",
        "a Windows panel window cannot be closed with Escape")
require("windows/Gantry.Windows/UI/TrayIcon.cs",
        r"private void ShowAuxiliary\(System\.Windows\.Window controller\)[\s\S]{0,400}?"
        r"if \(dashboard\.IsLoaded\) controller\.Owner = dashboard;",
        "Windows auxiliary windows are not owned by the fleet panel, so it hides from under them")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"_spoolAssignWindow = PanelWindow\.Present\(",
        "the Windows slot-assignment panel is not its own window")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"_maintenanceWindow = PanelWindow\.Present\(",
        "the Windows maintenance panel is not its own window")
for field in ("_spoolAssignWindow", "_maintenanceWindow"):
    require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
            rf"var window = {field};\s*\n\s*{field} = null;\s*\n\s*window\?\.Close\(\);",
            f"Windows {field} is closed before it is cleared, which recurses")
forbid("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs", r"internal void EmbedWindow",
       "the Windows dialog-into-overlay host is back")
forbid("windows/Gantry.Windows/UI/TrayIcon.cs", r"EmbedWindow",
       "a Windows dialog is embedded in the fleet panel again")
forbid("windows/Gantry.Windows/UI/SpoolbaseWindow.cs", r"area\.Right - Width",
       "Windows Spoolbase is pinned to the corner again instead of centred")
forbid("windows/Gantry.Windows/UI/SpoolbaseWindow.cs", r"WindowStyle = WindowStyle\.None",
       "Windows Spoolbase drops its title bar again, which also makes the DWM calls inert")
require("windows/Gantry.Windows/UI/SpoolbaseWindow.cs",
        r"WindowStartupLocation = WindowStartupLocation\.CenterScreen",
        "Windows Spoolbase does not open centred on the screen")
for centred in ("SettingsWindow.xaml", "AddPrinterWindow.xaml"):
    forbid(f"windows/Gantry.Windows/UI/{centred}", r'WindowStartupLocation="CenterOwner"',
           f"Windows {centred} centres on the fleet panel, which sits in a screen corner")


# ---- One frame for every panel window (contract panelWindow.header / slotAssignment) -----------------
# Every panel wears the fleet panel's own header, GANTRY · name, and none draws its own title or close.
require("Sources/Gantry/Views/PanelWindowController.swift",
        r'static func windowTitle\(for name: String\) -> String \{ "Gantry · \\\(name\)" \}',
        "the macOS panel window title is not \"Gantry · name\"")
require("Sources/Gantry/Views/PanelWindowController.swift", r"window\.toolbarStyle = \.unifiedCompact",
        "the macOS panel header is not in a unified title bar beside the traffic lights")
require("Sources/Gantry/Views/PanelWindowController.swift",
        r"GantryLogo\.wordmarkImage\(height: Self\.wordmarkHeight\)[\s\S]{0,700}?NSTextField\(labelWithString: \"·\"\)",
        "the macOS panel header does not carry the fleet header's wordmark and dot")
require("Sources/Gantry/Views/PanelWindowController.swift", r"content\.topAnchor\.constraint\(equalTo: header\.bottomAnchor\)",
        "macOS panel content is not laid out below the shared header")
for own in ("Sources/Gantry/Views/FleetStatsViewController.swift",
            "Sources/Gantry/Views/DiagnosticCenterWindowController.swift",
            "Sources/Gantry/Views/MaintenancePanelWindowController.swift"):
    forbid(own, r"#selector\(closePressed\)", "a macOS panel draws its own close button again beside the shared header")
forbid("Sources/Gantry/Spoolbase/MinimalFilamentPopoverViewController.swift", r'NSTextField\(labelWithString: "Spoolbase"\)',
       "macOS Spoolbase draws its own title again under the shared header")
forbid("Sources/Gantry/Spoolbase/SpoolAssignPopoverViewController.swift", r"func addCloseButton",
       "the macOS slot panel draws its own close button again")
forbid("Sources/Gantry/Spoolbase/SpoolAssignPopoverViewController.swift", r"preferredContentWidth",
       "the macOS slot panel sizes itself from its longest name again instead of filling its window")
require("Sources/Gantry/Spoolbase/SpoolAssignPopoverViewController.swift",
        r"present\(columns: \[[\s\S]{0,200}?scrollFrom: 3\),[\s\S]{0,120}?scrollFrom: 1\)",
        "the macOS slot panel's main screen is not two columns")
require("Sources/Gantry/Spoolbase/SpoolAssignPopoverViewController.swift", r"row\.distribution = \.fillEqually",
        "the macOS slot panel's columns are not equal")
require("Sources/Gantry/Spoolbase/SpoolAssignPopoverViewController.swift",
        rf"singleColumnWidth: CGFloat = {slot_assignment['singleColumnWidth']}\b[\s\S]{{0,160}}?columnGap: CGFloat = {slot_assignment['columnGap']}\b",
        "macOS slot panel column metrics differ from the contract")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        rf"name: title,\s*size: NSSize\(width: {panel_window['sizes']['slotAssignment']['width']}, height: {panel_window['sizes']['slotAssignment']['height']}\)",
        "the macOS slot panel window size differs from the contract")

require("linux/gantry/panelwindow.py", r'return f"Gantry · \{name\}"', "the GNU/Linux panel window title is not \"Gantry · name\"")
require("linux/gantry/panelwindow.py", r'header\.set_custom_title\(Gtk\.Box\(\)\)[\s\S]{0,300}?Gtk\.Label\(label="GANTRY"\)',
        "the GNU/Linux panel header does not carry the wordmark at its leading edge")
require("linux/gantry/panelwindow.py", r"panel_header\(self, name, accessories\)", "GNU/Linux PanelWindow does not wear the shared header")
for own, target in (("linux/gantry/fleetstats.py", "self"), ("linux/gantry/diagnostics.py", "self"),
                    ("linux/gantry/spoolbase.py", "self"), ("linux/gantry/spoolassign.py", "dialog")):
    require(own, rf"panel_header\({target}, ", f"{own} does not wear the shared panel header")
forbid("linux/gantry/maintenance.py", r'Gtk\.Button\(label="×"\)', "GNU/Linux maintenance draws its own close button again")
require("linux/gantry/spoolassign.py", r"columns = Gtk\.Box\(spacing=20\)[\s\S]{0,400}?columns\.pack_start\(right",
        "the GNU/Linux slot dialog is not two columns")
require("linux/gantry/dashboard.py", r"\.panel-wordmark \{", "the GNU/Linux panel header has no wordmark style")

require("windows/Gantry.Windows/UI/PanelWindow.cs", r'public static string WindowTitle\(string name\) => \$"Gantry · \{name\}";',
        "the Windows panel window title is not \"Gantry · name\"")
require("windows/Gantry.Windows/UI/PanelWindow.cs", r'Text = "GANTRY"[\s\S]{0,400}?Text = "·"',
        "the Windows panel header does not carry the wordmark and dot")
require("windows/Gantry.Windows/UI/PanelWindow.cs", r"Wrap\(this, name, body, accessories\);",
        "Windows PanelWindow does not wear the shared header")
require("windows/Gantry.Windows/UI/PanelWindow.cs", r"content\.MaxHeight = double\.PositiveInfinity;",
        "a Windows panel keeps the overlay's pinned size inside its window")
for own, name in (("windows/Gantry.Windows/UI/DiagnosticsWindow.cs", r'AppSettings\.T\("Diagnostic Center"\)'),
                  ("windows/Gantry.Windows/UI/FleetStatsWindow.cs", r'AppSettings\.T\("Fleet statistics"\)'),
                  ("windows/Gantry.Windows/UI/SpoolbaseWindow.cs", r'"Spoolbase"')):
    require(own, rf"PanelWindow\.Wrap\(this, {name}", f"{own} does not wear the shared panel header")
forbid("windows/Gantry.Windows/UI/MaintenanceWindow.cs", r'Button\("×"\)', "Windows maintenance draws its own close button again")
forbid("windows/Gantry.Windows/UI/SpoolbaseWindow.cs", r'Text = "Spoolbase", FontSize = 18',
       "Windows Spoolbase draws its own title again under the shared header")
require("windows/Gantry.Windows/UI/SpoolAssignPanel.cs", r"SetColumns\(left, right\);", "the Windows slot panel's main screen is not two columns")
require("windows/Gantry.Windows/UI/SpoolAssignPanel.cs",
        rf"SingleColumnWidth = {slot_assignment['singleColumnWidth']};[\s\S]{{0,200}}?ColumnGap = {slot_assignment['columnGap']};",
        "Windows slot panel column metrics differ from the contract")
forbid("windows/Gantry.Windows/UI/SpoolAssignPanel.cs", r"PreferredWidth\(\)|MaxHeight = 440",
       "the Windows slot panel pins its overlay size again instead of filling its window")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        rf"title, {panel_window['sizes']['slotAssignment']['width']}, 600, cleanup: CloseSpoolAssign",
        "the Windows slot panel window size differs from the contract")


# ---- Windows edge dock: pin/release and live pictures (issue #34, ported from macOS) ----------------
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"private bool Expanded => _hovering \|\| AppSettings\.EdgeDockPinned;",
        "a pinned Windows edge dock still folds when the pointer leaves")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"AppSettings\.EdgeDockPinned = !AppSettings\.EdgeDockPinned;",
        "the Windows edge dock cannot be pinned or released from the strip itself")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"new DockCameraFeed\(_store, serial\)",
        "the Windows edge dock shows no live pictures")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"if \(wanted\.SetEquals\(_cameraFeeds\.Keys\)\) return;",
        "the Windows edge dock restarts camera streams on refreshes that did not change which printers stream")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"private void HideStrip\(\)\s*\{\s*DetachCameras\(\);",
        "a hidden Windows edge dock keeps its camera streams running")
require("windows/Gantry.Windows/UI/DockCameraFeed.cs",
        r"kind is PrinterKind\.Bambu or PrinterKind\.Klipper or PrinterKind\.ElegooCc1\s+or PrinterKind\.ElegooCc2 or PrinterKind\.AnycubicKobraS1",
        "Windows dock cameras support a different set of printer brands than macOS")
for key in ("edge-dock-pinned", "edge-dock-camera", "edge-dock-camera-serials"):
    require("windows/Gantry.Windows/Services/Storage.cs", rf'"{key}"', f"Windows does not share the {key} setting with macOS")
for control in ("DockPinnedCheckBox", "DockCameraCheckBox", "DockCamerasList"):
    require("windows/Gantry.Windows/UI/SettingsWindow.xaml", rf'x:Name="{control}"', f"Windows settings are missing {control}")
# The fleet header's tools stay on one line: a WrapPanel capped at 300 px folded nine buttons into two.
forbid("windows/Gantry.Windows/UI/DashboardWindow.xaml", r'<WrapPanel x:Name="HeaderTools"',
       "the Windows fleet header tools wrap onto a second line again")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml", r'<StackPanel x:Name="HeaderTools" Grid\.Column="1" Orientation="Horizontal"',
        "the Windows fleet header tools are not a single row")


# ---- Edge dock on all three platforms (contract edgeDock) --------------------------------------------
def _number(value: float) -> str:
    """A contract number as each platform may spell it: 5, 5.0 and 1.5 all match their own value."""
    whole = float(value).is_integer()
    return rf"{int(value)}(?:\.0)?" if whole else re.escape(repr(float(value)))

# One pin shape everywhere: the same points, in order, in all three sources.
PIN_POINTS_PATTERN = r",\s*".join(rf"\(\s*{_number(x)},\s*{_number(y)}\s*\)" for x, y in edge_dock["pinControl"]["points"])
for pin_source in ("Sources/Gantry/Views/EdgeDockWindowController.swift",
                   "windows/Gantry.Windows/UI/EdgeDockWindow.cs",
                   "linux/gantry/edgedock.py"):
    require(pin_source, PIN_POINTS_PATTERN, "the edge-dock pin is not the contract's shape")
released = _number(edge_dock["pinControl"]["releasedAngle"])
require("Sources/Gantry/Views/EdgeDockWindowController.swift", rf"pinReleasedAngle: CGFloat = {released}\b",
        "the macOS released pin angle differs from the contract")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", rf"PinReleasedAngle = {released};",
        "the Windows released pin angle differs from the contract")
require("linux/gantry/edgedock.py", rf"PIN_RELEASED_ANGLE = {released}\b",
        "the GNU/Linux released pin angle differs from the contract")
# Drawn, not borrowed: an emoji or a platform symbol is a different pin on every system.
forbid("windows/Gantry.Windows/UI/EdgeDockWindow.cs", "📌", "the Windows edge dock draws the pin as an emoji again")
forbid("Sources/Gantry/Views/EdgeDockWindowController.swift", r'"pin\.fill"', "the macOS edge dock draws the pin as an SF Symbol again")
# The pin both pins and releases, and its band is there whenever the strip is open.
require("Sources/Gantry/Views/EdgeDockWindowController.swift", r"edgeDockPinned\.toggle\(\)",
        "the macOS strip can only release itself, not pin itself")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"isExpanded \? \(Self\.pinRow \+ Self\.pinGap\) \* scale : 0",
        "the macOS pin band is not there whenever the strip is open")
require("linux/gantry/edgedock.py", r'pinned = not self\.pinned\s*\n\s*self\.app\.config\.data\["edge-dock-pinned"\] = pinned',
        "the GNU/Linux strip cannot be pinned or released from the strip itself")
require("linux/gantry/edgedock.py", r"body = PAD_Y \* 2 \+ EXPANDED_BOTTOM_PAD \+ PIN_ROW \+ PIN_GAP \+ rows",
        "the GNU/Linux pin band is not there whenever the strip is open")

# ---- Edge dock placement: chosen display, six places, inner-edge dwell (contract edgeDock.placement) ----
placement = edge_dock["placement"]
PLACEMENT_SOURCES = {
    "macOS": "Sources/Gantry/Views/EdgeDockPlacement.swift",
    "Windows": "windows/Gantry.Windows/Services/EdgeDockPlacement.cs",
    "GNU/Linux": "linux/gantry/dockplacement.py",
}
PLACEMENT_CONSTANTS = [
    ("row margin", rf"static let rowMargin: CGFloat = {_number(placement['rowMargin'])}\b",
     rf"public const double RowMargin = {_number(placement['rowMargin'])};", rf"ROW_MARGIN = {_number(placement['rowMargin'])}\b"),
    ("display tolerance", rf"static let displayTolerance: CGFloat = {_number(placement['displayTolerance'])}\b",
     rf"public const double DisplayTolerance = {_number(placement['displayTolerance'])};",
     rf"DISPLAY_TOLERANCE = {_number(placement['displayTolerance'])}\b"),
    ("inner-edge dwell", rf"static let innerEdgeDwell: TimeInterval = {_number(placement['innerEdgeDwellMs'] / 1000)}\b",
     rf"public const int InnerEdgeDwellMs = {placement['innerEdgeDwellMs']};", rf"INNER_EDGE_DWELL_MS = {placement['innerEdgeDwellMs']}\b"),
    ("display change debounce", rf"static let displayChangeDebounceMilliseconds = {placement['displayChangeDebounceMs']}\b",
     rf"public const int DisplayChangeDebounceMs = {placement['displayChangeDebounceMs']};",
     rf"DISPLAY_CHANGE_DEBOUNCE_MS = {placement['displayChangeDebounceMs']}\b"),
]
for name, *patterns in PLACEMENT_CONSTANTS:
    for (platform, placement_source), pattern in zip(PLACEMENT_SOURCES.items(), patterns):
        require(placement_source, pattern, f"the {platform} edge-dock {name} differs from the contract")
for key in placement["settingsKeys"]:
    for settings_source in ("Sources/Gantry/App/AppSettings.swift", "windows/Gantry.Windows/Services/Storage.cs",
                            "linux/gantry/edgedock.py"):
        require(settings_source, rf'"{key}"', f"{settings_source} does not share the {key} setting")
# The strip follows the chosen display, not whatever the system calls main at the moment.
forbid("Sources/Gantry/Views/EdgeDockWindowController.swift", r"NSScreen\.main",
       "the macOS edge dock follows the key window's screen again instead of the chosen display")
forbid("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"SystemParameters\.VirtualScreen",
       "the Windows edge dock sits on the virtual desktop's outer edge again instead of the chosen display")
forbid("linux/gantry/edgedock.py", r"get_primary_monitor\(\)",
       "the GNU/Linux edge dock is pinned to the primary monitor again instead of the chosen display")
# The six-square picker and the menu submenu exist on every platform.
require("Sources/Gantry/Views/SettingsWindowController.swift", r"grid\.field\(dockPositionCaption, dockPositionPicker",
        "macOS settings have no edge-dock position picker")
require("windows/Gantry.Windows/UI/SettingsWindow.xaml", r'x:Name="DockPositionPicker"', "Windows settings have no edge-dock position picker")
require("linux/gantry/settings.py", r'pane\.field\(i18n\.t\("Position"\), self\.dock_position', "GNU/Linux settings have no edge-dock position picker")
require("Sources/Gantry/Views/MenuBarController.swift", r"edgeDockMenu\(settings: settings\)", "the macOS menu has no edge-dock submenu")
require("windows/Gantry.Windows/UI/TrayIcon.cs", r"BuildEdgeDockMenu\(\)", "the Windows tray has no edge-dock submenu")
require("linux/gantry/app.py", r"self\._fill_dock_menu\(dock_menu\)", "the GNU/Linux tray has no edge-dock submenu")

# ---- Card header: nothing cut off, nothing wrapped (contract header.nameLabel / manufacturerPill) ----------
# The printer name and the file name scroll while hovered on every platform instead of ending cut off.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift", r"private let nameLabel = MarqueeLabel\(\)",
        "the macOS card name does not scroll like the file name")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", r"_name = new MarqueeText", "the Windows card name does not scroll")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", r"_job = new MarqueeText", "the Windows file name does not scroll")
require("linux/gantry/dashboard.py", r'self\.name = MarqueeLabel\(printer\.name, "printer-name"\)', "the GNU/Linux card name does not scroll")
require("linux/gantry/dashboard.py", r'self\.job = MarqueeLabel\("", "job"\)', "the GNU/Linux file name does not scroll")
# The connection pill gives way before the chips on the right are pushed out of the card.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift", r"minimumNameWidth: CGFloat = 48[\s\S]*?func fitConnectionPill",
        "the macOS card header does not drop the connection pill when short of room")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs", r"MinimumNameWidth = 48;[\s\S]*?private void FitHeader\(\)",
        "the Windows card header does not drop the connection pill when short of room")
# The popover grows with the card scale, so a scaled card keeps its proportions instead of growing taller.
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        rf"Width = \(cols == 1 \? {one} : {two}\) \* AppSettings\.CardScalePercent / 100\.0;",
        "the Windows popover width differs from the contract or ignores the card scale")
require("linux/gantry/layout.py", rf"return {one} if max\(1, min\(2, columns\)\) == 1 else {two}",
        "the GNU/Linux panel widths differ from the contract")
require("linux/gantry/edgedock.py", r"return self\.hovering or self\.pinned",
        "a pinned GNU/Linux strip still folds when the pointer leaves")
# Captions under pictures in the open strip: same metrics on macOS and GNU/Linux, Windows in its own units.
captions = edge_dock["captions"]
for name, swift, python in (("insetX", "insetX", "INSET_X"), ("pictureRadius", "pictureRadius", "PICTURE_RADIUS"),
                            ("overlayShade", "overlayShade", "OVERLAY_SHADE"), ("overlayPadX", "overlayPadX", "OVERLAY_PAD_X"),
                            ("captionMinHeight", "captionMinHeight", "CAPTION_MIN_HEIGHT"),
                            ("captionPadY", "captionPadY", "CAPTION_PAD_Y"), ("captionInnerGap", "captionInnerGap", "CAPTION_INNER_GAP"),
                            ("wrappedLineGap", "wrappedLineGap", "WRAPPED_LINE_GAP"), ("noteRow", "statusRow", "STATUS_ROW"),
                            ("noteIcon", "statusIcon", "STATUS_ICON"), ("printerGap", "printerGap", "PRINTER_GAP")):
    value = _number(captions[name])
    require("Sources/Gantry/Views/EdgeDockWindowController.swift", rf"static let {swift}: CGFloat = {value}\b",
            f"macOS edge-dock caption {name} differs from the contract")
    require("linux/gantry/dockcaptions.py", rf"^{python} = {value}(\.0)?$",
            f"GNU/Linux edge-dock caption {name} differs from the contract")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        r"private const double InsetX = 12, PictureRadius = 9, CaptionMinHeight = 34, CaptionPadY = 5,[\s\S]{0,160}PrinterGap = 10,"
        r"\s*OverlayShade = 52, OverlayShadeAlpha = 0\.72, OverlayPadX = 10,",
        "Windows edge-dock captions differ from the contract's Windows units")
# The caption lies over the bottom of its picture: the fade's strength per platform, one line over a picture.
shade_alpha = captions["overlayShadeAlpha"]
require("Sources/Gantry/Views/EdgeDockWindowController.swift", rf"static let overlayShadeAlpha: CGFloat = {shade_alpha['macOS']}\b",
        "macOS edge-dock caption fade differs from the contract")
require("linux/gantry/dockcaptions.py", rf"^OVERLAY_SHADE_ALPHA = {shade_alpha['linux']}$",
        "GNU/Linux edge-dock caption fade differs from the contract")
require("Sources/Gantry/Views/EdgeDockWindowController.swift", r"static let captionBlurHeight: CGFloat = 40\b",
        "the macOS frosted band under a caption differs from the contract")
require("linux/gantry/edgedock.py", r"measure\.use\(measure\.name_font, entry\[\"name\"\], room, ellipsize=True\)",
        "a long GNU/Linux name over a picture is not cut with an ellipsis")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"TextTrimming = row\.Wraps \? TextTrimming\.None : TextTrimming\.CharacterEllipsis",
        "a long Windows name over a picture is not cut with an ellipsis")
# How long is left and when it ends, as on the fleet cards.
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r'return "\\\(entry\.progress\)% · \\\(left\) · \\\(finish\)"', "the macOS strip no longer shows the finish time")
require("linux/gantry/dockcaptions.py", r'return f"\{progress\}% · \{left\} · \{finish_clock\}"',
        "the GNU/Linux strip no longer shows the finish time")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"\{DateTime\.Now\.AddMinutes\(minutes\):t\}",
        "the Windows strip no longer shows the finish time")
# The settings button under the strip: one circle, one gear, the same pane on every platform.
button = edge_dock["settingsButton"]
gear = button["gear"]
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        rf"gearTeeth = {gear['teeth']}\b[\s\S]{{0,60}}gearRoot: CGFloat = {gear['root']}\b[\s\S]{{0,60}}gearTipSpan: CGFloat = {gear['tipSpan']}\b"
        rf"[\s\S]{{0,60}}gearRootSpan: CGFloat = {_number(gear['rootSpan'])}0?\b[\s\S]{{0,60}}gearHole: CGFloat = {gear['hole']}\b",
        "the macOS gear differs from the contract")
require("linux/gantry/dockcaptions.py",
        rf"GEAR_TEETH = {gear['teeth']}\nGEAR_ROOT = {gear['root']}\nGEAR_TIP_SPAN = {gear['tipSpan']}\nGEAR_ROOT_SPAN = {_number(gear['rootSpan'])}0?\nGEAR_HOLE = {gear['hole']}\n",
        "the GNU/Linux gear differs from the contract")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        rf"GearTeeth = {gear['teeth']};[\s\S]{{0,40}}GearRoot = {gear['root']}, GearTipSpan = {gear['tipSpan']}, GearRootSpan = {_number(gear['rootSpan'])}0?, GearHole = {gear['hole']};",
        "the Windows gear differs from the contract")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        rf"orbArcGap: CGFloat = {_number(button['restingArc']['gap'])}\b[\s\S]{{0,60}}orbStroke: CGFloat = {_number(button['restingArc']['stroke'])}\b"
        rf"[\s\S]{{0,200}}orbBand: CGFloat = {button['band']['macOS']}\b",
        "the macOS settings button differs from the contract")
require("linux/gantry/edgedock.py",
        rf"ORB_BAND = {button['band']['linux']}\.0\nORB_ARC_GAP = {_number(button['restingArc']['gap'])}\.0\nORB_STROKE = {_number(button['restingArc']['stroke'])}\.0",
        "the GNU/Linux settings button differs from the contract")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        rf"OrbBand = {button['band']['windows']}, OrbArcGap = {button['restingArc']['windows']['gap']}, OrbStroke = {button['restingArc']['windows']['stroke']},",
        "the Windows settings button differs from the contract")
require("Sources/Gantry/Views/MenuBarController.swift", r"showSettings\(\)\s*\n\s*settingsWindow\?\.selectWindowsPane\(\)",
        "the macOS settings button does not open the strip's pane")
require("linux/gantry/app.py", r'dialog\.stack\.set_visible_child_name\("windows"\)',
        "the GNU/Linux settings button does not open the strip's pane")
require("windows/Gantry.Windows/UI/TrayIcon.cs", r"ShowSettings\(\);\s*\n\s*_settings\?\.SelectWindowsPane\(\);",
        "the Windows settings button does not open the strip's pane")
# Nothing over a picture, pictures never cropped, the fallbacks for a small display, live pictures first.
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"new Image \{ Stretch = Stretch\.Uniform, IsHitTestVisible = false \}",
        "Windows edge-dock pictures are cropped again")
require("linux/gantry/edgedock.py", r"factor = min\(w / pw, h / ph\)", "GNU/Linux edge-dock pictures are cropped again")
require("Sources/Gantry/Views/CameraFeed.swift", r"displayLayer\.videoGravity = \.resizeAspect\b", "macOS camera pictures are cropped again")
for dock_source in ("Sources/Gantry/Views/EdgeDockWindowController.swift", "windows/Gantry.Windows/UI/EdgeDockWindow.cs",
                    "linux/gantry/dockcaptions.py"):
    require(dock_source, r"Not enough room for the preview", f"{dock_source}: a picture that does not fit is not replaced by a note")
    require(dock_source, r"minimumPictureShare|MinimumPictureShare|MINIMUM_PICTURE_SHARE", f"{dock_source}: pictures do not shrink to fit the display")
require("Sources/Gantry/Views/EdgeDockWindowController.swift", r"described\.filter \{ \$0\.camera == \.live \} \+ described\.filter \{ \$0\.camera != \.live \}",
        "macOS edge dock no longer lists printers with a live picture first")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs", r"_entries = described\.Where\(entry => entry\.Camera == DockCamera\.Live\)",
        "Windows edge dock no longer lists printers with a live picture first")
require("linux/gantry/edgedock.py", r"entries = \[entry for entry in entries if entry\[\"camera\"\] == dc\.LIVE\]",
        "GNU/Linux edge dock no longer lists printers with a live picture first")
for dock_source in ("windows/Gantry.Windows/UI/EdgeDockWindow.cs", "linux/gantry/edgedock.py"):
    require(dock_source, r"_picture_?[hH]its", f"{dock_source}: a click on a picture opens the printer again")
# Pictures: same width band, same brands, same stream rules.
cams = edge_dock["cameras"]
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        rf"cameraMinStripWidth: CGFloat = {_number(cams['minStripWidth'])}\b[\s\S]{{0,40}}?cameraMaxStripWidth: CGFloat = {_number(cams['maxStripWidth'])}\b",
        "macOS edge-dock picture width band differs from the contract")
require("windows/Gantry.Windows/UI/EdgeDockWindow.cs",
        rf"CameraMinStripWidth = {_number(cams['minStripWidth'])}, CameraMaxStripWidth = {_number(cams['maxStripWidth'])};",
        "Windows edge-dock picture width band differs from the contract")
require("linux/gantry/dockcaptions.py",
        rf"CAMERA_MIN_STRIP_WIDTH = {_number(cams['minStripWidth'])}\s*\nCAMERA_MAX_STRIP_WIDTH = {_number(cams['maxStripWidth'])}",
        "GNU/Linux edge-dock picture width band differs from the contract")
require("linux/gantry/camera.py",
        r"CAMERA_KINDS = frozenset\(\{PrinterKind\.BAMBU, PrinterKind\.KLIPPER, PrinterKind\.ELEGOO_CC1,\s*PrinterKind\.ELEGOO_CC2, PrinterKind\.ANYCUBIC_KOBRA_S1\}\)",
        "GNU/Linux camera brands differ from macOS and Windows")
require("linux/gantry/camera.py", r"sink = self\.frame_sink\s*\n\s*if sink is not None:",
        "the GNU/Linux camera cannot hand frames to the edge dock")
require("linux/gantry/edgedock.py", r"view\.frame_sink = lambda pixbuf",
        "the GNU/Linux edge dock shows no live pictures")
require("linux/gantry/edgedock.py", r"if wanted == set\(self\.camera_views\):\s*\n\s*return",
        "the GNU/Linux edge dock restarts streams on refreshes that did not change which printers stream")
require("linux/gantry/edgedock.py", r"def hide\(self\) -> None:[\s\S]{0,300}?self\._detach_cameras\(\)",
        "a hidden GNU/Linux edge dock keeps its camera streams running")
for key in edge_dock["settingsKeys"]:
    require("linux/gantry/settings.py", rf'"{key}"', f"GNU/Linux settings do not write the shared {key} setting")
# Geometry fixed along the way: the ring beside the physical edge, the silhouette mirrored only for the
# left edge, and folding after a grace period instead of on the leave event the resize itself causes.
require("linux/gantry/edgedock.py", r"ring_x = dc\.INSET_X \+ RING / 2 if left else width - dc\.INSET_X - RING / 2",
        "the GNU/Linux ring is not beside the physical screen edge")
require("linux/gantry/edgedock.py", r"if left:\s*\n\s*# The silhouette is drawn flush against the right edge",
        "the GNU/Linux silhouette is mirrored for the wrong edge")
require("linux/gantry/edgedock.py", r"GLib\.timeout_add\(COLLAPSE_DELAY_MS, self\._collapse_if_left\)",
        "the GNU/Linux strip folds on the leave event its own resize emits")

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
        r"func snappedFloatingContentSize[\s\S]*?columnPitch:\s*CGFloat\s*=\s*\(325 \+ GantryTheme\.cardGap\)[\s\S]*?height:\s*proposed\.height",
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
        r"cardScaleControl[\s\S]*?dockScaleControl",
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
# A camera stream that dies loudly is handled by its state callback. One that simply goes quiet was
# handled by nothing: measured on an X1, frames stopped after five to ten seconds with no error, no
# teardown and no state change, and the last frame stayed on screen for ever, which is what a camera
# "lagging" in the strip actually was. The keep-alive is the cause, the watchdog is the net.
require("Sources/Gantry/Services/RTSPCameraStream.swift",
        r"private func startKeepAlive\(\)[\s\S]*?OPTIONS \\\(self\.requestURL\)",
        "the RTSP session is never kept alive, so a printer stops feeding it")
require("Sources/Gantry/Services/RTSPCameraStream.swift",
        r"timeout=[\s\S]*?sessionTimeout = max\(5, seconds\)",
        "the RTSP session timeout is parsed away instead of driving the keep-alive")
require("Sources/Gantry/Views/CameraFeed.swift",
        r"private func checkForSilence\(\)[\s\S]*?restartDelay \* 2[\s\S]*?start\(\)",
        "a camera feed that goes silent is never restarted")
# The detail popover has one width. It used to have two: the root view was pinned to 480 while the
# host was told 600, both when the popover was opened and in every size reported afterwards, so 120
# points of it were empty down the right-hand side. It showed up in an error state because the report
# only went out when the height changed, and an error changes the height.
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"static let popoverContentWidth: CGFloat = 480[\s\S]*?"
        r"root\.widthAnchor\.constraint\(equalToConstant: Self\.popoverContentWidth\)",
        "the macOS detail view lays itself out at a width of its own")
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"NSSize\(width: Self\.popoverContentWidth, height: target\)",
        "the macOS detail view reports a width it does not lay itself out at")
require("Sources/Gantry/Views/MenuBarController.swift",
        r"PrinterDetailViewController\.popoverContentWidth",
        "the popover opens the detail view at a width of its own")
# Both the header and the cards hang off the clip view, so they keep one right edge whether or not a
# scroller is taking its lane, and the document can never come out wider than what is visible.
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"header\.trailingAnchor\.constraint\(equalTo: scroll\.contentView\.trailingAnchor",
        "the macOS detail header does not share its right edge with the cards")
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"flipped\.widthAnchor\.constraint\(equalTo: scroll\.contentView\.widthAnchor\)",
        "the macOS detail column does not track the visible width, so its edge can be clipped")
# The state rides next to the printer's name inside the status card, not at the far right of the
# navigation row a whole row away from the printer it describes.
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"NSStackView\(views: \[nameLabel, stateDot, stateLabel, NSView\(\), percentLabel\]\)",
        "the macOS detail state is not beside the printer's name")
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"nameLabel\.setContentCompressionResistancePriority\(\.defaultLow, for: \.horizontal\)",
        "a long printer name pushes the state out instead of truncating")
require("Sources/Gantry/Views/SettingsWindowController.swift",
        r"dockPinnedCheck[\s\S]*?dockCameraCheck",
        "macOS settings are missing the edge-dock pin and camera switches")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"pinButtonRect\(\)[\s\S]*?onTogglePin\?\(\)",
        "macOS pinned edge dock cannot be released from the strip itself")

# Frosted glass and an animated unfold, macOS only for now. The grace timer is not decoration: an
# animated edge slides out from under the pointer and the leave event that follows would fold the
# strip straight back, the loop the Windows port hit in issue #32.
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"blendingMode = \.behindWindow[\s\S]*?backdrop\.maskImage = mask",
        "macOS edge dock has no frosted backdrop clipped to its silhouette")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"unfoldDuration[\s\S]*?panel\.animator\(\)\.setFrame",
        "macOS edge dock snaps open instead of animating")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"collapseTimer = Timer\.scheduledTimer[\s\S]*?collapseIfPointerLeft",
        "macOS edge dock can fold on the leave event its own animation causes")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"sin\(CGFloat\.pi \* progress\)[\s\S]*?kCIInputRadiusKey[\s\S]*?rowsView\.contentFilters = \[blur\]",
        "macOS edge dock rows do not blur along the unfold")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"class EdgeDockRowsView[\s\S]*?owner\?\.drawRows\(\)",
        "macOS edge dock draws its rows into the silhouette, so a blur would soften its edges")

# Smoothness, measured rather than assumed. Each of these replaced work that ran on every frame or
# every telemetry packet; a sample of the running app put two thirds of the main thread in the last
# one. They are invariants, not preferences: undo any of them and the stutter comes straight back.
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"override func setFrameSize[\s\S]*?syncUnfoldProgress\(\)",
        "macOS edge dock runs a second animation clock instead of following the window's own width")
require("Sources/Gantry/Views/EdgeDockWindowController.swift",
        r"guard key != maskKey else \{ return \}",
        "macOS edge dock re-masks its frosted backdrop on layout passes that never changed the shape")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"guard view\.window\?\.isVisible == true else \{ return \}",
        "macOS dashboard lays out and measures its cards while nobody is looking at them")
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"if shape != zoneShape \{[\s\S]*?ThermalZoneView\(label: zone\.0,",
        "macOS temperature tiles are rebuilt per telemetry packet instead of updated in place")

# Issue #34, the second half: the detail panel must take the height its cards need, capped by the
# screen, instead of the constant it used to be nailed to. GNU/Linux already sizes to content through
# set_propagate_natural_height, so only the two ports that hard-coded a number are checked here.
require("Sources/Gantry/Views/PrinterDetailWindowController.swift",
        r"minimumPopoverHeight[\s\S]*?func updatePreferredHeight\(\)[\s\S]*?visibleFrame\.height",
        "macOS detail popover height is not driven by its cards and the screen")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"private void FitPanel\(\)[\s\S]*?double\.PositiveInfinity[\s\S]*?WorkArea\.Height",
        "Windows bounded panel height is not measured from its content and the work area")

# The fleet header sits on a translucent panel on all three, so its tile has to carry its own
# contrast. Borrowed from the backdrop it read as near-white on near-white over a bright window.
require("Sources/Gantry/Views/PrinterDashboardViewController.swift",
        r"header\.layer\?\.backgroundColor = GantryTheme\.surfaceOnBackdrop\.cgColor",
        "macOS fleet header borrows its contrast from the desktop behind the panel")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"FleetHeaderPlate\.Background = GTheme\.Brush\(GTheme\.SurfaceOnBackdrop\)",
        "Windows fleet header borrows its contrast from the desktop behind the panel")
require("linux/gantry/dashboard.py",
        r"\.fleet-header \{ background: %\(surface_on_backdrop\)s;",
        "Linux fleet header borrows its contrast from the desktop behind the panel")
require("windows/Gantry.Windows/UI/DashboardWindow.Presentation.cs",
        r"CardColumnPitch\s*=>\s*\(325 \+ GTheme\.FleetColumnGap\) \* AppSettings\.CardScalePercent / 100\.0[\s\S]*?SnapWindowToTiles\(\)[\s\S]*?columnPitch = CardColumnPitch[\s\S]*?FitHeightToContent",
        "Windows floating window is not snapped to card columns with content-driven height")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        r"if \(WindowMode\) return false;.*full card tiles",
        "Windows still switches to compact rows while resizing the window")
require("linux/gantry/presentation.py",
        r"TILE_PITCH = 325 \+ 12\n[\s\S]*?def _snapped_tile_size[\s\S]*?pitch = TILE_PITCH \* scale[\s\S]*?columns \* pitch[\s\S]*?content_height_for_width",
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

require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        rf"Width\s*=\s*{compact}\s*\*\s*AppSettings\.CardScalePercent\s*/\s*100\.0;",
        "compact width does not match macOS or ignores the card scale")
require("windows/Gantry.Windows/UI/DashboardWindow.xaml.cs",
        rf"Width\s*=\s*\(cols\s*==\s*1\s*\?\s*{one}\s*:\s*{two}\)\s*\*\s*AppSettings\.CardScalePercent", "panel widths do not match macOS")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"FleetColumnGap\s*=\s*{column_gap};",
        "column gap does not match macOS")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"FleetRowGap\s*=\s*{row_gap};",
        "row gap does not match macOS")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"CardRadius\s*=\s*{radius};",
        "card radius differs from the contract")
require("windows/Gantry.Windows/UI/GantryTheme.cs", rf"public const double Gap\s*=\s*{theme_gap};",
        "theme gap differs from the contract")

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
        r"double ringX = left \? \(InsetX \+ Ring / 2\) \* scale : width - \(InsetX \+ Ring / 2\) \* scale",
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

# Printer control in Details (macOS and Windows): the setpoint capsule sits inside the tile it changes.
detail_controls = CONTRACT["detailControls"]
capsule = detail_controls["capsule"]
steps = detail_controls["steps"]
ranges = detail_controls["ranges"]
timing = detail_controls["timing"]
mac_detail = "Sources/Gantry/Views/PrinterDetailWindowController.swift"
win_stepper = "windows/Gantry.Windows/UI/ControlStepper.cs"
win_detail = "windows/Gantry.Windows/UI/DetailWindow.cs"
require(mac_detail, rf"static let height: CGFloat = {capsule['height']}\b[\s\S]*?buttonWidth: CGFloat = {capsule['buttonWidth']}\b"
        rf"[\s\S]*?settleDelay: TimeInterval = {timing['settleSeconds']}\b[\s\S]*?echoWindow: TimeInterval = {timing['echoWindowSeconds']}\b",
        "macOS setpoint capsule geometry or timing differs from the contract")
require(win_stepper, rf"CapsuleHeight = {capsule['height']};[\s\S]*?ButtonWidth = {capsule['buttonWidth']};[\s\S]*?Radius = {capsule['radius']};"
        rf"[\s\S]*?FromMilliseconds\({int(timing['settleSeconds'] * 1000)}\)[\s\S]*?EchoWindow = TimeSpan\.FromSeconds\({timing['echoWindowSeconds']}\)",
        "Windows setpoint capsule geometry or timing differs from the contract")
require(win_stepper, rf"Delay = {timing['repeatDelayMs']}, Interval = {timing['repeatIntervalMs']}",
        "Windows capsule buttons do not repeat like macOS")
for label, key, step, caption in (("nozzle", "nozzle", steps["temperature"], True), ("bed", "bed", steps["temperature"], True),
                                   ("fan", "fan", steps["fan"], False), ("speed", "speed", steps["speed"], False)):
    low, high = ranges[key]
    require(mac_detail, rf"ControlStepperView\(range: {low}\.\.\.{high}, step: {step}, showsTargetCaption: {str(caption).lower()}",
            f"macOS {label} capsule range or step differs from the contract")
    require(win_detail, rf"new ControlStepper\({low}, {high}, {step}, {str(caption).lower()},",
            f"Windows {label} capsule range or step differs from the contract")
bambu_speed = detail_controls["bambuSpeed"]
speed_low, speed_high = bambu_speed["levels"]
require(mac_detail, rf"ControlStepperView\(range: {speed_low}\.\.\.{speed_high}, step: 1,",
        "macOS Bambu speed is not a speed-mode capsule")
require(win_detail, rf"new ControlStepper\({speed_low}, {speed_high}, 1, false,",
        "Windows Bambu speed is not a speed-mode capsule")
require("Sources/Gantry/App/PrinterStore.swift", rf'"command":"{bambu_speed["command"]}"',
        "macOS does not send the Bambu speed mode command")
require("windows/Gantry.Windows/Services/PrinterStore.cs", rf'command = "{bambu_speed["command"]}"',
        "Windows does not send the Bambu speed mode command")
require(mac_detail, rf"fan\.echoTolerance = {detail_controls['fanEchoTolerance']}\b",
        "macOS fan capsules do not accept Bambu's rounded echo")
require(win_detail, rf"EchoTolerance = {detail_controls['fanEchoTolerance']}\b",
        "Windows fan capsules do not accept Bambu's rounded echo")
require("Sources/Gantry/Services/MQTTClient.swift", r"BambuCommandReply\.parse\(payload\)",
        "macOS does not read the printer's replies to control commands")
require("windows/Gantry.Windows/Services/MqttClient.cs", r"BambuCommandReply\.Parse\(payload\)",
        "Windows does not read the printer's replies to control commands")
signing = detail_controls["commandSigning"]
signing_bit = int(signing["bit"], 16)
require("Sources/Gantry/Services/BambuStatusParser.swift", rf'report\["fun"\][\s\S]*?mask & 0x{signing_bit:_X}'.replace("0x2_0000000", "0x2000_0000"),
        "macOS does not read Bambu's command-signing bit")
require("windows/Gantry.Windows/Services/StatusParser.cs", rf'"fun"[\s\S]*?mask & 0x{signing_bit:X}UL',
        "Windows does not read Bambu's command-signing bit")
require(mac_detail, r"&& !signingBlocked", "macOS shows Bambu controls a signing printer would refuse")
require(win_detail, r"&& !_signingBlocked", "Windows shows Bambu controls a signing printer would refuse")
forbid(mac_detail, r"CompactControlSlider", "macOS brought back the loose plus/minus row under the tiles")
forbid(win_detail, r"TempChip\(", "Windows rebuilds temperature chips, which would drop a capsule mid-change")
require("windows/Gantry.Windows/Services/Storage.cs", rf'"{detail_controls["setting"]}"', "Windows is missing the printer-control setting")
require("windows/Gantry.Windows/Services/PrinterStore.cs", r"M104 S[\s\S]*?M140 S[\s\S]*?M106 P\{index\}[\s\S]*?M220 S",
        "Windows is missing the temperature, fan or speed commands")
require(mac_detail, r'sectionTitle\(AppSettings\.shared\.t\("CAMERA"\)\), NSView\(\), advancedButton', "macOS camera card lost Advanced…")
require(win_detail, r'new AdvancedWindow\(_store, _serial\)', "Windows has no way to open Advanced…")

# Spool accounting: a print is identified by its session, not the hour a FINISHED packet arrived.
for accounting_file, hour_bucket in (("Sources/Gantry/Spoolbase/FilamentConsumption.swift", r"/\s*3600"),
                                     ("windows/Gantry.Windows/Services/FilamentConsumption.cs", r"/\s*3600"),
                                     ("linux/gantry/consumption.py", r"//\s*3600")):
    require(accounting_file, r'"spoolbase-print-sessions"', "spool accounting does not keep print sessions")
    forbid(accounting_file, hour_bucket, "spool accounting identifies a print by the hour again")
# The slot a print came from: the active one, or a lone loaded roll, never the first present slot.
for slot_file, rule in (("Sources/Gantry/Spoolbase/FilamentConsumption.swift", r"active\.count == 1 \? active\[0\] : nil[\s\S]{0,80}?loaded\.count == 1"),
                        ("windows/Gantry.Windows/Services/SpoolAccounting.cs", r"active\.Count == 1 \? active\[0\] : null[\s\S]{0,160}?loaded\.Count == 1"),
                        ("linux/gantry/consumption.py", r"if len\(active\) == 1 else None[\s\S]{0,80}?len\(loaded\) == 1")):
    require(slot_file, rule, "spool accounting guesses the slot instead of taking the active one")
# The --render harness must work on a throwaway data folder, never the user's stores.
require("windows/Gantry.Windows/App.xaml.cs", r'"--render"[\s\S]{0,120}?AppDataRoot\.UseTemporaryFolder[\s\S]*?base\.OnStartup',
        "Windows --render does not switch to a throwaway data folder before startup")
for data_file in ("windows/Gantry.Windows/Services/Storage.cs", "windows/Gantry.Windows/Services/PhysicalSpoolStore.cs",
                  "windows/Gantry.Windows/Services/FilamentInventory.cs"):
    forbid(data_file, r"SpecialFolder\.ApplicationData", "a Windows store bypasses AppDataRoot")

# Data files are written in one step with a last good copy, never straight into place.
for data_file, in_place in (("windows/Gantry.Windows/Services/Storage.cs", r"File\.Create\(FilePath\)"),
                            ("windows/Gantry.Windows/Services/PhysicalSpoolStore.cs", r"(?<!Atomic)File\.WriteAllText\("),
                            ("windows/Gantry.Windows/Services/FilamentInventory.cs", r"(?<!Atomic)File\.WriteAllText\("),
                            ("linux/gantry/physicalspool.py", r"\.write_text\("),
                            ("linux/gantry/filamentstore.py", r"\.write_text\(")):
    forbid(data_file, in_place, "a data file is written in place again, so a crash can leave it empty")
# A replaced script's exit clears only its own entry.
require("Sources/Gantry/Services/AutomationStore.swift", r"ObjectIdentifier\(current\) == identity",
        "macOS: a replaced script's exit can unregister the run that replaced it")
require("windows/Gantry.Windows/Services/ScriptRunner.cs", r"ReferenceEquals\(current, process\)",
        "Windows: a replaced script's exit can unregister the run that replaced it")
# Windows FTPS: a whole transfer has a deadline and always closes.
require("windows/Gantry.Windows/Services/BambuFileClient.cs",
        r"TransferTimeout = TimeSpan\.FromSeconds\(60\)[\s\S]*?finally\s*\{\s*Close\(\);\s*gate\.Release\(\);",
        "Windows FTPS transfers have no deadline or can leave the connection open")
# macOS 3MF cache: expired files leave on every touch and the total is capped.
require("Sources/Gantry/Services/BambuFileClient.swift", r"struct FTPFileCache[\s\S]*?purgeExpired[\s\S]*?byteLimit",
        "macOS 3MF cache keeps expired files or has no size cap")

# GNU/Linux printer control follows the same contract as macOS and Windows.
linux_control = "linux/gantry/control.py"
require(linux_control, rf"CAPSULE_HEIGHT = {capsule['height']}\n[\s\S]*?BUTTON_WIDTH = {capsule['buttonWidth']}\n[\s\S]*?SETTLE_SECONDS = {timing['settleSeconds']}\n"
        rf"[\s\S]*?ECHO_WINDOW_SECONDS = {timing['echoWindowSeconds']}\n[\s\S]*?REPEAT_DELAY_MS = {timing['repeatDelayMs']}\n"
        rf"[\s\S]*?REPEAT_INTERVAL_MS = {timing['repeatIntervalMs']}\n[\s\S]*?FAN_ECHO_TOLERANCE = {detail_controls['fanEchoTolerance']}\n",
        "GNU/Linux setpoint capsule geometry or timing differs from the contract")
for linux_label, low, high, step in (("nozzle", *ranges["nozzle"], steps["temperature"]), ("bed", *ranges["bed"], steps["temperature"]),
                                     ("fan", *ranges["fan"], steps["fan"]), ("speed", *ranges["speed"], steps["speed"]),
                                     ("Bambu speed mode", speed_low, speed_high, 1)):
    require("linux/gantry/details.py", rf"StepperModel\({low}, {high}, {step}\b", f"GNU/Linux {linux_label} capsule range or step differs from the contract")
require(linux_control, rf'"command": "{bambu_speed["command"]}"', "GNU/Linux does not send the Bambu speed mode command")
require("linux/gantry/core.py", r'"fun"[\s\S]*?0x20000000', "GNU/Linux does not read Bambu's command-signing bit")
require("linux/gantry/mqtt.py", r"parse_command_reply\(payload\)", "GNU/Linux does not read the printer's replies to control commands")
require("linux/gantry/details.py", r"return wanted and not blocked, blocked", "GNU/Linux shows Bambu controls a signing printer would refuse")
require("linux/gantry/app.py", r"M104 S[\s\S]*?M140 S[\s\S]*?M106 P\{index\}[\s\S]*?M220 S", "GNU/Linux is missing the temperature, fan or speed commands")
# One list of 3MF paths on all three platforms, held by a shared fixture.
for paths_file, marker in (("Sources/Gantry/Services/BambuFileClient.swift", r"static func candidatePaths"),
                           ("windows/Gantry.Windows/Services/BambuFileClient.cs", r"BambuPaths\.CandidatePaths\(fileName\)"),
                           ("linux/gantry/consumption.py", r"candidates = candidate_paths\(")):
    require(paths_file, marker, "3MF download does not use the shared candidate paths")
# A colour shared by several rolls is settled by material or not charged at all.
for colour_file, marker in (("Sources/Gantry/Spoolbase/FilamentConsumption.swift", r"matches\.count == 1 \? matches\[0\]\.location : nil"),
                            ("windows/Gantry.Windows/Services/SpoolAccounting.cs", r"matches\.Count == 1 \? matches\[0\] : null"),
                            ("linux/gantry/consumption.py", r"if len\(matches\) == 1 else None")):
    require(colour_file, marker, "spool accounting charges the first roll of a shared colour")
# P1/A1 cameras: JPEG on port 6000 when RTSPS gives no picture.
require("linux/gantry/camera.py", r"if not self\._run_bambu\(stop\) and not stop\.is_set\(\):\s*self\._run_bambu_jpeg\(stop\)",
        "GNU/Linux has no JPEG fallback for P1/A1 cameras")
# Scripts on Linux honour their shebang and can be stopped.
require("linux/gantry/automation.py", r'startswith\("#!"\)[\s\S]*?def stop_script', "GNU/Linux scripts ignore their interpreter or cannot be stopped")
# Windows automations save as they change.
forbid("windows/Gantry.Windows/UI/AutomationsWindow.cs", r'T\("Save"\)', "Windows automations need a Save button again")

if ERRORS:
    print("UI parity check failed:", file=sys.stderr)
    for error in ERRORS:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)

print(f"UI parity OK — macOS/Windows/Linux match contract {CONTRACT['meta']['version']}")
