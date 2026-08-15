#!/bin/zsh
# Builds a classic drag-to-install .dmg: a Finder window showing Gantry.app next to an
# "Applications" shortcut, so the user just drags the app across to install — like most Mac apps.
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

STORAGE_MODE="${1:-local}"

# 1) Build + sign the .app (reuses the existing signing identity).
./scripts/build-app.sh "$STORAGE_MODE"

APP_PATH="dist/Gantry.app"
[[ -d "$APP_PATH" ]] || { echo "Brak $APP_PATH" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 0.7.0)"
VOL_NAME="Gantry"
DMG_PATH="dist/Gantry-${VERSION}-macOS.dmg"

# Prefer dmgbuild: it bakes in the watermark background + icon layout headlessly (writes the
# .DS_Store directly), so it works on CI and over SSH — no Finder/AppleScript/GUI session needed.
# Install with: pip3 install dmgbuild. Falls back to the Finder flow below when it's unavailable.
if python3 -c "import dmgbuild" >/dev/null 2>&1; then
    rm -f "$DMG_PATH"
    DMG_APP="$APP_PATH" python3 -c "import dmgbuild; dmgbuild.build_dmg('$DMG_PATH', '$VOL_NAME', settings_file='scripts/dmg-settings.py')"
    echo "Gotowe: $PROJECT_DIR/$DMG_PATH"
    exit 0
fi
echo "  (dmgbuild niedostępny — buduję przez Finder/AppleScript; zainstaluj: pip3 install dmgbuild)"

# 2) Stage the disk contents: the app + a symlink to /Applications.
STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGE/Gantry.app"
ln -s /Applications "$STAGE/Applications"
# Give the volume Gantry's own icon so the mounted disk looks branded (best-effort).
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    SetFile -a C "$STAGE" 2>/dev/null || true
fi
# Watermark background: a staggered grid of faint Gantry "G" marks (HiDPI TIFF). Regenerate with
# scripts/make-dmg-background.py. Optional — the DMG still works if it's missing.
DMG_BG=""
if [[ -f "Resources/dmg-background.tiff" ]]; then
    mkdir -p "$STAGE/.background"
    cp "Resources/dmg-background.tiff" "$STAGE/.background/background.tiff"
    DMG_BG="background.tiff"
fi

# 3) Build a read/write DMG so Finder can lay the window out, then style + compress it.
rm -f "$DMG_PATH" "dist/.gantry-rw.dmg"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -ov "dist/.gantry-rw.dmg" >/dev/null
rm -rf "$STAGE"

MOUNT_DIR="$(mktemp -d)"
hdiutil attach "dist/.gantry-rw.dmg" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen >/dev/null

# Best-effort Finder window layout (icon positions + drag arrow). Needs a Finder GUI session and
# Automation permission; if that isn't available the DMG still works, just without the pretty layout.
if [[ -n "$DMG_BG" ]]; then
    BG_LINE="set background picture of theViewOptions to file \".background:$DMG_BG\""
else
    BG_LINE=""
fi
osascript <<APPLESCRIPT 2>/dev/null || echo "  (pomijam układ okna Finder — DMG i tak działa)"
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 700, 460}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        $BG_LINE
        set position of item "Gantry.app" of container window to {130, 170}
        set position of item "Applications" of container window to {370, 170}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" >/dev/null || hdiutil detach "$MOUNT_DIR" -force >/dev/null
rm -rf "$MOUNT_DIR"

# 4) Convert to a compressed, read-only DMG for distribution.
hdiutil convert "dist/.gantry-rw.dmg" -format UDZO -o "$DMG_PATH" -ov >/dev/null
rm -f "dist/.gantry-rw.dmg"

echo "Gotowe: $PROJECT_DIR/$DMG_PATH"
