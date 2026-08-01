#!/usr/bin/env bash
#
# fetch_whisper.sh — vendor whisper.cpp and build its static libraries.
#
# Produces:
#   Vendor/whisper.cpp/                              shallow clone at $WHISPER_TAG
#   Vendor/whisper.cpp/build/                        cmake build tree (incremental)
#   Vendor/whisper-install/lib/libwhisper_merged.a   libwhisper.a + every libggml*.a
#   Vendor/whisper-install/include/*.h               public headers
#   Sources/CWhisper/include/*.h                     the copies SPM compiles against
#   Resources/samples/jfk.wav                        smoke-test audio
#
# Idempotent: re-running reuses the clone and does an incremental cmake build.
# `make distclean` (rm -rf Vendor) forces a full refetch.
#
# Env knobs:
#   FORCE_METAL=1   retry the Metal build even if a previous run fell back to CPU
#   JOBS=N          parallel build jobs (default: hw.ncpu)
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned release.
#
# v1.9.1 was the newest release tag on 2026-07-31, per
#   git ls-remote --tags https://github.com/ggml-org/whisper.cpp
# (the repo moved from ggerganov/ to ggml-org/; either URL redirects).
#
# Bump deliberately and re-run this script: the set of ggml headers and the
# names of the produced .a archives both change between releases.
# ---------------------------------------------------------------------------
WHISPER_TAG="v1.9.1"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp"

# Match the SwiftPM platform floor (Package.swift: .macOS(.v14)) so the linker
# does not warn about objects built for a newer OS than the Swift code.
MACOS_DEPLOYMENT_TARGET="14.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Vendor/whisper.cpp"
BUILD="$SRC/build"
INSTALL="$ROOT/Vendor/whisper-install"
LIBDIR="$INSTALL/lib"
INCDIR="$INSTALL/include"
SPM_INCDIR="$ROOT/Sources/CWhisper/include"
SAMPLES="$ROOT/Resources/samples"
STAMP="$INSTALL/.build-info"

CMAKE="${CMAKE:-/opt/homebrew/bin/cmake}"
command -v "$CMAKE" >/dev/null 2>&1 || CMAKE="cmake"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git not found"
command -v "$CMAKE" >/dev/null 2>&1 || die "cmake not found (brew install cmake)"
[ -x /usr/bin/libtool ] || die "/usr/bin/libtool not found (Command Line Tools)"

# ---------------------------------------------------------------------------
# 1. Clone (or reuse) the pinned tag.
# ---------------------------------------------------------------------------
current_tag() {
    git -C "$SRC" describe --tags --exact-match HEAD 2>/dev/null || true
}

if [ -d "$SRC/.git" ] && [ "$(current_tag)" = "$WHISPER_TAG" ]; then
    say "whisper.cpp $WHISPER_TAG already present at Vendor/whisper.cpp"
else
    if [ -e "$SRC" ]; then
        say "Vendor/whisper.cpp is missing or at the wrong tag — refetching"
        rm -rf "$SRC"
    fi
    say "Cloning $WHISPER_REPO @ $WHISPER_TAG"
    mkdir -p "$ROOT/Vendor"
    git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$SRC"
    rm -rf "$BUILD"   # a new checkout invalidates any previous build tree
fi

# ---------------------------------------------------------------------------
# 2. Configure + build the static libraries.
#
# GGML_METAL_EMBED_LIBRARY bakes the Metal *source* into the archive so ggml
# compiles it at runtime — this host has Command Line Tools only, with no
# Metal shader compiler, so a precompiled .metallib is not an option.
# ---------------------------------------------------------------------------
WANT_METAL=ON
if [ "${FORCE_METAL:-0}" != "1" ] && [ -f "$STAMP" ] && grep -q '^metal=OFF$' "$STAMP"; then
    # A previous run already proved Metal does not configure/build here.
    WANT_METAL=OFF
    say "Previous run fell back to CPU — building with GGML_METAL=OFF (FORCE_METAL=1 to retry)"
fi

# ggml probes the ARM feature sets (dotprod / i8mm / sve / sme) with cmake's
# check_cxx_source_runs — it *executes* an instruction from each set. On a part
# that lacks one (no Apple Silicon chip implements SVE) the probe binary takes
# SIGILL, and if the system crash reporter is busy that probe can wedge for
# minutes with no way to reap it. The kernel already knows the answer, so
# pre-seed cmake's result cache for anything sysctl reports as missing and let
# cmake probe the rest — probing also proves the *compiler* supports the flag,
# which sysctl cannot tell us.
ARM_FEATURE_ARGS=()
if [ "$(uname -m)" = "arm64" ]; then
    seed_absent_feature() {  # $1 = ggml tag, $2 = sysctl leaf
        if [ "$(sysctl -n "hw.optional.arm.$2" 2>/dev/null || echo 0)" != "1" ]; then
            ARM_FEATURE_ARGS+=("-DGGML_MACHINE_SUPPORTS_$1=0")
        fi
    }
    seed_absent_feature dotprod FEAT_DotProd
    seed_absent_feature i8mm    FEAT_I8MM
    seed_absent_feature sve     FEAT_SVE
    seed_absent_feature sme     FEAT_SME
    [ "${#ARM_FEATURE_ARGS[@]}" -eq 0 ] \
        || say "CPU lacks: ${ARM_FEATURE_ARGS[*]//-DGGML_MACHINE_SUPPORTS_/}"
