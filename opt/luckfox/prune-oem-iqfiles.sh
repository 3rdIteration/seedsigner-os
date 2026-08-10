#!/usr/bin/env bash
#
# prune-oem-iqfiles.sh [OEM_DIR]
#
# Camera ISP tuning-file (iqfiles) prune for non-dev images. Rockchip ships
# tuning data for many sensors; keep only the one(s) a Luckfox board can
# actually have. Size optimization only — no security impact.
#
# OEM_DIR defaults to $RK_PROJECT_PACKAGE_OEM_DIR, which the SDK exports, so the
# script can be invoked from the SDK's pre-build-OEM hook with no arguments.
#
# WHY IT RUNS FROM THAT HOOK: the oem partition is assembled by __PACKAGE_OEM,
# which is called only from build_firmware() (i.e. during `./build.sh firmware`).
# Anything earlier — such as optimize-nondev.sh, which runs during the rootfs/app
# install step — sees no oem directory at all and silently prunes nothing (this
# prune was dead for every build until 2026-08-06). The SDK's
# __RUN_PRE_BUILD_OEM_SCRIPT hook runs after __PACKAGE_OEM but before
# build_mkimg creates oem.img, which is the one window where the staged oem tree
# exists and is still editable. The vendor's own hook script
# (luckfox-buildroot-oem-pre.sh) prunes unused libs there for the same reason,
# and the SDK's __RUN_POST_CLEAN_FILES drops unused NPU/audio models at the same
# point — this follows that established pattern.
#
# Env:
#   IQFILES_KEEP - space-separated sensor-name substrings to keep
#                  (default: the sensors used on Luckfox Pico boards)
#
# REMOVING THE WRONG TUNING FILE BREAKS THE CAMERA — verify on hardware.

set -u

OEM_DIR="${1:-${RK_PROJECT_PACKAGE_OEM_DIR:-}}"
IQFILES_KEEP="${IQFILES_KEEP:-sc3336 sc3338 sc830ai gc2093 gc2053 ov5647}"

log()  { echo "  [iqprune] $*"; }
skip() { echo "  [iqprune] (skip) $*"; }

if [ -z "$OEM_DIR" ]; then
    skip "no OEM_DIR given and RK_PROJECT_PACKAGE_OEM_DIR unset - iqfiles untouched"
    exit 0
fi

IQDIR="$OEM_DIR/usr/share/iqfiles"
if [ ! -d "$IQDIR" ]; then
    skip "no $IQDIR - iqfiles untouched"
    exit 0
fi

size_before=$(du -sk "$IQDIR" 2>/dev/null | cut -f1 || echo 0)

# Two passes: decide first, delete second. Deciding as we go would mean a bad
# IQFILES_KEEP had already destroyed the tuning data by the time the safety
# check below noticed.
#
# Handle both layouts: tuning files directly in iqfiles/, and per-sensor
# subdirectories. A plain `for f in "$IQDIR"/*` with a -f test would silently
# skip the subdirectory layout and prune nothing.
keep_list=""; drop_list=""; kept=0; removed=0
while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name=$(basename "$entry")
    keep=0
    for s in $IQFILES_KEEP; do
        case "$name" in *"$s"*) keep=1; break;; esac
    done
    if [ "$keep" -eq 1 ]; then
        keep_list="$keep_list$entry
"
        kept=$((kept + 1))
    else
        drop_list="$drop_list$entry
"
        removed=$((removed + 1))
    fi
done <<EOF
$(find "$IQDIR" -mindepth 1 -maxdepth 1 2>/dev/null)
EOF

if [ "$kept" -eq 0 ] && [ "$removed" -gt 0 ]; then
    # Never leave the camera with no tuning data at all: that is a guaranteed
    # breakage and almost certainly means IQFILES_KEEP doesn't match this SDK's
    # naming. Fail loudly, having deleted nothing.
    echo "  [iqprune] ERROR: IQFILES_KEEP='$IQFILES_KEEP' matches NONE of the $removed entries in $IQDIR" >&2
    echo "  [iqprune] pruning would leave the camera with no ISP tuning data — aborting, nothing deleted" >&2
    exit 1
fi

while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    rm -rf "$entry"
done <<EOF
$drop_list
EOF

size_after=$(du -sk "$IQDIR" 2>/dev/null | cut -f1 || echo 0)
log "iqfiles: kept $kept, removed $removed (match: $IQFILES_KEEP); ${size_before}K -> ${size_after}K  --  VERIFY CAMERA ON HARDWARE"
