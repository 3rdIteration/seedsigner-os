#!/usr/bin/env bash
#
# resolve-buildroot-dir.sh <LUCKFOX_PICO_DIR>
#
# Print the path of the buildroot source tree the SDK actually unpacked. Shared
# by the GitHub Actions build and both local Docker builds — change this script,
# never one caller. Run AFTER `make buildroot_create`.
#
# WHY: the SDK ships buildroot as a tarball whose version is its own business
# and changes between SDK revisions. os-build.sh hard-coded
# `buildroot-2023.02.6` while the SDK had moved to buildroot-2024.11.4, so every
# Docker build died with:
#
#   [ERROR] Buildroot directory not found after buildroot_create:
#           .../sysdrv/source/buildroot/buildroot-2023.02.6
#
# CI got this right by discovering the directory, which is exactly why the
# breakage was invisible until someone ran the Docker path. Pinning a version
# here buys nothing -- the SDK revision already determines it -- and costs a
# hard failure on every bump.
#
# `sort | tail -1` picks the highest version when several are present, matching
# what CI has always done.

set -eu

LUCKFOX_DIR="${1:-}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "resolve-buildroot-dir: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

BR_ROOT="$LUCKFOX_DIR/sysdrv/source/buildroot"
BUILDROOT_DIR="$(find "$BR_ROOT" -maxdepth 1 -type d -name 'buildroot-*' 2>/dev/null | sort | tail -n 1)"

if [ -z "$BUILDROOT_DIR" ] || [ ! -d "$BUILDROOT_DIR" ]; then
    echo "resolve-buildroot-dir: no buildroot-* directory under $BR_ROOT" >&2
    echo "  (has 'make buildroot_create' run yet?)" >&2
    ls -la "$BR_ROOT" >&2 2>/dev/null || true
    exit 1
fi

printf '%s\n' "$BUILDROOT_DIR"
