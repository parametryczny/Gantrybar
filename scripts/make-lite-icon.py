#!/usr/bin/env python3
"""Builds Resources/AppIcon-LITE.icns from the shared Gantry icon.

The LITE mark is the same G on the same cream ground, tucked up a little to make room for a
letterspaced LITE underneath — so the two apps are told apart at a glance in the Dock without
inventing a second brand. Run it after the base icon changes:

    python3 scripts/make-lite-icon.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BASE_ICNS = ROOT / "Resources" / "AppIcon.icns"
OUT_ICNS = ROOT / "Resources" / "AppIcon-LITE.icns"
FONT = Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf")

SIZE = 1024
MARK_SCALE = 0.84          # how much of the canvas the original artwork keeps
MARK_SHIFT = -0.055        # fraction of the canvas the mark moves up
LABEL = "LITE"
LABEL_SIZE = 132
LABEL_TRACKING = 34        # extra pixels between glyphs
LABEL_BASELINE = 0.775     # fraction of the canvas where the label's top sits
# The icns sizes macOS actually asks for, as (pixel size, iconset file name).
ICONSET = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]


def base_image() -> Image.Image:
    """The 1024 px master out of the .icns, via sips (Pillow cannot read icns reliably)."""
    png = ROOT / "Resources" / ".appicon-master.png"
    subprocess.run(["sips", "-s", "format", "png", "--out", str(png), str(BASE_ICNS)],
                   check=True, capture_output=True)
    image = Image.open(png).convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)
    png.unlink(missing_ok=True)
    return image


def draw_tracked_text(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont,
                      top: int, fill: tuple[int, int, int, int], tracking: int) -> None:
    """Pillow has no letterspacing, so the label is drawn glyph by glyph, centred as a whole."""
    widths = [draw.textlength(char, font=font) for char in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = (SIZE - total) / 2
    for char, width in zip(text, widths):
        draw.text((x, top), char, font=font, fill=fill)
        x += width + tracking


def main() -> int:
    if not BASE_ICNS.exists():
        print(f"Brak {BASE_ICNS}", file=sys.stderr)
        return 1
    if not FONT.exists():
        print(f"Brak fontu {FONT}", file=sys.stderr)
        return 1

    base = base_image()
    # The ground is a flat colour, so scaling the whole artwork and re-seating it on a canvas of that
    # same colour is indistinguishable from scaling the G alone. The ink is taken as the artwork's
    # darkest pixel rather than a fixed spot — the middle of the mark is a cut-out, not the letter.
    ground = base.getpixel((8, 8))
    step = SIZE // 64
    samples = [base.getpixel((x, y)) for x in range(0, SIZE, step) for y in range(0, SIZE, step)]
    ink = min(samples, key=lambda px: px[0] + px[1] + px[2])

    canvas = Image.new("RGBA", (SIZE, SIZE), ground)
    mark_size = int(SIZE * MARK_SCALE)
    mark = base.resize((mark_size, mark_size), Image.LANCZOS)
    offset = ((SIZE - mark_size) // 2, int((SIZE - mark_size) // 2 + SIZE * MARK_SHIFT))
    canvas.paste(mark, offset, mark)

    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype(str(FONT), LABEL_SIZE)
    draw_tracked_text(draw, LABEL, font, int(SIZE * LABEL_BASELINE), ink, LABEL_TRACKING)

    iconset = ROOT / "Resources" / "AppIcon-LITE.iconset"
    if iconset.exists():
        for stale in iconset.iterdir():
            stale.unlink()
    iconset.mkdir(exist_ok=True)
    for size, name in ICONSET:
        canvas.resize((size, size), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)], check=True)
    for stale in iconset.iterdir():
        stale.unlink()
    iconset.rmdir()
    print(f"Gotowe: {OUT_ICNS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
