#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="/private/tmp/bambubar-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/bambubar-swift-cache"

STORAGE_MODE="${1:-local}"
case "$STORAGE_MODE" in
    local)
        # Default build. Keeps the stable bundle id (so the Local Network grant persists) but
        # stores printer access codes in the Keychain instead of plaintext UserDefaults.
        APP_NAME="Gantry"
        BUNDLE_ID="pl.gantry.app"
        SWIFT_FLAGS=(-Xswiftc -DKEYCHAIN_STORAGE)
        ;;
    keychain)
        APP_NAME="Gantry Keychain"
        BUNDLE_ID="pl.gantry.app.keychain"
        SWIFT_FLAGS=(-Xswiftc -DKEYCHAIN_STORAGE)
        ;;
    *)
        echo "Użycie: $0 [local|keychain]" >&2
        exit 2
        ;;
esac

# Build a universal (arm64 + x86_64) binary so the app runs on both Apple Silicon and Intel Macs.
# Set GANTRY_ARCHS="arm64" to build a faster native-only slice for local iteration.
GANTRY_ARCHS="${GANTRY_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $GANTRY_ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
BUILD_ARGS=(--disable-sandbox "${ARCH_FLAGS[@]}" "${SWIFT_FLAGS[@]}")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
TEMP_ROOT="$(mktemp -d /private/tmp/bambubar-build.XXXXXX)"
trap 'rm -rf "$TEMP_ROOT"' EXIT
APP_PATH="$TEMP_ROOT/$APP_NAME.app"
OUTPUT_PATH="dist/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/Gantry" "$APP_PATH/Contents/MacOS/Gantry"
chmod +x "$APP_PATH/Contents/MacOS/Gantry"
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
# Embedded Spoolbase filament catalog (loaded via Bundle.main at runtime).
cp "Resources/filament-catalog.json" "$APP_PATH/Contents/Resources/filament-catalog.json"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
xattr -cr "$APP_PATH"
# Prefer the stable self-signed identity (scripts/setup-signing.sh) so the
# macOS Local Network grant persists across rebuilds. Fall back to ad-hoc.
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null | awk '/BambuBar Local Signing/{print $2; exit}')"
if [[ -n "$SIGN_HASH" ]]; then
    codesign --force --sign "$SIGN_HASH" --identifier "$BUNDLE_ID" --entitlements "Resources/Gantry.entitlements" "$APP_PATH"
else
    echo "Uwaga: brak stałej tożsamości podpisu — podpisuję ad-hoc (uruchom scripts/setup-signing.sh)." >&2
    APP_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""
    codesign --force --sign - --identifier "$BUNDLE_ID" --requirements "$APP_REQUIREMENT" --entitlements "Resources/Gantry.entitlements" "$APP_PATH"
fi
xattr -cr "$APP_PATH"
mkdir -p "$OUTPUT_PATH"
rsync -a --delete "$APP_PATH/" "$OUTPUT_PATH/"
# Finder (and iCloud/Documents sync) stamps com.apple.FinderInfo on the .app bundle root, which a
# --strict verify rejects as "detritus". Strip it just before verifying; --deep still validates the
# nested code, which is what actually matters for launch.
xattr -cr "$OUTPUT_PATH"
codesign --verify --deep "$OUTPUT_PATH"
echo "Uniwersalna binarka: $(lipo -archs "$OUTPUT_PATH/Contents/MacOS/Gantry" 2>/dev/null)"
echo "Gotowe: $PROJECT_DIR/$OUTPUT_PATH"
