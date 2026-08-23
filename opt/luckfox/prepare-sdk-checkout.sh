#!/usr/bin/env bash
#
# prepare-sdk-checkout.sh <PARENT_DIR> [REPO_URL] [REF]
#
# Leave $PARENT_DIR/luckfox-pico checked out at the pinned SDK revision, in a
# PRISTINE state, whether or not a checkout is already sitting there. Shared by
# CI (build-luckfox.yml) and both local builds (os-build.sh / build-local.sh) --
# change this script, never one caller. Sibling of prepare-app-checkout.sh,
# which does the same job for the app.
#
# Two separate problems, both of which broke reproducibility:
#
# 1. THE REF WAS NOT PINNED. Every caller did
#        git clone <url> --depth=1 --single-branch luckfox-pico
#    i.e. whatever the default branch pointed at that day. Two builds of the
#    same seedsigner-os commit a week apart could use different kernel sources,
#    a different Buildroot version and a different prebuilt toolchain, with
#    nothing recorded anywhere saying which. The pin now lives in SDK_COMMIT.
#
# 2. THE TREE WAS NOT PRISTINE. The build patches the SDK IN PLACE -- board
#    configs, DTS files, kernel defconfigs, Buildroot's rustc/rust-bin/rust.mk.
#    os-build.sh keeps the SDK in the Docker volume 'seedsigner-repos', which
#    outlives the build, and only ever did `if [[ ! -d luckfox-pico ]]`. So the
#    second and every later local build started from a tree the previous build
#    had already edited. Most patches are grep-guarded and idempotent; not all
#    are, and "mostly idempotent" is not a reproducibility argument. CI, which
#    clones fresh into a new runner every time, never saw this -- so the local
#    build could not reproduce CI, and could not reproduce ITSELF either.
#
# Hence: fetch the pinned commit (cheap -- only new objects), then hard-reset
# and clean, which restores the pristine tree without re-downloading ~37 GB.
#
# `git clean -ffdx` also removes build OUTPUT (output/, the unpacked Buildroot
# tree, host-rust). That is deliberate: stale output is exactly what makes an
# incremental rebuild diverge from a clean one. The expensive part -- the Rust
# toolchain -- is cached OUTSIDE the SDK tree by rust-toolchain-cache.sh, so a
# clean build does not mean recompiling LLVM.
#
# Escape hatches, for SDK development rather than for building an image:
#   LUCKFOX_COMMIT=<sha>            build a different SDK revision
#   LUCKFOX_BRANCH=<branch|tag>     build the tip of a branch (NOT pinned)
#   SEEDSIGNER_KEEP_SDK_CHECKOUT=1  reuse the tree as-is, warn, never clean.
#                                   The resulting image is NOT reproducible.

set -eu

PARENT_DIR="${1:-}"
REPO_URL="${2:-${LUCKFOX_REPO_URL:-https://github.com/3rdIteration/luckfox-pico.git}}"
REF_ARG="${3:-}"

if [ -z "$PARENT_DIR" ]; then
    echo "usage: prepare-sdk-checkout.sh <PARENT_DIR> [REPO_URL] [REF]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$PARENT_DIR/luckfox-pico"

# Resolve the pin: explicit argument > LUCKFOX_COMMIT > LUCKFOX_BRANCH > SDK_COMMIT.
read_pin_file() {
    local f="$SCRIPT_DIR/SDK_COMMIT"
    [ -f "$f" ] || return 1
    grep -vE '^[[:space:]]*(#|$)' "$f" | head -1 | tr -d '[:space:]'
}

PINNED=0
if [ -n "$REF_ARG" ]; then
    REF="$REF_ARG"
elif [ -n "${LUCKFOX_COMMIT:-}" ]; then
    REF="$LUCKFOX_COMMIT"
elif [ -n "${LUCKFOX_BRANCH:-}" ]; then
    REF="$LUCKFOX_BRANCH"
