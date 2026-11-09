#!/usr/bin/env bash
# Builds FLACtastic, creates a .app bundle, embeds dynamic dependencies,
# and code signs it for development distribution.
#
# Signing identity: $FLACTASTIC_SIGN_IDENTITY if set, else the stable
# "FLACtastic Development" identity when it exists (create it once with
# create-dev-signing-identity.sh), else ad-hoc. Ad-hoc builds get a new
# identity every time, so macOS forgets privacy grants like Local Network
# access across rebuilds.
#
# Usage: package-macos.sh [--skip-build]
#
# Outputs:
#   build/FLACtastic.app

set -euo pipefail

# ── Resolve paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"

BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/FLACtastic.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

VERSION_FILE="$PROJECT_ROOT/version.txt"
ENTITLEMENTS_FILE="$PROJECT_ROOT/Resources/FLACtastic.entitlements"
APPICON_SOURCE="$PROJECT_ROOT/Sources/flactastic/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# Must track Package.swift's `platforms: [.macOS(.v14)]` and the
# LSMinimumSystemVersion generated below. Embedded third-party dylibs (see
# the vtool step after dependency embedding) get their declared minimum OS
# forced down to this, since a Homebrew bottle built on a newer host OS
# otherwise ships a dylib whose minos exceeds what this app claims to
# support — dyld then refuses to load it on any Mac older than the bottle's
# build machine, crashing the app at launch before any of our code runs.
DEPLOYMENT_TARGET="14.0"

SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
    esac
done

# ── Read version ────────────────────────────────────────────────────────────
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "ERROR: $VERSION_FILE not found" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_NUMBER="$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶ FLACtastic packaging"
echo "  version:      $VERSION"
echo "  build number: $BUILD_NUMBER"
echo "  output:       $APP_BUNDLE"
echo

# ── Build release binary ────────────────────────────────────────────────────
if [[ $SKIP_BUILD -eq 0 ]]; then
    echo "▶ Building release binary (swift build -c release)..."
    cd "$PROJECT_ROOT"
    # Stamp the real SDK version into the binary. The Swift Build backend
    # (default since Xcode 27) records the deployment target as the SDK
    # version, so AppKit treats the app as built for macOS 14 and draws
    # pre-Tahoe controls (e.g. a flat round slider knob instead of the glass
    # pill).
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    # Link a TagLib built for the deployment target, not Homebrew's (built
    # for the Mac it's on). See build-taglib.sh.
    "$SCRIPT_DIR/build-taglib.sh" "$DEPLOYMENT_TARGET"
    export PKG_CONFIG_PATH="$PROJECT_ROOT/.deps/taglib/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    swift build -c release \
        -Xlinker -platform_version -Xlinker macos \
        -Xlinker "$DEPLOYMENT_TARGET" -Xlinker "$SDK_VERSION"
fi

BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/flactastic"
if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: built binary not found at $BINARY" >&2
    exit 1
fi

# ── Create bundle skeleton ──────────────────────────────────────────────────
echo
echo "▶ Creating .app bundle skeleton..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

# ── Copy binary ─────────────────────────────────────────────────────────────
cp "$BINARY" "$MACOS_DIR/flactastic"
chmod +x "$MACOS_DIR/flactastic"

# ── Copy SPM-generated resource bundle (if present) ─────────────────────────
# SPM emits a "<target>_<target>.bundle" for resources declared in Package.swift.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$RESOURCES_DIR/"
    echo "  copied resource bundle: $(basename "$bundle")"
done
shopt -u nullglob

# ── Generate Info.plist ─────────────────────────────────────────────────────
echo
echo "▶ Generating Info.plist..."
"$SCRIPT_DIR/generate-info-plist.sh" "$CONTENTS_DIR/Info.plist" "$VERSION" "$BUILD_NUMBER"

# ── Generate AppIcon.icns ───────────────────────────────────────────────────
if [[ -f "$APPICON_SOURCE" ]]; then
    echo
    echo "▶ Generating AppIcon.icns..."
    "$SCRIPT_DIR/png-to-icns.sh" "$APPICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "WARNING: $APPICON_SOURCE not found — bundle will have no icon" >&2
fi

# ── PkgInfo (legacy but harmless) ───────────────────────────────────────────
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# ── Bundle dynamic library dependencies ─────────────────────────────────────
echo
echo "▶ Embedding dynamic library dependencies..."

# The load paths `otool -L` lists, whole: paths may contain spaces (this
# project lives under "computer stuff"), so they're cut at the version
# note rather than at the first space.
load_paths() {
    otool -L "$1" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//'
}

# Returns non-system dylib paths the binary depends on.
list_external_dylibs() {
    local target="$1"
    load_paths "$target" \
        | grep -v "^/usr/lib/" \
        | grep -v "^/System/" \
        | grep -v "^@" \
        | grep -v "^$(basename "$target")$" \
        || true
}

# Recursively copy non-system dylibs into Frameworks/ and rewrite IDs/paths.
# Uses a temp file (instead of associative arrays) for Bash 3.2 compatibility.
BUNDLED_LIST="$(mktemp)"
trap 'rm -f "$BUNDLED_LIST"' EXIT

