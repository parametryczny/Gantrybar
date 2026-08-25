#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "renders"
OUT.mkdir(parents=True, exist_ok=True)


def font(size: int):
    return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)


def replace(image: Image.Image, box, label: str, size: int, color, sample_xy):
    draw = ImageDraw.Draw(image)
    bg = image.getpixel(sample_xy)
    draw.rectangle(box, fill=bg)
    draw.text((box[0], box[1] - 1), label, font=font(size), fill=color)


mac = Image.open("/Users/kamilgrzegorczyk/Downloads/mac.png").convert("RGB")
# Coordinates are in the original 3024×1964 screenshot. Each replacement stays
# inside the job-name row and samples the untouched card background beside it.
mac_jobs = [
    ((1963, 293, 2250, 329), "demo_1", (2260, 307)),
    ((2487, 293, 2817, 329), "demo_2", (2825, 307)),
    ((1963, 661, 2290, 697), "demo_3", (2300, 675)),
    ((2487, 661, 2817, 697), "demo_4", (2825, 675)),
    ((1963, 1027, 2250, 1063), "demo_5", (2260, 1041)),
]
for box, label, sample in mac_jobs:
    replace(mac, box, label, 22, (135, 142, 135), sample)
mac.save(OUT / "gantry-macos-anonymized.png", optimize=True)


win = Image.open("/Users/kamilgrzegorczyk/Downloads/win.png").convert("RGB")
win_jobs = [
    ((1280, 642, 1450, 657), "demo_1", (1458, 648)),
    ((1582, 642, 1738, 657), "demo_2", (1745, 648)),
    ((1280, 854, 1450, 869), "demo_3", (1458, 860)),
    ((1582, 854, 1740, 869), "demo_4", (1748, 860)),
]
for box, label, sample in win_jobs:
    replace(win, box, label, 10, (142, 147, 152), sample)
win.save(OUT / "gantry-windows-anonymized.png", optimize=True)
