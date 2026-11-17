#!/bin/bash
# Builds the Receiver's libraries from source: SDL2 and a minimal FFmpeg
# with only what the Receiver uses (H.264/HEVC decoding with VideoToolbox
# hardware acceleration, swscale), for one processor and minimum macOS.
#
# Used for all three Receivers. Homebrew's FFmpeg brings hundreds of codecs
# and their libraries (about 45 MB in the app) and is built for the build
# machine's macOS; this one is about 8 MB and has an explicit minimum.
#
#   MACOSX_DEPLOYMENT_TARGET=10.14 ARCH=x86_64 bash build_receiver_deps.sh <prefix>
#   MACOSX_DEPLOYMENT_TARGET=15.0  ARCH=arm64  bash build_receiver_deps.sh <prefix>
#
# ARCH defaults to this Mac's processor. Afterwards build the Receiver with
#   PKG_CONFIG_PATH=<prefix>/lib/pkgconfig MACOSX_DEPLOYMENT_TARGET=<same>
set -euo pipefail

PREFIX="${1:?Usage: build_receiver_deps.sh <prefix>}"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-10.14}"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64)  FFMPEG_ARCH=aarch64 ;;
  x86_64) FFMPEG_ARCH=x86_64 ;;
  *) echo "Unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac
# Building for the other processor (e.g. Apple Silicon on an Intel Mac).
FFMPEG_CROSS=()
if [[ "$ARCH" != "$(uname -m)" ]]; then
  FFMPEG_CROSS=(--enable-cross-compile --target-os=darwin)
fi
SDL2_VERSION="${SDL2_VERSION:-2.30.9}"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
JOBS="$(sysctl -n hw.ncpu)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export MACOSX_DEPLOYMENT_TARGET="$MIN_OS"
mkdir -p "$PREFIX"

echo "== SDL2 $SDL2_VERSION for macOS $MIN_OS ($ARCH)"
curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" \
    | tar -xz -C "$WORK"
cmake -S "$WORK/SDL2-${SDL2_VERSION}" -B "$WORK/sdl2-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
    -DCMAKE_MACOSX_RPATH=OFF \
    -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib"
cmake --build "$WORK/sdl2-build" --parallel "$JOBS"
cmake --install "$WORK/sdl2-build"
# Absolute install names, so dylibbundler finds every library on its own
# instead of asking for an @rpath directory (which would hang in CI).
for lib in "$PREFIX"/lib/libSDL2*.dylib; do
    [[ -L "$lib" ]] && continue
    install_name_tool -id "$PREFIX/lib/$(basename "$lib")" "$lib"
done

echo "== FFmpeg $FFMPEG_VERSION for macOS $MIN_OS ($ARCH)"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" | tar -xJ -C "$WORK"
(
    cd "$WORK/ffmpeg-${FFMPEG_VERSION}"
    # Only what the Receiver uses: libavcodec (H.264/HEVC decoders and their
    # VideoToolbox hardware acceleration), libavutil and libswscale. No
    # autodetected system libraries, so nothing newer sneaks in.
    ./configure \
        --prefix="$PREFIX" \
        --enable-shared --disable-static \
        --disable-programs --disable-doc \
        --disable-avdevice --disable-avformat --disable-avfilter --disable-swresample \
        --disable-network --disable-autodetect \
        --disable-everything \
        --enable-videotoolbox \
        --enable-decoder=h264,hevc \
        --enable-parser=h264,hevc \
        --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
        --arch="$FFMPEG_ARCH" "${FFMPEG_CROSS[@]}" \
        --extra-cflags="-arch $ARCH -mmacosx-version-min=$MIN_OS" \
        --extra-ldflags="-arch $ARCH -mmacosx-version-min=$MIN_OS"
    make -j"$JOBS"
    make install
)

echo "== Install names (must be absolute)"
for lib in "$PREFIX"/lib/*.dylib; do
    [[ -L "$lib" ]] && continue
    otool -D "$lib" | tail -n 1
done

echo "== Minimum macOS of the built libraries"
for lib in "$PREFIX"/lib/*.dylib; do
    [[ -L "$lib" ]] && continue
    printf '%s: ' "$(basename "$lib")"
    otool -l "$lib" | awk '$1 == "minos" || ($1 == "version" && prev ~ /LC_VERSION_MIN/) { print $2; exit } { prev = $2 }'
done
