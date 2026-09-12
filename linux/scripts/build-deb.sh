#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=$(PYTHONPATH="$ROOT/linux" python3 -c 'from gantry import __version__; print(__version__)')
ARCH=all
# GANTRY_EDITION=lite builds Gantry LITE: the same code with the extras switched off (tray, printers,
# notifications, short settings). It is a separate package that replaces gantry rather than sitting
# beside it — both would own the same Python package directory.
EDITION=${GANTRY_EDITION:-full}
if [ "$EDITION" = "lite" ]; then
  PACKAGE=gantry-lite
  APP_NAME="Gantry LITE"
  BINARY=gantry-lite
  OTHER_EDITION=gantry
else
  PACKAGE=gantry
  APP_NAME=Gantry
  BINARY=gantry
  OTHER_EDITION=gantry-lite
fi
BUILD="$ROOT/linux/build/${PACKAGE}_${VERSION}_${ARCH}"
SUFFIX=${GANTRY_PACKAGE_SUFFIX:-}
if [ "$EDITION" = "lite" ]; then
  NAME_PREFIX="Gantry-LITE"
else
  NAME_PREFIX="Gantry"
fi
if [ -n "$SUFFIX" ]; then
  OUTPUT="$ROOT/linux/dist/${NAME_PREFIX}-${VERSION}-Linux-${ARCH}-${SUFFIX}.deb"
else
  OUTPUT="$ROOT/linux/dist/${NAME_PREFIX}-${VERSION}-Linux-${ARCH}.deb"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/DEBIAN" \
  "$BUILD/usr/bin" \
  "$BUILD/usr/lib/python3/dist-packages/gantry" \
  "$BUILD/usr/share/applications" \
  "$BUILD/usr/share/icons/hicolor/scalable/apps" \
  "$BUILD/usr/share/metainfo" \
  "$BUILD/usr/share/doc/gantry" \
  "$ROOT/linux/dist"

cat > "$BUILD/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: python3 (>= 3.10), python3-gi, python3-websocket, gir1.2-gtk-3.0, gir1.2-gdkpixbuf-2.0, gir1.2-gstreamer-1.0, gir1.2-ayatanaappindicator3-0.1, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-libav, libsecret-tools, gnome-keyring, libnotify-bin, openssl, avahi-daemon, x11-xserver-utils
Conflicts: bambubar, ${OTHER_EDITION}
Replaces: bambubar, ${OTHER_EDITION}
Maintainer: Kamil Grzegorczyk <parametryczny@users.noreply.github.com>
Homepage: https://github.com/parametryczny/gantrybar
Description: $APP_NAME 3D printer status monitor
 Gantry monitors Bambu Lab, Anycubic, Elegoo, Klipper/Moonraker and PrusaLink printers over the
 local network, shows print progress, temperatures, layers and filament slots,
 and lives in the system tray.
 The Raspberry Pi workshop mode provides a full-screen kiosk and an HTTPS
 configuration panel protected with an on-screen pairing code.
EOF

# Translation catalog, shared verbatim with the macOS and Windows builds.
mkdir -p "$ROOT/linux/gantry/data/i18n"
cp "$ROOT"/i18n/*.json "$ROOT/linux/gantry/data/i18n/"
cp "$ROOT/Resources/web-dashboard.html" "$ROOT/linux/gantry/data/web-dashboard.html"
cp -a "$ROOT/linux/gantry/." "$BUILD/usr/lib/python3/dist-packages/gantry/"
find "$BUILD/usr/lib/python3/dist-packages/gantry" -type d -name __pycache__ -prune -exec rm -rf {} +
if [ "$EDITION" = "lite" ]; then
  # Stamp the edition into the installed copy; the source tree stays the full edition.
  sed -i.bak 's/^EDITION = "full"$/EDITION = "lite"/' \
    "$BUILD/usr/lib/python3/dist-packages/gantry/edition.py"
  rm -f "$BUILD/usr/lib/python3/dist-packages/gantry/edition.py.bak"
  grep -q '^EDITION = "lite"$' "$BUILD/usr/lib/python3/dist-packages/gantry/edition.py"
  # LITE has neither the web dashboard nor Spoolbase, so their payload is not shipped.
  rm -f "$BUILD/usr/lib/python3/dist-packages/gantry/data/web-dashboard.html"
  rm -f "$BUILD/usr/lib/python3/dist-packages/gantry/data/filament-catalog.json"
fi
install -m 0755 "$ROOT/linux/packaging/$BINARY" "$BUILD/usr/bin/$BINARY"
install -m 0644 "$ROOT/linux/packaging/$PACKAGE.desktop" "$BUILD/usr/share/applications/$PACKAGE.desktop"
if [ "$EDITION" != "lite" ]; then
  install -m 0755 "$ROOT/linux/packaging/gantry-kiosk" "$BUILD/usr/bin/gantry-kiosk"
  install -m 0755 "$ROOT/linux/packaging/gantry-kiosk-setup" "$BUILD/usr/bin/gantry-kiosk-setup"
  install -m 0644 "$ROOT/linux/packaging/gantry-kiosk.desktop" "$BUILD/usr/share/applications/gantry-kiosk.desktop"
fi
install -m 0644 "$ROOT/linux/assets/gantry.svg" "$BUILD/usr/share/icons/hicolor/scalable/apps/gantry.svg"
if [ "$EDITION" != "lite" ]; then
  install -m 0644 "$ROOT/linux/packaging/gantry.metainfo.xml" "$BUILD/usr/share/metainfo/pl.parametryczny.Gantry.metainfo.xml"
fi
install -m 0644 "$ROOT/LICENSE" "$BUILD/usr/share/doc/gantry/copyright"
install -m 0644 "$ROOT/linux/packaging/Gantry-printers-template.csv" "$BUILD/usr/share/doc/gantry/Gantry-printers-template.csv"

if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --root-owner-group --build "$BUILD" "$OUTPUT"
else
  # A .deb is an ar archive containing these three files. This fallback lets maintainers
  # produce the architecture-independent package on macOS without Docker; CI still uses
  # dpkg-deb and validates the resulting package on Ubuntu.
  PARTS="$ROOT/linux/build/deb-parts"
  rm -rf "$PARTS"
  mkdir -p "$PARTS"
  printf '2.0\n' > "$PARTS/debian-binary"
  # BSD tar defaults to PAX and may preserve com.apple.* xattrs.  dpkg on
  # Ubuntu 26.04 rejects those extended headers as an unsupported tar type,
  # so the macOS fallback must emit plain ustar archives.
  COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root \
    -C "$BUILD/DEBIAN" -cJf "$PARTS/control.tar.xz" .
  COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root \
    -C "$BUILD" --exclude ./DEBIAN -cJf "$PARTS/data.tar.xz" .
  python3 "$ROOT/linux/scripts/make_deb_ar.py" "$OUTPUT" \
    "$PARTS/debian-binary" "$PARTS/control.tar.xz" "$PARTS/data.tar.xz"
fi
echo "$OUTPUT"