embed_dylib() {
    local src="$1"
    [[ -z "$src" ]] && return 0
    local name
    name="$(basename "$src")"
    if grep -Fxq "$name" "$BUNDLED_LIST" 2>/dev/null; then
        return 0
    fi
    if [[ ! -f "$src" ]]; then
        echo "  WARNING: dependency not found: $src" >&2
        return 0
    fi
    local dest="$FRAMEWORKS_DIR/$name"
    cp "$src" "$dest"
    chmod u+w "$dest"
    install_name_tool -id "@rpath/$name" "$dest"
    echo "$name" >> "$BUNDLED_LIST"
    echo "  embedded: $name"
    # Recurse for transitive deps
    while IFS= read -r dep; do
        embed_dylib "$dep"
    done < <(list_external_dylibs "$dest")
}

# Embed direct deps of the main binary
while IFS= read -r dep; do
    embed_dylib "$dep"
done < <(list_external_dylibs "$MACOS_DIR/flactastic")

# The app runs with library validation on (no disable-library-validation
# entitlement), so macOS refuses any dylib not signed by the app's own team.
# TagLib is linked statically for this reason (build-taglib.sh). Anything
# that ends up here would crash the app at launch, so stop now instead.
if [[ -s "$BUNDLED_LIST" ]]; then
    echo "ERROR: the binary links third-party dylibs, which library validation will refuse:" >&2
    sed 's/^/  /' "$BUNDLED_LIST" >&2
    echo "Link them statically, or sign them with the app's Developer ID team." >&2
    exit 1
fi

# Rewrite the main binary's load commands to look in Frameworks/
chmod u+w "$MACOS_DIR/flactastic"
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    original="$(load_paths "$MACOS_DIR/flactastic" | grep "/$name$" || true)"
    if [[ -n "$original" ]]; then
        install_name_tool -change "$original" "@rpath/$name" "$MACOS_DIR/flactastic"
    fi
done < "$BUNDLED_LIST"

# Add an rpath so @rpath resolves to Frameworks/
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/flactastic" 2>/dev/null || true

# Also rewrite cross-references between embedded dylibs
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    chmod u+w "$dylib"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        original="$(load_paths "$dylib" | grep "/$name$" | grep -v "^@rpath" || true)"
        if [[ -n "$original" ]]; then
            install_name_tool -change "$original" "@rpath/$name" "$dylib"
        fi
    done < "$BUNDLED_LIST"
done

rm -f "$BUNDLED_LIST"
trap - EXIT

# ── Pin embedded dylibs' declared minimum OS ────────────────────────────────
# Homebrew bottles are built against whatever OS the Homebrew CI runner (or
# your own machine, for local taps) happened to be on, and stamp that as the
# dylib's LC_BUILD_VERSION minos — independent of, and often newer than,
# this app's own deployment target. A dylib is a direct (non-weak) load
# dependency of the main binary, so dyld resolves it at process startup, not
# on first use: if its minos exceeds the OS actually running, the app can
# fail before a single line of our code executes, surfacing to the user as
# an instant, silent crash on launch. `vtool` rewrites that declared
# minimum after the fact. TagLib is now built for the deployment target
# (build-taglib.sh), so this is a no-op for it; it stays as a safety net
# for any other Homebrew dylib, whose code it can't actually retarget.
echo
echo "▶ Pinning embedded dylibs to deployment target $DEPLOYMENT_TARGET..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    minos="$(otool -l "$dylib" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
    if [[ -n "$minos" && "$minos" != "$DEPLOYMENT_TARGET" ]]; then
        chmod u+w "$dylib"
        vtool -set-build-version macos "$DEPLOYMENT_TARGET" "$DEPLOYMENT_TARGET" -replace -output "$dylib" "$dylib"
        echo "  $(basename "$dylib"): minos $minos → $DEPLOYMENT_TARGET"
    fi
done

# ── Code sign ───────────────────────────────────────────────────────────────
DEV_IDENTITY="FLACtastic Development"
if [[ -n "${FLACTASTIC_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$FLACTASTIC_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$DEV_IDENTITY\""; then
    SIGN_IDENTITY="$DEV_IDENTITY"
else
    SIGN_IDENTITY="-"
fi

echo
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "▶ Code signing (ad-hoc)..."
    echo "  Tip: run Scripts/macos/create-dev-signing-identity.sh once so rebuilds"
    echo "  keep their Local Network permission."
else
    echo "▶ Code signing as \"$SIGN_IDENTITY\"..."
fi

# Sign embedded dylibs first, then the main binary, then the app bundle.
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$dylib"
done

if [[ -f "$ENTITLEMENTS_FILE" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
        --entitlements "$ENTITLEMENTS_FILE" \
        --options runtime \
        "$APP_BUNDLE"
else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_BUNDLE"
fi

# Verify signature
codesign --verify --verbose=2 "$APP_BUNDLE"

# ── Done ────────────────────────────────────────────────────────────────────
APP_SIZE="$(du -sh "$APP_BUNDLE" | cut -f1)"
echo
echo "✅ App bundle ready"
echo "   path: $APP_BUNDLE"
echo "   size: $APP_SIZE"
