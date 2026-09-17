"""Layout of the open edge dock: one column of printers, each a picture with its caption under it.

The same arithmetic as macOS (EdgeDockView.plan) and Windows (EdgeDockWindow.Plan), contract
edgeDock.captions. Every printer is one block: its picture, a 5 pt gap, then a caption with the name on
the leading side and the percentage, time and ring at the end; nothing is drawn over a picture. A
printer without a picture is its caption plus one note line saying why. Neighbours are separated by a
hairline with more room around it than between a picture and its caption.

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
CAPTION_GAP = 5.0
CAPTION_MIN_HEIGHT = 28.0
CAPTION_PAD_Y = 4.0
CAPTION_INNER_GAP = 5.0
RING_SPAN = RING + CAPTION_INNER_GAP
WRAPPED_LINE_GAP = 1.0
STATUS_ROW = 16.0
STATUS_ICON = 12.0
PRINTER_GAP = 14.0
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
        wraps = measure.name_width(caption.name) + CAPTION_INNER_GAP + measure.value_width(caption.value) > text_width
        name_height = measure.name_height(caption.name, text_width) if wraps else measure.name_line
        text_height = (name_height + WRAPPED_LINE_GAP + measure.value_line if wraps
                       else max(measure.name_line, measure.value_line))
        caption_height = max(CAPTION_MIN_HEIGHT, text_height + CAPTION_PAD_Y * 2)
        picture_band = picture_height + CAPTION_GAP if shows_picture else 0.0
        block = picture_band + caption_height + (STATUS_ROW if note else 0.0)
        rows.append(Row(block_top=offset, block_height=block,
                        picture_width=picture_width if shows_picture else 0.0,
                        picture_height=picture_height if shows_picture else 0.0,
                        caption_top=offset + picture_band, caption_height=caption_height,
                        wraps=wraps, name_height=name_height, note=note))
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

