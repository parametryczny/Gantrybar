#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

zsh scripts/build-app.sh local
zsh scripts/build-app.sh keychain

LOCAL_ZIP="dist/Gantry-$VERSION-macOS-Local.zip"
KEYCHAIN_ZIP="dist/Gantry-$VERSION-macOS-Keychain.zip"
rm -f "$LOCAL_ZIP" "$KEYCHAIN_ZIP"
(
    cd dist
    /usr/bin/zip -qry "${LOCAL_ZIP:t}" "Gantry.app" -x '*.DS_Store'
    /usr/bin/zip -qry "${KEYCHAIN_ZIP:t}" "Gantry Keychain.app" -x '*.DS_Store'
)

echo "Gotowe: $PROJECT_DIR/$LOCAL_ZIP"
echo "Gotowe: $PROJECT_DIR/$KEYCHAIN_ZIP"
