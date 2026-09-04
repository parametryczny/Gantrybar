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
        SWIFT_FLAGS=(-Xswiftc -DKEYCHAIN_STORAGE
             # macOS 27 beta crashes inside swift_task_isCurrentExecutor, so every dynamic
             # isolation check AppKit triggers (isFlipped on hit-test, MainActor closures from
             # RunLoop timers) is a landmine. The checks are redundant here: the code is already
             # main-thread only. Drop them until the OS runtime is fixed.
             -Xswiftc -Xfrontend -Xswiftc -disable-dynamic-actor-isolation)
        ;;
    keychain)
        APP_NAME="Gantry Keychain"
        BUNDLE_ID="pl.gantry.app.keychain"
        SWIFT_FLAGS=(-Xswiftc -DKEYCHAIN_STORAGE
             # macOS 27 beta crashes inside swift_task_isCurrentExecutor, so every dynamic
             # isolation check AppKit triggers (isFlipped on hit-test, MainActor closures from
             # RunLoop timers) is a landmine. The checks are redundant here: the code is already
             # main-thread only. Drop them until the OS runtime is fixed.
             -Xswiftc -Xfrontend -Xswiftc -disable-dynamic-actor-isolation)
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
BUILD_ARGS=(-c release --disable-sandbox "${ARCH_FLAGS[@]}" "${SWIFT_FLAGS[@]}")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
TEMP_ROOT="$(mktemp -d /private/tmp/bambubar-build.XXXXXX)"
trap 'rm -rf "$TEMP_ROOT"' EXIT
APP_PATH="$TEMP_ROOT/$APP_NAME.app"
OUTPUT_PATH="dist/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/Gantry" "$APP_PATH/Contents/MacOS/Gantry"
chmod +x "$APP_PATH/Contents/MacOS/Gantry"
# Kobra S1 exposes its camera as FLV, which AVFoundation will not demux, so we ship a small ffmpeg.
# This used to copy whatever ffmpeg happened to be on the build host, which meant released bundles had
# none at all (the 0.10.0 dmg is 4 MB) and the Kobra S1 camera just told users to install Homebrew.
# Now it is a pinned, decode-only universal build (~4 MB), produced once into vendor/ and reused.
VENDORED_FFMPEG="vendor/ffmpeg-macos/ffmpeg"
if [[ ! -x "$VENDORED_FFMPEG" ]]; then
    echo "Buduję minimalny ffmpeg (jednorazowo, kilka minut)…"
    scripts/build-ffmpeg-macos-minimal.sh "$(dirname "$VENDORED_FFMPEG")"
fi
cp "$VENDORED_FFMPEG" "$APP_PATH/Contents/MacOS/ffmpeg"
chmod +x "$APP_PATH/Contents/MacOS/ffmpeg"
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
# Embedded Spoolbase filament catalog (loaded via Bundle.main at runtime).
cp "Resources/filament-catalog.json" "$APP_PATH/Contents/Resources/filament-catalog.json"
# Translation catalog, shared verbatim with the Windows and Linux builds.
mkdir -p "$APP_PATH/Contents/Resources/i18n"
cp "i18n/pl.json" "$APP_PATH/Contents/Resources/i18n/pl.json"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_PATH/Contents/Info.plist"
xattr -cr "$APP_PATH"
# Prefer the stable self-signed identity (scripts/setup-signing.sh) so the
# macOS Local Network grant persists across rebuilds. Fall back to ad-hoc.
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null | awk '/BambuBar Local Signing/{print $2; exit}')"
# Nested Mach-O executables are NOT covered by signing the bundle, so ffmpeg has to be signed on its
# own and BEFORE the app, or `codesign --verify --deep` rejects the bundle with "code object is not
# signed at all".
if [[ -n "$SIGN_HASH" ]]; then
    codesign --force --sign "$SIGN_HASH" "$APP_PATH/Contents/MacOS/ffmpeg"
else
    codesign --force --sign - "$APP_PATH/Contents/MacOS/ffmpeg"
fi
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
