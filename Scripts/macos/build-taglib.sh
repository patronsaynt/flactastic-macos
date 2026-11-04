#!/usr/bin/env bash
# Builds TagLib for the app's own deployment target into .deps/taglib, for
# release builds. Homebrew's TagLib is built for the Mac it's installed on
# (macOS 26 here), so a release linked against it could fail on older macOS
# wherever TagLib uses something newer. Debug builds keep using Homebrew's.
#
# Usage: build-taglib.sh [deployment-target]   (default 14.0)
# Prints nothing more and exits early when the build is already in place.

set -euo pipefail

VERSION="2.3.2"
# The checksum Homebrew pins for this release's source.
SHA256="3ca2d8afaa7f1cf7f6ed10e511ebc368bfacd6dcaa3dbfa690b89e502e8963dc"
URL="https://github.com/taglib/taglib/releases/download/v$VERSION/taglib-$VERSION.tar.gz"
TARGET="${1:-14.0}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
DEPS="$PROJECT_ROOT/.deps"
PREFIX="$DEPS/taglib"
STAMP="$PREFIX/.built-$VERSION-macos-$TARGET"

[[ -f "$STAMP" ]] && exit 0

command -v cmake >/dev/null || { echo "ERROR: cmake not found (brew install cmake)" >&2; exit 1; }
# TagLib needs utfcpp's headers to build (header-only, so nothing of it ships).
UTF8CPP="$(brew --prefix utf8cpp 2>/dev/null || true)"
[[ -d "$UTF8CPP/include" ]] || { echo "ERROR: utfcpp not found (brew install utf8cpp)" >&2; exit 1; }

echo "▶ Building TagLib $VERSION for macOS $TARGET..."
mkdir -p "$DEPS/download"
TARBALL="$DEPS/download/taglib-$VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
    curl -fsSL "$URL" -o "$TARBALL.part"
    mv "$TARBALL.part" "$TARBALL"
fi
if [[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$SHA256" ]]; then
    rm -f "$TARBALL"
    echo "ERROR: taglib-$VERSION.tar.gz doesn't match its pinned checksum" >&2
    exit 1
fi

rm -rf "$DEPS/src" "$DEPS/build" "$PREFIX"
mkdir -p "$DEPS/src"
tar -xzf "$TARBALL" -C "$DEPS/src"

cmake -S "$DEPS/src/taglib-$VERSION" -B "$DEPS/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$UTF8CPP" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_BINDINGS=ON \
    -DWITH_ZLIB=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF >/dev/null
cmake --build "$DEPS/build" -j "$(sysctl -n hw.ncpu)" >/dev/null
cmake --install "$DEPS/build" >/dev/null
# Escape spaces in the install path, or the flags read from these files
# split at them (the project lives under "computer stuff").
sed -i '' '/^prefix=/s/ /\\ /g' "$PREFIX"/lib/pkgconfig/*.pc
rm -rf "$DEPS/src" "$DEPS/build"
touch "$STAMP"
echo "  installed to $PREFIX"
