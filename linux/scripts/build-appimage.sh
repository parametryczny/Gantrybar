#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=$(PYTHONPATH="$ROOT/linux" python3 -c 'from gantry import __version__; print(__version__)')
MACHINE=$(uname -m)
case "$MACHINE" in
  x86_64|amd64) APPIMAGE_ARCH=x86_64 ;;
  aarch64|arm64) APPIMAGE_ARCH=aarch64 ;;
  *) echo "Unsupported AppImage architecture: $MACHINE" >&2; exit 1 ;;
esac

APPDIR="$ROOT/linux/build/Gantry.AppDir"
PYI_DIST="$ROOT/linux/build/pyinstaller-dist"
PYI_WORK="$ROOT/linux/build/pyinstaller-work"
TOOLS="$ROOT/linux/build/appimage-tools"
OUTPUT="$ROOT/linux/dist/Gantry-$VERSION-Linux-$APPIMAGE_ARCH.AppImage"
LINUXDEPLOY_URL=${LINUXDEPLOY_URL:-"https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$APPIMAGE_ARCH.AppImage"}
GTK_PLUGIN_URL=${GTK_PLUGIN_URL:-"https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"}
# Packaging is a separate step so the AppDir can be de-duplicated between deploy and squash.
APPIMAGETOOL_URL=${APPIMAGETOOL_URL:-"https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$APPIMAGE_ARCH.AppImage"}

if ! python3 -c 'import PyInstaller' >/dev/null 2>&1; then
  echo "build-appimage.sh requires PyInstaller (python3 -m pip install pyinstaller)." >&2
  exit 1
fi
if ! python3 -c 'from Crypto.Cipher import AES' >/dev/null 2>&1; then
  echo "build-appimage.sh requires PyCryptodome (python3 -m pip install pycryptodome)." >&2
  exit 1
fi
for command_name in curl file gst-inspect-1.0 pkg-config patchelf readelf; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "build-appimage.sh requires $command_name." >&2
    exit 1
  fi
done
ZBAR_PLUGIN=$(gst-inspect-1.0 zbar | awk '/Filename/ { print $2; exit }')
if [ -z "$ZBAR_PLUGIN" ] || [ ! -f "$ZBAR_PLUGIN" ]; then
  echo "GStreamer zbar plugin was not found; install gst-plugins-bad before building." >&2
  exit 1
fi

rm -rf "$APPDIR" "$PYI_DIST" "$PYI_WORK" "$TOOLS"
mkdir -p "$APPDIR/usr/lib/gantry" \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" \
  "$APPDIR/usr/share/metainfo" \
  "$ROOT/linux/dist" "$TOOLS"

# PyInstaller provides the private Python runtime. Hidden GI repositories are loaded dynamically
# by Gantry and therefore must be declared explicitly for a reproducible portable build.
PYTHONPATH="$ROOT/linux${PYTHONPATH:+:$PYTHONPATH}" python3 -m PyInstaller --noconfirm --clean --onedir --name Gantry \
  --paths "$ROOT/linux" \
  --collect-data gantry \
  --hidden-import gi.repository.AyatanaAppIndicator3 \
  --hidden-import gi.repository.GdkPixbuf \
  --hidden-import gi.repository.Gst \
  --hidden-import Crypto.Cipher.AES \
  --hidden-import Crypto.Util.Padding \
  --hidden-import websocket \
  --distpath "$PYI_DIST" \
  --workpath "$PYI_WORK" \
  --specpath "$ROOT/linux/build" \
  "$ROOT/linux/packaging/appimage-entry.py"
cp -a "$PYI_DIST/Gantry/." "$APPDIR/usr/lib/gantry/"
ln -s ../lib/gantry/Gantry "$APPDIR/usr/bin/gantry"
install -m 0755 "$ROOT/linux/packaging/AppRun" "$APPDIR/AppRun"
install -m 0644 "$ROOT/linux/packaging/gantry.desktop" "$APPDIR/usr/share/applications/gantry.desktop"
install -m 0644 "$ROOT/linux/assets/gantry.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/gantry.svg"
install -m 0644 "$ROOT/linux/packaging/gantry.metainfo.xml" "$APPDIR/usr/share/metainfo/pl.parametryczny.Gantry.metainfo.xml"

