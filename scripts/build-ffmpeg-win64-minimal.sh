#!/usr/bin/env bash
# Cross-compiles a MINIMAL win64 ffmpeg.exe for the Windows release.
#
# The stock BtbN "gpl" build is 139 MB because it carries every codec, muxer and filter FFmpeg has.
# Gantry uses ffmpeg as a decoder only, on exactly two paths:
#
#   Bambu    (Services/BambuCameraStream.cs)  -f h264 -i pipe:0  -an -f mjpeg      -q:v 6 pipe:1
#   Anycubic (Services/AnycubicFlvStream.cs)  -i <http url>      -an -f image2pipe -vcodec mjpeg -q:v 5 -
#
# So the build needs: the h264 decoder/parser, the h264 and flv demuxers, the mjpeg encoder, the mjpeg
# and image2pipe muxers, the pipe/file/http/tcp protocols, and swscale with the scale+format filters
# (ffmpeg inserts a pixel-format conversion between h264's yuv420p and the mjpeg encoder's yuvj420p).
# Everything else is switched off. Result: single-digit MB instead of 139.
#
# Built without --enable-gpl: the h264 decoder and everything else here is LGPL, which is the cleaner
# licence to redistribute. Cross-compiled with mingw-w64 on Linux, far simpler and faster in CI than
# MSYS2 on a Windows runner. Usage: scripts/build-ffmpeg-win64-minimal.sh <output-dir>
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"   # pinned so the artifact is reproducible and cacheable
OUT_DIR="${1:?usage: $0 <output-dir>}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Fetching FFmpeg $FFMPEG_VERSION"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o "$WORK_DIR/ffmpeg.tar.xz"
tar -xf "$WORK_DIR/ffmpeg.tar.xz" -C "$WORK_DIR"
cd "$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"

echo "==> Configuring (decode-only, no extras)"
./configure \
    --prefix="$WORK_DIR/install" \
    --target-os=mingw32 \
    --arch=x86_64 \
    --cross-prefix=x86_64-w64-mingw32- \
    --pkg-config=pkg-config \
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
    --enable-swresample

echo "==> Building"
make -j"$(nproc)"
test -f ffmpeg.exe || { echo "ffmpeg.exe was not produced"; exit 1; }

mkdir -p "$OUT_DIR"
cp ffmpeg.exe "$OUT_DIR/ffmpeg.exe"
x86_64-w64-mingw32-strip "$OUT_DIR/ffmpeg.exe" || true

SIZE_MB=$(( $(stat -c%s "$OUT_DIR/ffmpeg.exe") / 1024 / 1024 ))
echo "==> Done: $OUT_DIR/ffmpeg.exe (${SIZE_MB} MB, was 139 MB with the stock gpl build)"
