#!/bin/bash
# Launch a local Luckfox Pico build (all 5 combos) reproducing one of the two CI lineages.
#
# Usage: launch-luckfox.sh <tag> [branch]
#   no branch = lineage C (app-repo dispatch via workflow_call): CI checks out the
#               tag DETACHED, so /etc/seedsigner-os-release records BRANCH=HEAD.
#               The checkout must be detached at the tag's commit.
#   branch    = lineage D (OS-repo direct dispatch on that branch): the checkout
#               must be ON that branch with HEAD == the tag's commit.
#
# Builds non-dev + secure-boot signed (SEEDSIGNER_FIT_SIGNATURE=1), matching the
# release defaults: usb/debug-network/uart2/rootfs all "auto", harden-adb on,
# boot-log off, testing-build off — i.e. no extra flags needed.
#
# Provenance is resolved from this checkout by opt/luckfox/build.sh (REPO from the
# origin remote canonicalised to https://github.com/owner/repo; BRANCH via
# rev-parse --abbrev-ref HEAD; COMMIT + DATE from git) — which is exactly CI's
# expressions, so identical checkout state gives byte-identical images.
#
# BLOCKS for hours (five sequential builds in one container). Run it inside a
# long-lived session (a foreground shell that stays open); the docker run it
# performs has no detached mode of its own.
set -euo pipefail

TAG="${1:?usage: launch-luckfox.sh <tag> [branch]}"
BRANCH="${2:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED="$(git -C "$REPO_DIR" rev-parse "${TAG}^{commit}" 2>/dev/null || true)"
if [ -z "$EXPECTED" ]; then
    echo "tag $TAG not found in $REPO_DIR (fetch it first: git fetch origin refs/tags/$TAG)" >&2
    exit 1
fi

HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
ON_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"

if [ -z "$BRANCH" ]; then
    # Lineage C: detached at the tag.
    if [ "$ON_BRANCH" != "HEAD" ] || [ "$HEAD_SHA" != "$EXPECTED" ]; then
        echo "lineage C needs a DETACHED checkout at $EXPECTED; currently on '$ON_BRANCH' at ${HEAD_SHA:0:12}" >&2
        echo "run: git -C \"$REPO_DIR\" checkout --detach $TAG && git -C \"$REPO_DIR\" submodule update" >&2
        exit 1
    fi
else
    # Lineage D: on the dispatch branch, at the tag's commit.
    if [ "$ON_BRANCH" != "$BRANCH" ] || [ "$HEAD_SHA" != "$EXPECTED" ]; then
        echo "lineage D needs branch '$BRANCH' at $EXPECTED; currently on '$ON_BRANCH' at ${HEAD_SHA:0:12}" >&2
        exit 1
    fi
fi

# origin must be the github.com remote CI records (canonicalised by build.sh).
ORIGIN="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
case "$ORIGIN" in
    https://github.com/*|git@github.com:*) ;;
    *) echo "origin is '$ORIGIN' — provenance REPO would not match CI (need a github.com remote named 'origin')" >&2; exit 1 ;;
esac

# The app repo URL lands verbatim in /etc/seedsigner-os-release (APP_REPO), so it
# must match what CI passes for this lineage or every artifact desyncs: the file
# changes rootfs.img, whose minisign rides in boot.img's initramfs, which moves
# the FIT hash + signature nodes. Lineage C's caller (app-repo build-luckfox.yml)
# passes it WITHOUT the .git suffix; lineage D uses the OS workflow default WITH it.
if [ -z "$BRANCH" ]; then
    export SEEDSIGNER_REPO_URL="${SEEDSIGNER_REPO_URL:-https://github.com/3rdIteration/seedsigner}"
else
    export SEEDSIGNER_REPO_URL="${SEEDSIGNER_REPO_URL:-https://github.com/3rdIteration/seedsigner.git}"
fi

OUT_DIR="${SS_LUCKFOX_OUT:-$REPO_DIR/luckfox-build-output-${TAG//\+/_}}"
mkdir -p "$OUT_DIR"

echo "== launching Luckfox build: tag=$TAG lineage=${BRANCH:+D($BRANCH)}${BRANCH:-C} variant=non-dev signed=yes app_repo=$SEEDSIGNER_REPO_URL"
echo "   output -> $OUT_DIR  (five sequential builds; expect hours)"
cd "$REPO_DIR/opt/luckfox"
SEEDSIGNER_FIT_SIGNATURE=1 ./build.sh build \
    --all \
    --variant non-dev \
    --seedsigner-ref "$TAG" \
    --output "$OUT_DIR"
