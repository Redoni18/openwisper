#!/usr/bin/env bash
#
# make_dmg.sh — package dist/OpenWisper.app into a drag-to-install DMG.
#
#   bash scripts/make_dmg.sh
#
# Requires dist/OpenWisper.app to already exist (run `make app` first). This
# script does NOT build.
#
# Produces:
#   dist/OpenWisper-<version>.dmg   versioned disk image
#   dist/OpenWisper.dmg             stable name (releases/latest/download URL)
#
set -euo pipefail

say() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PRODUCT="OpenWisper"
APP="$ROOT/dist/$PRODUCT.app"
STAGING="$ROOT/dist/dmg-staging"
README_NAME="READ ME FIRST.txt"

[ -d "$APP" ] || die "missing $APP — run 'make app' first"

say "Verifying code signature"
codesign --verify --strict "$APP" || die "codesign --verify --strict failed for $APP — re-run 'make app'"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" \
    || die "could not read CFBundleShortVersionString from $APP/Contents/Info.plist"
[ -n "$VERSION" ] || die "CFBundleShortVersionString is empty"

DMG_VERSIONED="$ROOT/dist/$PRODUCT-$VERSION.dmg"
DMG_STABLE="$ROOT/dist/$PRODUCT.dmg"

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------
say "Staging DMG contents"
rm -rf "$STAGING"
mkdir -p "$STAGING"

ditto "$APP" "$STAGING/$PRODUCT.app"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/$README_NAME" <<'EOF'
Welcome to OpenWisper!

Install
1. Drag OpenWisper into the Applications folder (the shortcut next to it).
2. Open OpenWisper from Applications.

First launch tip
Because OpenWisper is a free app that is not registered with Apple, the very
first time you open it your Mac may say it “can’t be opened.” That is expected
and safe — you’re not doing anything wrong.

• On macOS 15 (Sequoia) and later: open System Settings → Privacy & Security,
  scroll down, and click “Open Anyway” next to OpenWisper, then confirm.
• On macOS 14 (Sonoma): right-click (or Control-click) OpenWisper in
  Applications and choose Open, then click Open in the dialog.

After that, it opens normally forever.

Where to find it
Look for the small microphone icon in the menu bar at the top of the screen.
OpenWisper has no Dock icon — that’s intentional.
EOF

# ---------------------------------------------------------------------------
# Create DMG
# ---------------------------------------------------------------------------
say "Creating $DMG_VERSIONED"
hdiutil create \
    -volname "OpenWisper" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_VERSIONED" \
    || die "hdiutil create failed"

cp "$DMG_VERSIONED" "$DMG_STABLE"

say "Verifying $DMG_STABLE"
hdiutil verify "$DMG_STABLE" || die "hdiutil verify failed for $DMG_STABLE"

say "Cleaning staging"
rm -rf "$STAGING"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
size_v="$(du -h "$DMG_VERSIONED" 2>/dev/null | awk '{print $1}')" || size_v='?'
size_s="$(du -h "$DMG_STABLE" 2>/dev/null | awk '{print $1}')" || size_s='?'

say "Built $PRODUCT DMG"
printf '    versioned    %s (%s)\n' "$DMG_VERSIONED" "$size_v" >&2
printf '    stable       %s (%s)\n' "$DMG_STABLE" "$size_s" >&2
printf '    version      %s\n' "$VERSION" >&2

echo "$DMG_VERSIONED"
