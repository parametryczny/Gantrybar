"""Which display the edge dock lives on and where on it.

Pure geometry, free of GTK, so every rule is covered by tests on simulated desktops. Mirrors the macOS
and Windows EdgeDockPlacement (contract edgeDock.placement). Rectangles are (x, y, width, height) in
GDK application pixels, y down.
"""
from __future__ import annotations

from dataclasses import dataclass

from . import i18n

ROW_MARGIN = 0.2
DISPLAY_TOLERANCE = 8
INNER_EDGE_DWELL_MS = 250
DISPLAY_CHANGE_DEBOUNCE_MS = 600
ROWS = ("top", "middle", "bottom")

Rect = tuple[float, float, float, float]


@dataclass(frozen=True)
class EdgeDockDisplay:
    """One connected display. `frame` is the whole display, which the strip touches on its side;
    `workarea` leaves out panels and bounds the strip vertically."""
    id: str
    name: str
    pixel_width: int
    pixel_height: int
    frame: Rect
    workarea: Rect
    is_primary: bool


def _same_size(a: Rect, b: Rect) -> bool:
    return abs(a[2] - b[2]) <= DISPLAY_TOLERANCE and abs(a[3] - b[3]) <= DISPLAY_TOLERANCE


def _same_frame(a: Rect, b: Rect) -> bool:
    return abs(a[0] - b[0]) <= DISPLAY_TOLERANCE and abs(a[1] - b[1]) <= DISPLAY_TOLERANCE and _same_size(a, b)


def resolve(displays: list[EdgeDockDisplay], saved_id: str,
            saved_frame: Rect | None) -> tuple[EdgeDockDisplay, bool] | None:
    """The display the strip belongs on, and whether it is the one the user chose rather than the fallback.
    A missing display never clears the choice: the strip waits on the main display and goes back once its
    own display returns.

    1. The saved id with the saved size. 2. The saved frame within DISPLAY_TOLERANCE, for an id that
    changed; twins with the same frame resolve to the main display. 3. The saved id alone, for a new
    resolution. 4. The main display (the first one when the compositor names none, as Wayland may)."""
    if not displays:
        return None
    primary = next((d for d in displays if d.is_primary), displays[0])
    if not saved_id:
        return primary, False
    by_id = next((d for d in displays if d.id == saved_id), None)
    if saved_frame is not None:
        if by_id is not None and _same_size(by_id.frame, saved_frame):
            return by_id, True
        near = [d for d in displays if _same_frame(d.frame, saved_frame)]
        twin = next((d for d in near if d.is_primary), near[0] if near else None)
        if twin is not None:
            return twin, True
    if by_id is not None:
        return by_id, True
    return primary, False


def place(frame: Rect, workarea: Rect, left: bool, row: str, width: float, height: float) -> tuple[float, float]:
    """Top-left corner for a strip of this size. Flush against the display's side; placed in the work area
    and kept inside it, so an unfolded strip taller than the room below a top anchor slides up instead of
    running off the screen."""
    x = frame[0] if left else frame[0] + frame[2] - width
    wx, wy, _ww, wh = workarea
    margin = wh * ROW_MARGIN
    if row == "top":
        y = wy + margin
    elif row == "bottom":
        y = wy + wh - margin - height
    else:
        y = wy + (wh - height) / 2
    y = wy if height >= wh else min(max(y, wy), wy + wh - height)
    return x, y


def is_inner_edge(display: EdgeDockDisplay, left: bool, displays: list[EdgeDockDisplay]) -> bool:
    """True when another display continues past this edge. There the pointer crosses the strip on its way
    to the neighbour, so the strip must not unfold on a mere pass."""
    x, y, width, height = display.frame
    for other in displays:
        if other.id == display.id and other.frame == display.frame:
            continue
        ox, oy, owidth, oheight = other.frame
        overlaps = oy < y + height and oy + oheight > y
        touches = abs(ox + owidth - x) <= 2 if left else abs(ox - (x + width)) <= 2
        if overlaps and touches:
            return True
    return False


def format_frame(frame: Rect) -> str:
    return ",".join(str(int(round(value))) for value in frame)


def parse_frame(text: str) -> Rect | None:
    parts = str(text or "").split(",")
    if len(parts) != 4:
        return None
    try:
        values = tuple(float(part.strip()) for part in parts)
    except ValueError:
        return None
    return values if values[2] > 0 and values[3] > 0 else None  # type: ignore[return-value]


def display_title(display: EdgeDockDisplay) -> str:
    title = f"{display.name} · {display.pixel_width}×{display.pixel_height}"
    return i18n.t("{0} (main)").format(title) if display.is_primary else title


def position_title(left: bool, row: str) -> str:
    place_text = {"top": i18n.t("at the top"), "bottom": i18n.t("at the bottom")}.get(row, i18n.t("in the middle"))
    return f"{i18n.t('Left edge' if left else 'Right edge')}, {place_text}"


def choices(displays: list[EdgeDockDisplay], saved_id: str, saved_name: str) -> list[tuple[str, str, bool]]:
    """The monitor list for Settings and the tray: the main display first, every connected display, and the
    chosen one kept on the list while it is unplugged, so the choice stays visible."""
    result = [("", i18n.t("Main display"), not saved_id)]
    result.extend((display.id, display_title(display), display.id == saved_id) for display in displays)
    if saved_id and all(display.id != saved_id for display in displays):
        result.append((saved_id, i18n.t("{0} (disconnected)").format(saved_name or saved_id), True))
    return result
