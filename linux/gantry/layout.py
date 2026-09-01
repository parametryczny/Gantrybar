from __future__ import annotations

"""Pure dashboard geometry shared by the GTK view and tests.

These rules are a direct port of PrinterDashboardViewController.refreshDashboard(),
cardNeedsWideSpan() and addExpandedRows().  Keeping them free of GTK makes the platform contract
testable on macOS and in headless packaging jobs.
"""

from dataclasses import dataclass

from .core import Telemetry


@dataclass(frozen=True, slots=True)
class Placement:
    serial: str
    row: int
    column: int
    span: int


def panel_width(compact: bool, columns: int) -> int:
    if compact:
        return 512
    return 380 if max(1, min(2, columns)) == 1 else 563


def needs_wide(telemetry: Telemetry) -> bool:
    dual_nozzle = any(nozzle.position == "right" for nozzle in telemetry.nozzles)
    ams_count = sum(1 for group in telemetry.filament_groups if not group.external)
    return dual_nozzle or ams_count >= 2


def place_cards(serials: list[str], telemetry: dict[str, Telemetry], columns: int,
                compact: bool = False) -> list[Placement]:
    columns = 1 if compact else max(1, min(2, columns))
    result: list[Placement] = []
    row = column = 0
    for index, serial in enumerate(serials):
        span = min(columns, 2 if not compact and needs_wide(telemetry.get(serial, Telemetry())) else 1)
        if column + span > columns:
            row += 1
            column = 0
        if not compact and index == len(serials) - 1 and column == 0:
            span = columns
        result.append(Placement(serial, row, column, span))
        column += span
        if column == columns:
            row += 1
            column = 0
    return result
