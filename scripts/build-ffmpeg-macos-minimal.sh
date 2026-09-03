#!/usr/bin/env bash
# Builds a MINIMAL universal (arm64 + x86_64) ffmpeg for the macOS bundle.
#
# Why this exists: the Kobra S1 camera is HTTP/FLV, which AVFoundation will not demux, so
# Services/AnycubicCameraStream.swift shells out to ffmpeg. build-app.sh used to copy whatever ffmpeg
# happened to be on the build host, which meant released .app bundles shipped WITHOUT it (the 0.10.0
# dmg is 4 MB) and the Kobra S1 camera silently told users to install Homebrew. This produces a small
# ffmpeg we can always bundle, mirroring scripts/build-ffmpeg-win64-minimal.sh.
#
# Only the two paths Gantry actually invokes are compiled in:
#   Anycubic  -i <http url> -an -f image2pipe -vcodec mjpeg -q:v 5 -
#   (Bambu decodes natively with VideoToolbox and needs no ffmpeg at all on macOS.)
#
# LGPL only, no --enable-gpl: the h264 decoder does not need it and LGPL is cleaner to redistribute.
# Usage: scripts/build-ffmpeg-macos-minimal.sh <output-dir>
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"   # pinned so the artifact is reproducible
OUT_DIR="${1:?usage: $0 <output-dir>}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Fetching FFmpeg $FFMPEG_VERSION"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "$WORK_DIR/ffmpeg.tar.xz"

build_slice() {
    local arch="$1" src="$WORK_DIR/src-$1"
    mkdir -p "$src"
    tar -xf "$WORK_DIR/ffmpeg.tar.xz" -C "$src" --strip-components=1
    cd "$src"

    # ${extra[@]+...} because macOS ships bash 3.2, where an empty array trips set -u.
    local extra=()
    [[ "$arch" != "$(uname -m)" ]] && extra+=(--enable-cross-compile)
    # ffmpeg's x86 assembly needs nasm; without it fall back to the C decoder for that slice rather
    # than failing the build or installing tools onto the user's machine.
    if [[ "$arch" == "x86_64" ]] && ! command -v nasm >/dev/null 2>&1; then
        echo "    (no nasm: building the x86_64 slice without x86 assembly)"
        extra+=(--disable-x86asm)
    fi

    echo "==> Configuring $arch"
    ./configure \
        --prefix="$WORK_DIR/install-$arch" \
        --arch="$arch" \
        --cc="clang -arch $arch" \
        --extra-cflags="-arch $arch -mmacosx-version-min=13.0" \
        --extra-ldflags="-arch $arch -mmacosx-version-min=13.0" \
        --disable-everything \
        --disable-doc \
        --disable-ffplay \
        --disable-ffprobe \
        --disable-avdevice \
        --disable-postproc \
        --disable-debug \
        --disable-autodetect \
        --disable-iconv \
        --enable-small \
        --enable-network \
        --enable-decoder=h264,mjpeg \
        --enable-parser=h264,mjpeg \
        --enable-demuxer=h264,flv,mjpeg,image2pipe \
        --enable-encoder=mjpeg \
        --enable-muxer=mjpeg,image2pipe,image2 \
        --enable-protocol=pipe,file,http,tcp \
        --enable-filter=scale,format,null,copy \
        --enable-swscale \
        --enable-swresample \
        ${extra[@]+"${extra[@]}"} > "$WORK_DIR/configure-$arch.log" 2>&1 \
        || { echo "configure failed for $arch:"; tail -20 "$WORK_DIR/configure-$arch.log"; exit 1; }

    echo "==> Building $arch"
    make -j"$(sysctl -n hw.ncpu)" ffmpeg > "$WORK_DIR/make-$arch.log" 2>&1 \
        || { echo "make failed for $arch:"; tail -20 "$WORK_DIR/make-$arch.log"; exit 1; }
    cp ffmpeg "$WORK_DIR/ffmpeg-$arch"
}

build_slice arm64
build_slice x86_64

echo "==> Merging into a universal binary"
lipo -create "$WORK_DIR/ffmpeg-arm64" "$WORK_DIR/ffmpeg-x86_64" -output "$OUT_DIR/ffmpeg"
strip -S "$OUT_DIR/ffmpeg" 2>/dev/null || true
chmod +x "$OUT_DIR/ffmpeg"

SIZE_MB=$(( $(stat -f%z "$OUT_DIR/ffmpeg") / 1024 / 1024 ))
echo "==> Done: $OUT_DIR/ffmpeg (${SIZE_MB} MB, $(lipo -archs "$OUT_DIR/ffmpeg"))"
