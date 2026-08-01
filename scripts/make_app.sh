#!/usr/bin/env bash
#
# make_app.sh — assemble (and sign) dist/OpenWisper.app around an already-built
# SwiftPM binary.
#
#   bash scripts/make_app.sh [debug|release]        (default: release)
#
# Produces:
#   dist/OpenWisper.app/Contents/MacOS/OpenWisper   the built executable
#   dist/OpenWisper.app/Contents/Info.plist         copy of Resources/Info.plist
#   dist/OpenWisper.app/Contents/PkgInfo            "APPL????"
#
# This script does NOT build. `make app` runs `swift build -c $CONFIG` first and
# then calls it; running it standalone only works after a build of the same
# configuration (it locates the binary with `swift build --show-bin-path`, which
# does not compile anything).
#
# Env knobs:
#   SWIFT=/path/to/swift     toolchain override (same auto-detection as the Makefile)
#   CODESIGN_IDENTITY=name   signing identity; default: "OpenWisper Dev" when that
#                            identity exists in the keychain, else "-" (ad-hoc)
#
# Why CODESIGN_IDENTITY exists: macOS identifies an app for TCC by its code
# signature, and an ad-hoc ("-") signature changes on every build — so each
# rebuild looks like a brand new app and Input Monitoring / Accessibility have to
# be granted all over again. Create a self-signed Code Signing certificate once
# (README → "Permissions reset after every rebuild") and keep your grants with:
#
#   make install CODESIGN_IDENTITY="OpenWisper Dev"
#
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *)
        printf 'usage: bash scripts/make_app.sh [debug|release]\n' >&2
        exit 2
        ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRODUCT="OpenWisper"
APP="$ROOT/dist/$PRODUCT.app"
CONTENTS="$APP/Contents"
PLIST_SRC="$ROOT/Resources/Info.plist"
ICON_SRC="$ROOT/Resources/AppIcon.icns"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
    # Prefer the stable self-signed certificate the README walks through
    # ("OpenWisper Dev") whenever it exists: TCC ties grants to the code
    # signature, and an ad-hoc one changes every build. With the certificate,
    # plain `make install` keeps Input Monitoring / Accessibility grants
    # across rebuilds without the user remembering a variable.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"OpenWisper Dev"'; then
        CODESIGN_IDENTITY="OpenWisper Dev"
    else
        CODESIGN_IDENTITY="-"
    fi
fi

# ---------------------------------------------------------------------------
# Toolchain — same order as the Makefile: explicit $SWIFT, then a swift.org
# toolchain, then the Homebrew keg, then whatever is on PATH. (This machine's
# Command Line Tools ship a broken SwiftPM ManifestAPI, so bare `swift` is the
# last resort, not the first.)
# ---------------------------------------------------------------------------
detect_swift() {
    local candidate
    for candidate in \
        "$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" \
        "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" \
        "/opt/homebrew/opt/swift/bin/swift"
    do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf 'swift\n'
}

SWIFT="${SWIFT:-}"
[ -n "$SWIFT" ] || SWIFT="$(detect_swift)"
command -v "$SWIFT" >/dev/null 2>&1 || die "no usable swift toolchain (tried '$SWIFT') — set SWIFT=/path/to/swift"

# ---------------------------------------------------------------------------
# Locate the built binary
# ---------------------------------------------------------------------------
BIN_DIR="$("$SWIFT" build -c "$CONFIG" --show-bin-path)" \
    || die "could not determine the SwiftPM bin path for -c $CONFIG"
BINARY="$BIN_DIR/$PRODUCT"

[ -x "$BINARY" ] || die "$PRODUCT was not built for -c $CONFIG (expected $BINARY) — run 'make app', which builds first"
[ -f "$PLIST_SRC" ] || die "missing $PLIST_SRC"
[ -f "$ICON_SRC" ] || die "missing $ICON_SRC"

plutil -lint "$PLIST_SRC" >/dev/null || die "$PLIST_SRC is not a valid property list"

# A bundle whose CFBundleExecutable does not name a file in Contents/MacOS fails
# to launch with a useless Finder error, so catch the drift here instead.
EXEC_NAME="$(plutil -extract CFBundleExecutable raw -o - "$PLIST_SRC" 2>/dev/null)" \
    || die "$PLIST_SRC has no CFBundleExecutable key"
[ "$EXEC_NAME" = "$PRODUCT" ] \
    || die "Info.plist CFBundleExecutable is '$EXEC_NAME' but the built product is '$PRODUCT'"

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
say "Assembling $APP ($CONFIG)"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"

cp "$BINARY" "$CONTENTS/MacOS/$PRODUCT"
chmod 755 "$CONTENTS/MacOS/$PRODUCT"
cp "$PLIST_SRC" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

mkdir -p "$CONTENTS/Resources"
cp "$ICON_SRC" "$CONTENTS/Resources/AppIcon.icns"

# SwiftPM resource bundles: a target that declares resources builds a
# <Package>_<Target>.bundle next to the binary (MainWindowUI's brand image
# lives in one), and the app has to carry them or those lookups come up empty
# at runtime.
while IFS= read -r -d '' bundle; do
    ditto "$bundle" "$CONTENTS/Resources/$(basename "$bundle")"
done < <(find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -print0)

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------
say "Signing with identity: $CODESIGN_IDENTITY"
codesign --force --sign "$CODESIGN_IDENTITY" "$APP" \
    || die "codesign failed for identity '$CODESIGN_IDENTITY' (list yours with: security find-identity -v -p codesigning)"
codesign --verify --strict "$APP" || die "the signature did not verify"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
size="$(du -h "$CONTENTS/MacOS/$PRODUCT" 2>/dev/null | awk '{print $1}')" || size='?'
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$CONTENTS/Info.plist" 2>/dev/null)" || bundle_id='?'
version="$(plutil -extract CFBundleShortVersionString raw -o - "$CONTENTS/Info.plist" 2>/dev/null)" || version='?'

say "Built $PRODUCT.app"
printf '    bundle       %s\n' "$APP" >&2
printf '    identifier   %s (v%s)\n' "$bundle_id" "$version" >&2
printf '    executable   %s (%s)\n' "$size" "$CONFIG" >&2
printf '    signature    %s\n' "$CODESIGN_IDENTITY" >&2

if [ "$CODESIGN_IDENTITY" = "-" ]; then
    cat >&2 <<'EOF'

    Note: this is an ad-hoc signature. macOS ties TCC grants to the code
    signature, so Input Monitoring and Accessibility must be granted again after
    every rebuild. To keep them, create a self-signed Code Signing certificate
    named "OpenWisper Dev" (see the README) and build with:

        make install CODESIGN_IDENTITY="OpenWisper Dev"
EOF
fi

echo "$APP"
