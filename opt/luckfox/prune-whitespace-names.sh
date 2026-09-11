#!/usr/bin/env bash
#
# prune-whitespace-names.sh <ROOTFS_DIR>
#
# Remove whitespace-named paths from the Python site-packages trees. Shared by
# the GitHub Actions build and both local Docker builds (os-build.sh /
# build-local.sh) -- change this script, never one caller.
#
# WHY THIS EXISTS: mkfs-ext4-deterministic.sh populates the image by driving
# `debugfs` from a `find | sort` manifest, and debugfs commands (`write`, `ln`,
# `mkdir`) are space-delimited with no quoting we can rely on. A path containing
# whitespace would therefore be silently mis-parsed into the wrong file, so the
# census pass rejects one outright:
#
#     mkfs-ext4-deterministic: unsupported filename (whitespace): <path>
#
# That guard is correct and stays. It is a hard build failure, though, and it
# fired on every ext4 target (SD_CARD and EMMC — SPI_NAND is UBIFS and never
# reaches it) as soon as the CI image began shipping a setuptools that vendors
# jaraco.text, which carries a sample-text file with a space in its name:
#
#     usr/lib/python3.12/site-packages/setuptools/_vendor/jaraco/text/Lorem ipsum.txt
#
# Rather than teach the deterministic populate path to quote — where getting it
# wrong corrupts an image instead of failing it — drop the offending files. A
# name with a space in it is never importable Python, so nothing under
# site-packages that matches is code; in practice these are vendored fixtures
# and sample data that have no business on an air-gapped signer anyway.
#
# NOT gated on the build variant. optimize-nondev.sh already prunes tests/ and
# *.dist-info from site-packages, which would have been the natural home — but
# it runs on non-dev only, and CI builds dev, so the break would have persisted
# exactly where it was being observed.
#
# Every removal is logged by name so the build log records precisely what left
# the image. Anything whitespace-named OUTSIDE site-packages is reported but
# deliberately NOT deleted: that would be an unknown case, and guessing at it is
# worse than letting mkfs-ext4-deterministic.sh fail with the name in hand.

set -eu

ROOTFS="${1:-}"
if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "prune-whitespace-names: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [whitespace] $*"; }

echo "=== Pruning whitespace-named paths from site-packages ==="

removed=0

# -depth so a whitespace-named directory's contents are removed before it is.
# NUL-delimited throughout: the whole point here is names the shell would split.
for base in "$ROOTFS"/usr/lib/python*/site-packages; do
    [ -d "$base" ] || continue
    while IFS= read -r -d '' path; do
        rel="${path#"$ROOTFS"}"
        if rm -rf -- "$path" 2>/dev/null; then
            log "removed ${rel}"
            removed=$((removed + 1))
        else
            echo "prune-whitespace-names: ERROR -- could not remove ${rel}" >&2
            exit 1
        fi
    done < <(find "$base" -depth -name '*[[:space:]]*' -print0)
done

if [ "$removed" -eq 0 ]; then
    log "no whitespace-named paths under site-packages"
else
    log "removed $removed whitespace-named path(s)"
fi

# Report-only sweep of the rest of the rootfs. mkfs-ext4-deterministic.sh errors
# on the FIRST offender it meets, so without this a second one costs another
# full build to discover. Listing them all here turns that into one iteration.
leftover=0
while IFS= read -r -d '' path; do
    [ "$leftover" -eq 0 ] && log "WARNING: whitespace-named paths remain outside site-packages:"
    log "  ${path#"$ROOTFS"}"
    leftover=$((leftover + 1))
done < <(find "$ROOTFS" -path '*/site-packages' -prune -o -name '*[[:space:]]*' -print0)

if [ "$leftover" -ne 0 ]; then
    log "WARNING: $leftover path(s) above will fail mkfs-ext4-deterministic.sh on ext4 targets"
    log "WARNING: (SPI_NAND is UBIFS and is unaffected). Not removed automatically —"
    log "WARNING: decide each case rather than guessing."
fi

echo "=== Whitespace-name prune done ==="
