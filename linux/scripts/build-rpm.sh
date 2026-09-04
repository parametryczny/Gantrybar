#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=$(PYTHONPATH="$ROOT/linux" python3 -c 'from gantry import __version__; print(__version__)')
TOPDIR="$ROOT/linux/build/rpmbuild"
SOURCE="$ROOT/linux/build/rpm-source/gantry-$VERSION"
OUTPUT="$ROOT/linux/dist/Gantry-$VERSION-Linux-noarch.rpm"

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "build-rpm.sh requires rpmbuild (Fedora: sudo dnf install rpm-build python3-devel)." >&2
  exit 1
fi

rm -rf "$TOPDIR" "$ROOT/linux/build/rpm-source"
mkdir -p "$TOPDIR/BUILD" "$TOPDIR/BUILDROOT" "$TOPDIR/RPMS" "$TOPDIR/SOURCES" \
  "$TOPDIR/SPECS" "$TOPDIR/SRPMS" "$SOURCE" "$ROOT/linux/dist"

# Build from a clean source archive so rpmbuild validates exactly what will be installed.
mkdir -p "$SOURCE/linux"
# Translation catalog, shared verbatim with the macOS and Windows builds.
install -Dm0644 "$ROOT/i18n/pl.json" "$ROOT/linux/gantry/data/i18n-pl.json"
cp -a "$ROOT/linux/gantry" "$SOURCE/linux/gantry"
cp -a "$ROOT/linux/assets" "$SOURCE/linux/assets"
cp -a "$ROOT/linux/packaging" "$SOURCE/linux/packaging"
cp "$ROOT/linux/README.md" "$SOURCE/linux/README.md"
cp "$ROOT/LICENSE" "$SOURCE/LICENSE"
find "$SOURCE" -type d -name __pycache__ -prune -exec rm -rf {} +
tar -C "$(dirname "$SOURCE")" -czf "$TOPDIR/SOURCES/gantry-$VERSION.tar.gz" "gantry-$VERSION"
sed "s/@VERSION@/$VERSION/g" "$ROOT/linux/packaging/gantry.spec" > "$TOPDIR/SPECS/gantry.spec"

rpmbuild -bb --define "_topdir $TOPDIR" "$TOPDIR/SPECS/gantry.spec"
PACKAGE=$(find "$TOPDIR/RPMS" -type f -name 'gantry-*.noarch.rpm' -print | head -n 1)
if [ -z "$PACKAGE" ]; then
  echo "rpmbuild completed without producing a noarch RPM." >&2
  exit 1
fi
cp "$PACKAGE" "$OUTPUT"
echo "$OUTPUT"
