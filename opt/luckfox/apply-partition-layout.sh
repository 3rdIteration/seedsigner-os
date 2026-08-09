#!/usr/bin/env bash
#
# apply-partition-layout.sh <LUCKFOX_PICO_DIR>
#
# Set the flash partition layout for every Luckfox board. Shared by the GitHub
# Actions build and both local Docker builds (os-build.sh / build-local.sh) —
# change this script, never one caller. Must run BEFORE the firmware is packaged.
#
# THE POINT OF THIS SCRIPT IS THE userdata PARTITION. It is the only writable,
# non-rootfs store on the device, and since the rootfs became read-only squashfs
# (see readonly-rootfs.sh) it is the ONLY place anything can be persisted at all:
#
#   * the app saves settings there when no removable card is present
#     (resolve_seedsigner_os_data_dir), and Persistent Settings is offered only
#     when that store exists;
#   * start-seedsigner.sh writes its boot log there, the sole diagnostic channel
#     on a hardened image with no console, no adb and no network.
#
# A board built without it boots, looks completely healthy, and silently discards
# every setting the user saves. That is why the verification below is a hard
# failure rather than a warning.
#
# HISTORY, because it is the whole reason this file exists: the two local Docker
# builds used to DELETE the userdata partition (`20M(oem),99M(rootfs)`, plus a sed
# stripping `userdata@/userdata@ubifs` from the filesystem config) while CI kept
# it. Same repo, same board, silently different images — and the local one had
# nowhere to store settings. Three copies of a layout is how that happens, so
# there is now one.
#
# Sizes are chosen so rootfs stays LAST and userdata sits at a fixed offset before
# it: rootfs can then grow in a later revision without moving userdata, which would
# otherwise orphan the settings of every already-flashed device.

set -eu

LUCKFOX_DIR="${1:-}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "apply-partition-layout: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [parts] $*"; }
fail() { echo "  [parts] ❌ $*" >&2; exit 1; }

CFG_DIR="$LUCKFOX_DIR/project/cfg/BoardConfig_IPC"
MINI_FILE="$CFG_DIR/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk"
MAX_FILE="$CFG_DIR/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk"
PI_FILE="$CFG_DIR/BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Pi-IPC.mk"

echo "=== Applying Luckfox partition layout ==="

# ------------------------------------------------------------------ Mini (128MB)
# OEM 30M -> 20M; userdata 6M retained; rootfs 85M -> 93M. Same 119M total as the
# old userdata-less layout (20M oem + 99M rootfs), with 6M carved out of rootfs.
[ -f "$MINI_FILE" ] || fail "Mini BoardConfig not found: $MINI_FILE"
sed -i 's/30M(oem),6M(userdata),85M(rootfs)/20M(oem),6M(userdata),93M(rootfs)/' "$MINI_FILE"
log "Mini: oem 20M, userdata 6M, rootfs 93M"

# ------------------------------------------------------------------- Max (256MB)
# OEM 30M -> 20M; userdata 10M retained (settings + boot log); rootfs 210M -> 217M.
[ -f "$MAX_FILE" ] || fail "Max BoardConfig not found: $MAX_FILE"
sed -i 's/30M(oem),10M(userdata),210M(rootfs)/20M(oem),10M(userdata),217M(rootfs)/' "$MAX_FILE"
log "Max: oem 20M, userdata 10M, rootfs 217M"

# --------------------------------------------------------------------- Pi (eMMC)
# Nothing is edited: the SDK's own layout already has 256M(userdata) and eMMC has
# space to spare. But an unconditional "retained" message is not a check — it
# would keep reporting a partition that a future SDK bump had removed — so assert
# both halves instead.
[ -f "$PI_FILE" ] || fail "Pi BoardConfig not found: $PI_FILE"
PI_PARTITION="$(grep 'RK_PARTITION_CMD_IN_ENV=' "$PI_FILE" | head -1)"
PI_FS_TYPE="$(grep 'RK_PARTITION_FS_TYPE_CFG=' "$PI_FILE" | head -1)"
echo "$PI_PARTITION" | grep -q '(userdata)' \
    || fail "Pi eMMC partition table has no userdata partition: $PI_PARTITION"
echo "$PI_FS_TYPE" | grep -q 'userdata@/userdata@' \
    || fail "Pi eMMC fs config does not mount userdata: $PI_FS_TYPE"
log "Pi: userdata retained (SDK default, 256M ext4) — verified, not assumed"

# ------------------------------------------------------------------ verification
# Hard failures. A silently unpatched table ships a board with no userdata
# partition, which has no visible symptom at build time and shows up only when a
# user loses their settings.
echo ""
MINI_PARTITION="$(grep 'RK_PARTITION_CMD_IN_ENV=' "$MINI_FILE" | head -1)"
MAX_PARTITION="$(grep 'RK_PARTITION_CMD_IN_ENV=' "$MAX_FILE" | head -1)"
log "Mini table: $MINI_PARTITION"
log "Max table:  $MAX_PARTITION"

echo "$MINI_PARTITION" | grep -q '6M(userdata),93M(rootfs)' \
    || fail "Mini partition layout unexpected: $MINI_PARTITION"
log "✅ Mini partition VERIFIED"

echo "$MAX_PARTITION" | grep -q '10M(userdata),217M(rootfs)' \
    || fail "Max partition layout unexpected: $MAX_PARTITION"
log "✅ Max partition VERIFIED"

# The filesystem config must still MOUNT userdata on every board. Keeping the
# partition but dropping its mountpoint would give a device with the space
# allocated and nothing able to use it.
for f in "$MINI_FILE" "$MAX_FILE" "$PI_FILE"; do
    grep -q 'userdata@/userdata@' "$f" \
        || fail "userdata mount missing from fs config in $(basename "$f")"
done
log "✅ userdata mounted on all three boards"

echo "=== partition layout applied ==="
