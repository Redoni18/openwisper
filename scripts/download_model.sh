#!/usr/bin/env bash
#
# download_model.sh — fetch a ggml whisper model into the app's models directory.
#
#   bash scripts/download_model.sh [size]
#
# size: tiny.en | base.en | small.en | small | medium.en | medium | large-v3-turbo
#       (default: small.en — the app's Defaults.defaultModelFile)
#
# Idempotent: an existing, plausibly-sized file is left alone. Prints the final
# absolute path on stdout as the last line, so callers can capture it.
set -euo pipefail

SIZE="${1:-small.en}"

case "$SIZE" in
    tiny.en|base.en|small.en|small|medium.en|medium|large-v3-turbo) ;;
    *)
        cat >&2 <<EOF
error: unknown model size '$SIZE'
usage: bash scripts/download_model.sh <tiny.en|base.en|small.en|small|medium.en|medium|large-v3-turbo>
EOF
        exit 2
        ;;
esac

FILE="ggml-$SIZE.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$FILE"
DEST_DIR="$HOME/Library/Application Support/OpenWisper/models"
DEST="$DEST_DIR/$FILE"
TMP="$DEST.part"

# A truncated/HTML error page is the common failure mode; every real ggml model
# is far larger than this.
MIN_BYTES=$((10 * 1024 * 1024))

say() { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

file_size() { stat -f%z "$1" 2>/dev/null || echo 0; }

mkdir -p "$DEST_DIR"

if [ -f "$DEST" ]; then
    have="$(file_size "$DEST")"
    if [ "$have" -ge "$MIN_BYTES" ]; then
        say "$FILE already present ($((have / 1024 / 1024)) MB) — skipping download"
        echo "$DEST"
        exit 0
    fi
    say "$FILE exists but is only $have bytes — re-downloading"
    rm -f "$DEST"
fi

# This host's network has flaky HTTP/2 to some CDNs; force HTTP/1.1.
CURL_OUTPUT=(--silent --show-error)
[ -t 2 ] && CURL_OUTPUT=(--progress-bar)

say "Downloading $FILE from huggingface.co"
rm -f "$TMP"
curl "${CURL_OUTPUT[@]}" \
    --fail --location --http1.1 \
    --retry 5 --retry-delay 2 --retry-connrefused \
    --connect-timeout 20 \
    --output "$TMP" \
    "$URL" || die "download failed: $URL"

got="$(file_size "$TMP")"
if [ "$got" -lt "$MIN_BYTES" ]; then
    rm -f "$TMP"
    die "downloaded file is only $got bytes (expected > $((MIN_BYTES / 1024 / 1024)) MB) — the URL may have moved"
fi

mv "$TMP" "$DEST"
say "Saved $((got / 1024 / 1024)) MB"
echo "$DEST"
