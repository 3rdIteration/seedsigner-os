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
#   IQFILES_KEEP - space-separated sensor-name substrings to keep in iqfiles
#                  (default: the sensors used on Luckfox Pico boards).
#
# Usage:  optimize-nondev.sh <ROOTFS_DIR>

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
# Camera ISP iqfiles prune. Rockchip ships tuning for many sensors; keep only the
# one(s) the board actually uses. Guarded: no-op if oem isn't staged in this
# rootfs. VERIFY THE CAMERA ON HARDWARE after changing this.
IQDIR="$ROOTFS/oem/usr/share/iqfiles"
IQFILES_KEEP="${IQFILES_KEEP:-sc3336 sc3338 sc830ai gc2093 gc2053 ov5647}"
if [ -d "$IQDIR" ]; then
    kept=0; removed=0
    for f in "$IQDIR"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        keep=0
        for s in $IQFILES_KEEP; do
            case "$name" in *"$s"*) keep=1; break;; esac
        done
        if [ "$keep" -eq 1 ]; then
            kept=$((kept + 1))
        else
            rm -f "$f" && removed=$((removed + 1))
        fi
    done
    log "iqfiles: kept $kept (match: $IQFILES_KEEP), removed $removed  --  VERIFY CAMERA ON HARDWARE"
else
    skip "no $IQDIR (oem may be a separate stage) - iqfiles untouched"
fi

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