fi

configure_and_build() {
    local metal="$1"
    "$CMAKE" -S "$SRC" -B "$BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL="$metal" \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        ${ARM_FEATURE_ARGS[@]+"${ARM_FEATURE_ARGS[@]}"} \
        && "$CMAKE" --build "$BUILD" --config Release -j "$JOBS"
}

METAL="$WANT_METAL"
if ! configure_and_build "$WANT_METAL"; then
    [ "$WANT_METAL" = "ON" ] || die "whisper.cpp build failed (Metal already disabled)"
    say "Metal build failed — falling back to CPU + Accelerate (GGML_METAL=OFF)"
    rm -rf "$BUILD"
    METAL=OFF
    configure_and_build OFF || die "whisper.cpp build failed even with GGML_METAL=OFF"
fi

# ---------------------------------------------------------------------------
# 3. Merge every produced archive into one static library.
#    Archive names drift between releases (libggml / libggml-base / libggml-cpu
#    / libggml-blas / libggml-metal ...), so glob rather than enumerate.
# ---------------------------------------------------------------------------
ARCHIVES=()
while IFS= read -r a; do
    [ -n "$a" ] && ARCHIVES+=("$a")
done < <(find "$BUILD" -type f \( -name 'libwhisper*.a' -o -name 'libggml*.a' \) | sort)

[ "${#ARCHIVES[@]}" -gt 0 ] || die "no .a archives found under $BUILD"

mkdir -p "$LIBDIR" "$INCDIR" "$SPM_INCDIR" "$SAMPLES"
MERGED="$LIBDIR/libwhisper_merged.a"
rm -f "$MERGED"
say "Merging ${#ARCHIVES[@]} archive(s) into ${MERGED#"$ROOT"/}"
/usr/bin/libtool -static -no_warning_for_no_symbols -o "$MERGED" "${ARCHIVES[@]}"

# ---------------------------------------------------------------------------
# 4. Copy the public headers.
#
# Starts at whisper.h and follows quoted #includes transitively, so we pick up
# exactly the ggml headers this release actually needs and nothing else.
# The Sources/CWhisper/include copies are what SPM compiles against; they are
# generated here and should not be hand-edited (CWhisper.h is ours and stays).
# ---------------------------------------------------------------------------
HEADER_DIRS="$SRC/include $SRC/ggml/include"

# Drop headers from a previous tag, but keep our umbrella header.
find "$INCDIR" -maxdepth 1 -name '*.h' -delete 2>/dev/null || true
find "$SPM_INCDIR" -maxdepth 1 -name '*.h' ! -name 'CWhisper.h' -delete 2>/dev/null || true

queue="whisper.h"
seen=""
copied=""
while [ -n "$queue" ]; do
    header="${queue%% *}"
    if [ "$queue" = "$header" ]; then queue=""; else queue="${queue#* }"; fi
    case " $seen " in *" $header "*) continue ;; esac
    seen="$seen $header"

    found=""
    for d in $HEADER_DIRS; do
        if [ -f "$d/$header" ]; then found="$d/$header"; break; fi
    done
    if [ -z "$found" ]; then
        # System / compiler headers are included with <> so they never land here;
        # anything else missing is a genuine packaging problem.
        die "public header '$header' not found under: $HEADER_DIRS"
    fi

    cp "$found" "$INCDIR/$header"
    cp "$found" "$SPM_INCDIR/$header"
    copied="$copied $header"

    deps="$(sed -n 's|^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*|\1|p' "$found" || true)"
    for dep in $deps; do queue="$queue $(basename "$dep")"; done
done

# ---------------------------------------------------------------------------
# 5. Sample audio for the smoke test.
# ---------------------------------------------------------------------------
if [ -f "$SRC/samples/jfk.wav" ]; then
    cp "$SRC/samples/jfk.wav" "$SAMPLES/jfk.wav"
else
    say "warning: samples/jfk.wav missing from the checkout — whisper-smoke needs an explicit wav path"
fi

# ---------------------------------------------------------------------------
# 6. Stamp + summary.
# ---------------------------------------------------------------------------
{
    echo "tag=$WHISPER_TAG"
    echo "metal=$METAL"
    echo "built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$STAMP"

lib_size="$(du -h "$MERGED" | cut -f1 | tr -d ' ')"
echo
say "whisper.cpp $WHISPER_TAG ready"
echo "    Metal GPU     : $METAL$([ "$METAL" = ON ] && echo ' (library source embedded, compiled at runtime)' || echo ' (CPU + Accelerate)')"
echo "    merged library: ${MERGED#"$ROOT"/}  ($lib_size)"
echo "    archives      : ${#ARCHIVES[@]}"
for a in "${ARCHIVES[@]}"; do echo "        - ${a#"$BUILD"/}"; done
echo "    headers       : (copied to Vendor/whisper-install/include and Sources/CWhisper/include)"
for h in $copied; do echo "        - $h"; done
echo "    sample audio  : Resources/samples/jfk.wav"