else
    REF="$(read_pin_file || true)"
    PINNED=1
    if [ -z "$REF" ]; then
        echo "prepare-sdk-checkout: no SDK revision pinned." >&2
        echo "  Expected a sha in $SCRIPT_DIR/SDK_COMMIT, or LUCKFOX_COMMIT/LUCKFOX_BRANCH set." >&2
        echo "  Building an unpinned SDK is what this script exists to prevent." >&2
        exit 1
    fi
fi

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{7,40}$'; }

checkout_desc() {
    local sha ref
    sha="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    ref="$(git -C "$DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [ -z "$ref" ]; then
        ref="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        [ "$ref" = "HEAD" ] && ref="detached"
    fi
    echo "ref=$ref commit=$sha"
}

echo "LuckFox SDK: $REPO_URL @ $REF$([ "$PINNED" = 1 ] && echo ' (pinned via SDK_COMMIT)')"

# --- no checkout yet: clone -------------------------------------------------
if [ ! -d "$DIR/.git" ]; then
    # A stale non-git directory (an interrupted clone) would make every git
    # command below fail with something unhelpful. Clear it first.
    [ -e "$DIR" ] && rm -rf "$DIR"

    if is_sha "$REF"; then
        # `git clone -b` does NOT accept a commit, so clone the default branch
        # shallow and then fetch exactly the pinned object.
        git clone "$REPO_URL" --depth=1 --single-branch "$DIR"
        git -C "$DIR" fetch --depth=1 origin "$REF"
        git -C "$DIR" checkout --detach FETCH_HEAD
    else
        git clone "$REPO_URL" --depth=1 -b "$REF" --single-branch "$DIR"
    fi
    echo "✅ luckfox-pico cloned ($(checkout_desc))"
    exit 0
fi

# --- checkout exists --------------------------------------------------------
if [ "${SEEDSIGNER_KEEP_SDK_CHECKOUT:-0}" = "1" ]; then
    echo "⚠️  SEEDSIGNER_KEEP_SDK_CHECKOUT=1 — keeping $(checkout_desc) as-is." >&2
    echo "⚠️  In-place patches from a previous build are NOT reverted and build" >&2
    echo "⚠️  output is NOT cleaned. This image will NOT be reproducible." >&2
    exit 0
fi

HAVE="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo none)"

# Make sure the target object is present locally. A shallow single-branch clone
# will not have it after the pin moves, so fetch it by name; tolerate failure so
# an offline rebuild of an already-correct tree still works.
if is_sha "$REF"; then
    if ! git -C "$DIR" cat-file -e "${REF}^{commit}" 2>/dev/null; then
        echo "Fetching pinned SDK commit $REF ..."
        git -C "$DIR" fetch --depth=1 origin "$REF" || {
            echo "prepare-sdk-checkout: cannot fetch $REF from $REPO_URL" >&2
            echo "  existing checkout is $(checkout_desc); refusing to build the wrong SDK." >&2
            exit 1
        }
    fi
    TARGET="$REF"
else
    git -C "$DIR" fetch --depth=1 origin "$REF" || {
        echo "prepare-sdk-checkout: cannot fetch '$REF' from $REPO_URL" >&2
        echo "  existing checkout is $(checkout_desc); refusing to build the wrong SDK." >&2
        exit 1
    }
    TARGET="FETCH_HEAD"
fi

# Always reset+clean, even when HEAD already matches: matching HEAD says nothing
# about the working tree, and the previous build's in-place edits live exactly
# there. This is the step that makes a second local build equal the first.
if [ "$HAVE" != "$REF" ]; then
    echo "↻ SDK checkout is $(checkout_desc), moving to $REF"
fi
git -C "$DIR" reset --hard "$TARGET"
echo "Cleaning SDK tree (reverting previous build's in-place patches and output)..."
git -C "$DIR" clean -ffdx
echo "✅ luckfox-pico pristine at $(checkout_desc)"
