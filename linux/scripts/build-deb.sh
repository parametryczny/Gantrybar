#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=$(PYTHONPATH="$ROOT/linux" python3 -c 'from bambubar import __version__; print(__version__)')
ARCH=all
BUILD="$ROOT/linux/build/bambubar_${VERSION}_${ARCH}"
OUTPUT="$ROOT/linux/dist/Gantry-${VERSION}-Linux-${ARCH}.deb"

rm -rf "$BUILD"
mkdir -p "$BUILD/DEBIAN" \
  "$BUILD/usr/bin" \
  "$BUILD/usr/lib/python3/dist-packages/bambubar" \
  "$BUILD/usr/share/applications" \
  "$BUILD/usr/share/icons/hicolor/scalable/apps" \
  "$BUILD/usr/share/metainfo" \
  "$BUILD/usr/share/doc/bambubar" \
  "$ROOT/linux/dist"

cat > "$BUILD/DEBIAN/control" <<EOF
Package: bambubar
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: python3 (>= 3.10), python3-gi, python3-websocket, gir1.2-gtk-3.0, gir1.2-ayatanaappindicator3-0.1, libsecret-tools, gnome-keyring, libnotify-bin, openssl, avahi-daemon, x11-xserver-utils
Maintainer: Kamil Grzegorczyk <parametryczny@users.noreply.github.com>
Homepage: https://github.com/parametryczny/BambuBar
Description: Gantry 3D printer status monitor
 Gantry monitors Bambu Lab, Klipper/Moonraker and PrusaLink printers over the
 local network, shows print progress, temperatures, layers and filament slots,
 and lives in the system tray.
 The Raspberry Pi workshop mode provides a full-screen kiosk and an HTTPS
 configuration panel protected with an on-screen pairing code.
EOF

cp -a "$ROOT/linux/bambubar/." "$BUILD/usr/lib/python3/dist-packages/bambubar/"
find "$BUILD/usr/lib/python3/dist-packages/bambubar" -type d -name __pycache__ -prune -exec rm -rf {} +
install -m 0755 "$ROOT/linux/packaging/bambubar" "$BUILD/usr/bin/bambubar"
install -m 0755 "$ROOT/linux/packaging/bambubar-kiosk" "$BUILD/usr/bin/bambubar-kiosk"
install -m 0755 "$ROOT/linux/packaging/bambubar-kiosk-setup" "$BUILD/usr/bin/bambubar-kiosk-setup"
install -m 0644 "$ROOT/linux/packaging/bambubar.desktop" "$BUILD/usr/share/applications/bambubar.desktop"
install -m 0644 "$ROOT/linux/packaging/bambubar-kiosk.desktop" "$BUILD/usr/share/applications/bambubar-kiosk.desktop"
install -m 0644 "$ROOT/linux/assets/bambubar.svg" "$BUILD/usr/share/icons/hicolor/scalable/apps/bambubar.svg"
install -m 0644 "$ROOT/linux/packaging/bambubar.metainfo.xml" "$BUILD/usr/share/metainfo/pl.parametryczny.BambuBar.metainfo.xml"
install -m 0644 "$ROOT/LICENSE" "$BUILD/usr/share/doc/bambubar/copyright"
install -m 0644 "$ROOT/linux/packaging/BambuBar-printers-template.csv" "$BUILD/usr/share/doc/bambubar/Gantry-printers-template.csv"

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
  COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname root \
    -C "$BUILD/DEBIAN" -cJf "$PARTS/control.tar.xz" .
  COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname root \
    -C "$BUILD" --exclude ./DEBIAN -cJf "$PARTS/data.tar.xz" .
  python3 "$ROOT/linux/scripts/make_deb_ar.py" "$OUTPUT" \
    "$PARTS/debian-binary" "$PARTS/control.tar.xz" "$PARTS/data.tar.xz"
fi
echo "$OUTPUT"