curl -fsSL "$LINUXDEPLOY_URL" -o "$TOOLS/linuxdeploy.AppImage"
curl -fsSL "$GTK_PLUGIN_URL" -o "$TOOLS/linuxdeploy-plugin-gtk.sh"
curl -fsSL "$APPIMAGETOOL_URL" -o "$TOOLS/appimagetool.AppImage"
chmod +x "$TOOLS/linuxdeploy.AppImage" "$TOOLS/linuxdeploy-plugin-gtk.sh" "$TOOLS/appimagetool.AppImage"

# linuxdeploy's GTK plugin adds themes, schemas, typelibs, pixbuf loaders and the GTK libraries
# which PyInstaller cannot discover from Python imports alone.
PATH="$TOOLS:$PATH" DEPLOY_GTK_VERSION=3 VERSION="$VERSION" ARCH="$APPIMAGE_ARCH" \
  OUTPUT="$OUTPUT" "$TOOLS/linuxdeploy.AppImage" --appimage-extract-and-run \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/usr/share/applications/gantry.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/gantry.svg" \
  --library "$ZBAR_PLUGIN" \
  --plugin gtk

# PyInstaller collects the shared libraries it finds into usr/lib/gantry/_internal, and linuxdeploy
# then deploys the very same ones into usr/lib, so every big library was present twice (librsvg four
# times). mksquashfs already folds identical files together, so this is mostly about not shipping a
# confusing bundle and about the real hazard below: if the two copies ever DIFFER, which one wins
# depends on load order. Identical copies become symlinks; differing ones are reported loudly.
echo "==> De-duplicating the AppDir"
INTERNAL="$APPDIR/usr/lib/gantry/_internal"
LIBDIR="$APPDIR/usr/lib"
linked=0; differing=0; patched=0
if [ -d "$INTERNAL" ]; then
  for candidate in "$INTERNAL"/*.so*; do
    [ -f "$candidate" ] || continue                 # already a symlink, or nothing matched
    [ -L "$candidate" ] && continue
    name=$(basename "$candidate")
    twin="$LIBDIR/$name"
    [ -f "$twin" ] && [ ! -L "$twin" ] || continue
    if cmp -s "$candidate" "$twin"; then
      ln -sf "../../$name" "$candidate"             # _internal -> usr/lib
      linked=$((linked + 1))
    else
      # Bytes differ, but linuxdeploy runs patchelf on what it deploys, so the usual cause is a
      # rewritten rpath rather than a different library. GNU build-id survives patchelf and does not
      # survive a version change, so it tells the two apart. Same id: still safe to link ($ORIGIN
      # resolves through the symlink to usr/lib, where that copy's dependencies already live).
      id_a=$(readelf -n "$candidate" 2>/dev/null | awk '/Build ID/ { print $3; exit }')
      id_b=$(readelf -n "$twin" 2>/dev/null | awk '/Build ID/ { print $3; exit }')
      if [ -n "$id_a" ] && [ "$id_a" = "$id_b" ]; then
        ln -sf "../../$name" "$candidate"
        linked=$((linked + 1))
        patched=$((patched + 1))
      else
        echo "    UWAGA: $name to ROZNE wersje w _internal i usr/lib (build-id sie nie zgadza)" >&2
        differing=$((differing + 1))
      fi
    fi
  done
fi
echo "    zlinkowano: $linked (w tym $patched po patchelf), ROZNYCH wersji: $differing"

echo "==> Packing the AppImage"
ARCH="$APPIMAGE_ARCH" "$TOOLS/appimagetool.AppImage" --appimage-extract-and-run \
  "$APPDIR" "$OUTPUT"

if [ ! -x "$OUTPUT" ]; then
  echo "appimagetool did not create $OUTPUT" >&2
  exit 1
fi
echo "$OUTPUT"
