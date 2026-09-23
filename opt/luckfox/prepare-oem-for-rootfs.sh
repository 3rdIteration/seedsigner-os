#!/usr/bin/env bash
#
# prepare-oem-for-rootfs.sh [OEM_DIR]
#
# Prepare the staged oem tree to be folded into the read-only signed rootfs.
# OEM_DIR defaults to $RK_PROJECT_PACKAGE_OEM_DIR, which the SDK exports, so the
# script can be invoked from the SDK's pre-build-OEM hook with no arguments.
#
# WHY THIS RUNS FROM THAT HOOK: the oem tree is assembled by the SDK's
# __PACKAGE_OEM only during `./build.sh firmware`. The SDK's
# __RUN_PRE_BUILD_OEM_SCRIPT hook runs after __PACKAGE_OEM and before the tree is
# copied into the rootfs staging directory / packed — the one window where the
# staged oem tree exists and is still editable. This script runs right after
# prune-oem-iqfiles.sh from that same hook (see patch-oem-pre-hook.sh).
#
# WHAT IT DOES — the oem partition no longer exists. apply-partition-layout.sh
# sets RK_BUILD_APP_TO_OEM_PARTITION=n, so build.sh's build_firmware() folds
# $RK_PROJECT_PACKAGE_OEM_DIR into <rootfs>/oem before packing the squashfs (see
# the long note in apply-partition-layout.sh). The iqfiles and .ko are then
# covered by the rootfs signature. Nothing is copied here — the SDK owns the
# fold; this script only fixes the pieces of the oem tree that assumed they lived
# on a WRITABLE /oem.
#
# CORE DUMPS. The SDK's RkLunch.sh (run as root from /oem/usr/bin every boot)
# sets:
#
#     echo "/data/core-%p-%e" >/proc/sys/kernel/core_pattern
#
# /data resolves onto the oem storage, so on the old writable oem partition a
# crashing process could drop a core there. On the folded image /oem is a
# read-only squashfs, and a core dump is a verbatim copy of a root process's
# memory (the app runs as root holding seed material), so we point it at /tmp —
# a tmpfs, wiped at reboot, never written to flash. (The kernel strip on non-dev
# already disables coredumps entirely; this is defence in depth and stops the
# kernel from trying to write to a read-only mount.)
#
# Env:
#   CORE_PATTERN - the replacement pattern (default: /tmp/core-%p-%e)

set -u

OEM_DIR="${1:-${RK_PROJECT_PACKAGE_OEM_DIR:-}}"
CORE_PATTERN="${CORE_PATTERN:-/tmp/core-%p-%e}"

log()  { echo "  [oemroot] $*"; }
skip() { echo "  [oemroot] (skip) $*"; }

if [ -z "$OEM_DIR" ]; then
    skip "no OEM_DIR given and RK_PROJECT_PACKAGE_OEM_DIR unset - nothing to prepare"
    exit 0
fi
if [ ! -d "$OEM_DIR" ]; then
    echo "  [oemroot] ERROR: OEM_DIR '$OEM_DIR' is not a directory" >&2
    exit 1
fi

RKLUNCH="$OEM_DIR/usr/bin/RkLunch.sh"

# RkLunch.sh is the SDK's camera launcher and is always staged with the oem
# resources. Its absence means the oem layout changed and the camera would not
# come up, so fail loudly rather than fold a broken tree.
if [ ! -f "$RKLUNCH" ]; then
    echo "  [oemroot] ERROR: $RKLUNCH not found — SDK oem layout changed (camera would not start)" >&2
    exit 1
fi

if grep -q '/data/core-%p-%e' "$RKLUNCH"; then
    sed -i "s|/data/core-%p-%e|$CORE_PATTERN|g" "$RKLUNCH"
    if grep -q "$CORE_PATTERN" "$RKLUNCH"; then
        log "RkLunch.sh: core_pattern /data/core-%p-%e -> $CORE_PATTERN (no core dumps written to the read-only /oem)"
    else
        echo "  [oemroot] ERROR: failed to repoint core_pattern in $RKLUNCH" >&2
        exit 1
    fi
elif grep -q "$CORE_PATTERN" "$RKLUNCH"; then
    log "RkLunch.sh: core_pattern already points at $CORE_PATTERN (idempotent re-run)"
else
    # A future SDK may stop setting core_pattern in RkLunch.sh. That is not an
    # error (the kernel default then applies), but say so loudly so a change in
    # the oem tree is noticed.
    log "WARNING: no core_pattern line found in RkLunch.sh — leaving it untouched (verify no other writer targets /oem)"
fi
