#!/usr/bin/env bash
#
# optimize-nondev.sh <ROOTFS_DIR>
#
# Non-dev (production) size / boot optimizations of a *built* Luckfox rootfs.
# Runs after harden-nondev.sh, only on non-dev builds. Companion to it, same
# discipline: guarded/no-op-if-absent, and logs every action so the build output
# can be reviewed. Camera-related pruning (iqfiles) and the UI-first marker MUST
# be verified on hardware — a green build proves nothing about the camera.
#
#   1. Prune python/app test suites + packaging metadata + the app's dev tools/.
#   2. Prune unused camera ISP tuning files (keep the board's sensor).
#   3. Drop /etc/seedsigner-nondev, which start-seedsigner.sh reads to launch the
#      UI before the (backgrounded) camera-graph bootstrap.
#
# Env:
#   (the iqfiles prune and its IQFILES_KEEP knob now live in
#    prune-oem-iqfiles.sh — see section 2 below)
#                  (default: the sensors used on Luckfox Pico boards).
#
# Usage:  optimize-nondev.sh <ROOTFS_DIR>
#
# NOTE: this script only ever sees the ROOTFS. The oem partition is assembled
# later, by the SDK's __PACKAGE_OEM inside `build.sh firmware`, so anything
# targeting oem must run from the __RUN_PRE_BUILD_OEM_SCRIPT hook instead (see
# prune-oem-iqfiles.sh / patch-oem-pre-hook.sh).

set -u

ROOTFS="${1:-}"
if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "optimize-nondev: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [optimize] $*"; }
skip() { echo "  [optimize] (skip) $*"; }

echo "=== Applying non-dev size/boot optimizations to $ROOTFS ==="

size_before=$(du -sk "$ROOTFS" 2>/dev/null | cut -f1 || true)

# --------------------------------------------------------------------------- 1
# Python / app prunes (safe): test suites and packaging metadata are not used at
# runtime. PYC_ONLY is set in the defconfig, so .py source is already absent and
# __pycache__ (the shipped .pyc) is left alone.
for base in "$ROOTFS"/usr/lib/python*/site-packages "$ROOTFS"/opt/src; do
    [ -d "$base" ] || continue
    find "$base" -depth -type d -name tests -exec rm -rf {} + 2>/dev/null || true
    find "$base" -depth -type d \( -name '*.dist-info' -o -name '*.egg-info' \) -exec rm -rf {} + 2>/dev/null || true
done
log "pruned package tests/ + *.dist-info/*.egg-info under site-packages and /opt/src"

if [ -d "$ROOTFS/opt/tools" ]; then
    rm -rf "$ROOTFS/opt/tools" && log "removed /opt/tools (app dev tooling)"
fi

# --------------------------------------------------------------------------- 2
# Camera ISP iqfiles prune MOVED OUT of this script (2026-08-06).
#
# It used to live here and silently did nothing in every build: the oem
# partition is assembled by the SDK's __PACKAGE_OEM, which runs inside
# `build.sh firmware` — i.e. AFTER this script — so the iqfiles directory did
# not exist yet and the prune always hit its "not found" branch. It now runs
# from opt/luckfox/prune-oem-iqfiles.sh, invoked via the SDK's
# __RUN_PRE_BUILD_OEM_SCRIPT hook (installed by patch-oem-pre-hook.sh), which
# fires after __PACKAGE_OEM and before build_mkimg creates oem.img — the one
# window where the staged oem tree exists and is still editable.

# --------------------------------------------------------------------------- 3
# UI-first camera bring-up marker (read by start-seedsigner.sh). OPT-IN only:
# backgrounding the camera-graph bootstrap can race the SPI display init and blank
# the screen, so it is OFF by default until proven on hardware. Enable with
# OPTIMIZE_UI_FIRST_CAMERA=1. Without the marker, boot uses the SDK-default order.
if [ "${OPTIMIZE_UI_FIRST_CAMERA:-0}" = "1" ]; then
    mkdir -p "$ROOTFS/etc"
    : > "$ROOTFS/etc/seedsigner-nondev" \
        && log "created /etc/seedsigner-nondev (UI-first camera bring-up ENABLED)"
else
    rm -f "$ROOTFS/etc/seedsigner-nondev" 2>/dev/null || true
    log "UI-first camera bring-up DISABLED (SDK-default camera ordering; set OPTIMIZE_UI_FIRST_CAMERA=1 to enable)"
fi

size_after=$(du -sk "$ROOTFS" 2>/dev/null | cut -f1 || true)
if [ -n "${size_before:-}" ] && [ -n "${size_after:-}" ]; then
    log "rootfs staged size: ${size_before}K -> ${size_after}K"
fi

echo "=== non-dev optimization complete ==="
exit 0
