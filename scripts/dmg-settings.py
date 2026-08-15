"""dmgbuild settings for the Gantry installer — a drag-to-install window with the Gantry "G"
watermark background, laid out headlessly (no Finder/AppleScript needed). Run from the repo root:

    dmgbuild -s scripts/dmg-settings.py "Gantry" dist/Gantry-macOS.dmg

The .app path can be overridden with DMG_APP; defaults to dist/Gantry.app.
"""
import os.path

app = os.environ.get("DMG_APP", "dist/Gantry.app")
appname = os.path.basename(app)   # "Gantry.app"

# --- Disk image ---
format = "UDZO"                   # compressed, read-only
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = "Resources/AppIcon.icns"   # branded volume icon

# --- Window & icons ---
background = "Resources/dmg-background.tiff"
window_rect = ((200, 120), (500, 340))  # (x, y), (width, height) — matches the background
default_view = "icon-view"
icon_size = 96
text_size = 12
icon_locations = {
    appname: (130, 170),
    "Applications": (370, 170),
}
