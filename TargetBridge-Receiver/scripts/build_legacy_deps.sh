#!/bin/bash
# Builds the Receiver's libraries for older Macs: SDL2 and a minimal FFmpeg
# (H.264/HEVC with VideoToolbox hardware decoding, swscale), both for
# macOS 10.14 Mojave on Intel.
#
# Homebrew's libraries are built for the macOS version of the build machine
# (macOS 15 on GitHub's runners), which makes the Receiver refuse to start on
# older systems. These are built from source with an explicit minimum.
#
#   bash build_legacy_deps.sh <prefix>
#
# Afterwards build the Receiver with
#   PKG_CONFIG_PATH=<prefix>/lib/pkgconfig MACOSX_DEPLOYMENT_TARGET=10.14
set -euo pipefail

PREFIX="${1:?Usage: build_legacy_deps.sh <prefix>}"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-10.14}"
SDL2_VERSION="${SDL2_VERSION:-2.30.9}"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
JOBS="$(sysctl -n hw.ncpu)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export MACOSX_DEPLOYMENT_TARGET="$MIN_OS"
mkdir -p "$PREFIX"

echo "== SDL2 $SDL2_VERSION for macOS $MIN_OS"
curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" \
    | tar -xz -C "$WORK"
cmake -S "$WORK/SDL2-${SDL2_VERSION}" -B "$WORK/sdl2-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
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

echo "== FFmpeg $FFMPEG_VERSION for macOS $MIN_OS"
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
        --arch=x86_64 \
        --extra-cflags="-mmacosx-version-min=$MIN_OS" \
        --extra-ldflags="-mmacosx-version-min=$MIN_OS"
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
