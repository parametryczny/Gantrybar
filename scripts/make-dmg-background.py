#!/usr/bin/env python3
"""Generate the .dmg window background: a staggered grid ("siatka") of faint Gantry "G" marks as a
watermark on a warm off-white field. Renders @1x and @2x and combines them into a HiDPI TIFF so the
install window looks crisp on Retina.

Run from the repo root: python3 scripts/make-dmg-background.py
Requires Pillow. Output: Resources/dmg-background.tiff (committed; build-dmg.sh just copies it).
"""
import subprocess
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "branding" / "gantry-g-icon.png"
OUT_TIFF = ROOT / "Resources" / "dmg-background.tiff"

# Window content area (points). Must match the Finder window bounds in build-dmg.sh.
WIDTH, HEIGHT = 500, 340
BG = (245, 242, 234)          # warm off-white, matching the logo's cream field
TILE_PT = 46                  # watermark glyph size in points
STEP_PT = 66                  # grid spacing in points
OPACITY = 26                  # 0…255 — how strong the watermark reads (subtle)


def glyph_mask(scale: int) -> Image.Image:
    """The black 'G' turned into a soft alpha mask, sized for the given scale (1 or 2)."""
    src = Image.open(SOURCE).convert("L")
    # Tight crop around the glyph so the surrounding cream doesn't tile as a block.
    bbox = src.point(lambda p: 255 if p < 160 else 0).getbbox()
    if bbox:
        src = src.crop(bbox)
    # Darkness → alpha: near-black glyph becomes opaque, any leftover light pixels vanish.
    mask = src.point(lambda p: max(0, min(255, int((205 - p) * 1.6))))
    size = TILE_PT * scale
    return mask.resize((size, size), Image.LANCZOS)


def render(scale: int) -> Image.Image:
    w, h = WIDTH * scale, HEIGHT * scale
    canvas = Image.new("RGB", (w, h), BG)
    mask = glyph_mask(scale)
    ink = Image.new("RGB", mask.size, (34, 34, 34))
    faint = mask.point(lambda p: int(p * OPACITY / 255))
    step = STEP_PT * scale
    tile = TILE_PT * scale
    row = 0
    y = -tile // 2
    while y < h:
        offset = (step // 2) if row % 2 else 0
        x = -tile // 2 + offset
        while x < w:
            canvas.paste(ink, (x, y), faint)
            x += step
        y += step
        row += 1
    return canvas


def main() -> None:
    one = ROOT / "Resources" / "_dmg-bg@1x.png"
    two = ROOT / "Resources" / "_dmg-bg@2x.png"
    render(1).save(one)
    render(2).save(two)
    # Combine into a single multi-resolution TIFF so Finder shows it crisp on Retina.
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT_TIFF)], check=True)
    one.unlink(); two.unlink()
    print(f"wrote {OUT_TIFF}")


if __name__ == "__main__":
    main()
