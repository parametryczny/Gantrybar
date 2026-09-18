"""Layout of the open edge dock: one column of printers, a picture with its caption laid over its bottom.

The same arithmetic as macOS (EdgeDockView.plan) and Windows (EdgeDockWindow.Plan), contract
edgeDock.captions. A printer with a picture is just the picture, with the name on the leading side and the
percentage, time and ring at the end drawn over its bottom edge on a soft dark fade, so a camera costs no
more height than its image. A printer without a picture is its caption plus one note line saying why.
Neighbours are separated by a hairline.

When the column is taller than the display, it gives way in a fixed order: smaller pictures, pictures
replaced by a note, the notes dropped, and last the strip cut at the display's height. The order of the
printers never changes. No GTK here, so the rules are testable without a display.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

RING = 14.0
INSET_X = 10.0
PICTURE_RADIUS = 8.0
CAPTION_MIN_HEIGHT = 28.0
CAPTION_PAD_Y = 4.0
CAPTION_INNER_GAP = 5.0
RING_SPAN = RING + CAPTION_INNER_GAP
WRAPPED_LINE_GAP = 1.0
STATUS_ROW = 16.0
STATUS_ICON = 12.0
PRINTER_GAP = 8.0
#: The fade under a caption laid over a picture, and the caption's side padding inside the picture.
OVERLAY_SHADE = 44.0
OVERLAY_SHADE_ALPHA = 0.72
OVERLAY_PAD_X = 8.0
SEPARATOR_ALPHA = 0.12
NAME_SIZE = 13.0
VALUE_SIZE = 11.0
STATUS_SIZE = 11.0
#: A long name gives the strip at most this much of its width before it wraps instead.
NAME_WIDTH_CAP = 120.0
#: Pictures shrink to no less than this share of the column before they give way to a note.
MINIMUM_PICTURE_SHARE = 0.55
PICTURE_SHARE_STEP = 0.02
#: Room kept free above and below an open strip on its display.
SCREEN_MARGIN = 16.0
CAMERA_MIN_STRIP_WIDTH = 236.0
CAMERA_MAX_STRIP_WIDTH = 300.0
PLAIN_MIN_STRIP_WIDTH = 180.0
PLAIN_MAX_STRIP_WIDTH = 260.0
#: The camera glyph in a 12x12 design box, y down: body (x, y, w, h), lens, and the strike when absent.
CAMERA_GLYPH_BODY = (1.0, 3.0, 7.5, 6.0)
CAMERA_GLYPH_LENS = ((8.5, 5.0), (11.0, 3.5), (11.0, 8.5), (8.5, 7.0))
CAMERA_GLYPH_STRIKE = ((1.0, 1.5), (11.0, 10.5))

#: The gear on the strip's settings button, in a box `size` wide: eight teeth, the root circle at 72 % of
#: the tip, each tooth 34 % of its period wide at the tip and 60 % at the root, and a hole of 32 %. Drawn,
#: not a font glyph, so it is the same shape on macOS, Windows and GNU/Linux (contract edgeDock.settingsButton).
GEAR_TEETH = 8
GEAR_ROOT = 0.72
GEAR_TIP_SPAN = 0.17
GEAR_ROOT_SPAN = 0.30
GEAR_HOLE = 0.32

LIVE, PREVIEW_OFF, NO_CAMERA, HIDDEN = "live", "preview_off", "no_camera", "hidden"
#: Catalogue keys for the note under a caption without a picture.
NOTES = {LIVE: "Not enough room for the preview", PREVIEW_OFF: "Preview off", NO_CAMERA: "No camera"}


class Measure(Protocol):
    name_line: float
    value_line: float

    def name_width(self, text: str) -> float: ...
    def value_width(self, text: str) -> float: ...
    def name_height(self, text: str, width: float) -> float: ...


@dataclass(frozen=True)
class Caption:
    name: str
    value: str
    camera: str          # LIVE, PREVIEW_OFF, NO_CAMERA or HIDDEN
    has_picture: bool    # a stream is attached; LIVE without one is treated as having no room


@dataclass(frozen=True)
class Row:
    block_top: float
    block_height: float
    picture_width: float     # 0 when no picture is shown
    picture_height: float
    caption_top: float
    caption_height: float
    wraps: bool              # the name on its own lines, the metrics under it
    overlay: bool            # the caption is laid over the bottom of the picture
    name_height: float
    note: str | None         # catalogue key of the note line, or None


@dataclass(frozen=True)
class Plan:
    rows: tuple[Row, ...]
    height: float


def separator_step() -> float:
    """Distance from one block's bottom to the next block's top: gap, hairline, gap."""
    return PRINTER_GAP * 2 + 1


def plan(captions: list[Caption], strip_width: float, measure: Measure, picture_share: float = 1.0,
         pictures: bool = True, notes: bool = True) -> Plan:
    content = max(0.0, strip_width - INSET_X * 2)
    picture_width = round(content * picture_share)
    picture_height = round(picture_width * 9 / 16)
    text_width = max(0.0, content - RING_SPAN)
    rows: list[Row] = []
    offset = 0.0
    for index, caption in enumerate(captions):
        shows_picture = pictures and caption.camera == LIVE and caption.has_picture and content > 0
        note = NOTES.get(caption.camera) if notes and not shows_picture else None
        if shows_picture:
            # Over a picture the caption is one line: a long name is cut with an ellipsis instead.
            rows.append(Row(block_top=offset, block_height=picture_height, picture_width=picture_width,
                            picture_height=picture_height, caption_top=offset + picture_height - CAPTION_MIN_HEIGHT,
                            caption_height=CAPTION_MIN_HEIGHT, wraps=False, overlay=True,
                            name_height=measure.name_line, note=None))
            offset += picture_height
            if index < len(captions) - 1:
                offset += separator_step()
            continue
        wraps = measure.name_width(caption.name) + CAPTION_INNER_GAP + measure.value_width(caption.value) > text_width
        name_height = measure.name_height(caption.name, text_width) if wraps else measure.name_line
        text_height = (name_height + WRAPPED_LINE_GAP + measure.value_line if wraps
                       else max(measure.name_line, measure.value_line))
        caption_height = max(CAPTION_MIN_HEIGHT, text_height + CAPTION_PAD_Y * 2)
        block = caption_height + (STATUS_ROW if note else 0.0)
        rows.append(Row(block_top=offset, block_height=block, picture_width=0.0, picture_height=0.0,
                        caption_top=offset, caption_height=caption_height, wraps=wraps, overlay=False,
                        name_height=name_height, note=note))
        offset += block
        if index < len(captions) - 1:
            offset += separator_step()
    return Plan(tuple(rows), offset)


def fitted_plan(captions: list[Caption], strip_width: float, measure: Measure, limit: float) -> Plan:
    """The column at full size when it fits `limit`, otherwise the fallbacks in the module docstring."""
    limit = max(CAPTION_MIN_HEIGHT, limit)
    full = plan(captions, strip_width, measure)
    if full.height <= limit:
        return full
    picture_total = sum(row.picture_height for row in full.rows)
    if picture_total > 0:
        # Pictures are whole points, so the first estimate can land a point or two over; step down.
        share = 1 - (full.height - limit) / picture_total
        while share >= MINIMUM_PICTURE_SHARE:
            smaller = plan(captions, strip_width, measure, picture_share=share)
            if smaller.height <= limit:
                return smaller
            share -= PICTURE_SHARE_STEP
    no_pictures = plan(captions, strip_width, measure, pictures=False)
    if no_pictures.height <= limit:
        return no_pictures
    bare = plan(captions, strip_width, measure, pictures=False, notes=False)
    return Plan(bare.rows, min(bare.height, limit))


def strip_width(captions: list[Caption], measure: Measure) -> float:
    """Sized by the widest caption, but a long name wraps instead of widening the strip."""
    widest = 0.0
    for caption in captions:
        widest = max(widest, min(measure.name_width(caption.name), NAME_WIDTH_CAP) + measure.value_width(caption.value))
    content = INSET_X * 2 + CAPTION_INNER_GAP * 2 + RING + widest
    pictures = any(caption.camera == LIVE and caption.has_picture for caption in captions)
    minimum = CAMERA_MIN_STRIP_WIDTH if pictures else PLAIN_MIN_STRIP_WIDTH
    maximum = CAMERA_MAX_STRIP_WIDTH if pictures else PLAIN_MAX_STRIP_WIDTH
    return min(max(content, minimum), maximum)



def gear_outline(cx: float, cy: float, size: float, angle_degrees: float = 0.0) -> list[tuple[float, float]]:
    """The gear's outer edge as a closed polygon around (cx, cy), turned clockwise by `angle_degrees`."""
    import math
    tip, root = size / 2, size / 2 * GEAR_ROOT
    period = 2 * math.pi / GEAR_TEETH
    turn = math.radians(angle_degrees)
    points: list[tuple[float, float]] = []
    for tooth in range(GEAR_TEETH):
        middle = tooth * period + turn
        for radius, offset in ((root, -GEAR_ROOT_SPAN), (tip, -GEAR_TIP_SPAN), (tip, GEAR_TIP_SPAN), (root, GEAR_ROOT_SPAN)):
            angle = middle + offset * period
            points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


def finish_value(progress: int, minutes: int, finish_clock: str) -> str:
    """How far along, how long is left and the clock time it ends, as on the fleet cards: "75% · 1h 16m · 15:42"."""
    left = f"{minutes}m" if minutes < 60 else f"{minutes // 60}h {minutes % 60}m"
    return f"{progress}% · {left} · {finish_clock}"
