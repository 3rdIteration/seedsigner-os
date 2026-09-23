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
# THE oem PARTITION IS REMOVED AND ITS CONTENT IS FOLDED INTO THE SIGNED ROOTFS.
# Luckfox secure boot verifies the loader, both FIT images and the rootfs — it
# does NOT verify the oem partition, yet the board mounts oem at /oem and runs
# /oem/usr/bin/RkLunch.sh and /oem/usr/ko/insmod_ko.sh as root on every boot. A
# proof-of-concept on a fully fused board (2026-09-23) spliced two `echo`s into
# RkLunch.sh on an otherwise byte-identical signed chain: the board verified the
# rootfs, then ran the tamper as uid 0. oem is therefore not part of the trusted
# boot path and cannot be made so by a userspace check.
#
# The fix is to remove it by construction. Setting
#   RK_BUILD_APP_TO_OEM_PARTITION=n
# makes the SDK's build_firmware() copy the staged (and pruned) oem tree into the
# rootfs staging directory before the rootfs squashfs is packed — build.sh:
#
#     __PACKAGE_ROOTFS ; __PACKAGE_OEM ; __RUN_PRE_BUILD_OEM_SCRIPT
#     if [ "$RK_BUILD_APP_TO_OEM_PARTITION" = "y" ]; then
#         build_mkimg oem $RK_PROJECT_PACKAGE_OEM_DIR          # separate partition
#     else
#         __COPY_FILES $RK_PROJECT_PACKAGE_OEM_DIR $RK_PROJECT_PACKAGE_ROOTFS_DIR/oem
#         rm -rf $RK_PROJECT_PACKAGE_OEM_DIR                   # folded into rootfs
#     fi
#     ... build_mkimg rootfs $RK_PROJECT_PACKAGE_ROOTFS_DIR
#
# so the camera iqfiles, the .ko modules and RkLunch.sh all end up inside the
# squashfs, which the rootfs signature (tier C) already covers. The `oem`
# element is removed from every partition table and every filesystem mount
# config; the space it used is added to the (last) rootfs partition. No verifier
# code, no hashing, no freeze: the untrusted partition leaves the execution path
# by construction.
#
# The partition tables live in the SDK board configs under
# project/cfg/BoardConfig_IPC/, in two variables:
#   RK_PARTITION_CMD_IN_ENV   the `<size>(name),...` list (also the SD card's
#                             blkdevparts via env.img)
#   RK_PARTITION_FS_TYPE_CFG  the `name@mountpoint@fstype,...` mount list
# A stale oem entry in RK_PARTITION_FS_TYPE_CFG with no matching partition is a
# hard error in the SDK (__GET_TARGET_PARTITION_FS_TYPE exits), so both must go
# together.
#
# Sizes are chosen so rootfs stays LAST and userdata sits at a fixed offset before
# it: rootfs can then grow in a later revision without moving userdata, which would
# otherwise orphan the settings of every already-flashed device. (Removing the
# oem entry necessarily shifts userdata earlier by the oem size, so every device
# is reflashed with the new table; nothing at runtime hardcodes the offset.)

set -eu

LUCKFOX_DIR="${1:-}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "apply-partition-layout: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [parts] $*"; }
fail() { echo "  [parts] ❌ $*" >&2; exit 1; }

CFG_DIR="$LUCKFOX_DIR/project/cfg/BoardConfig_IPC"
NAND_MINI="$CFG_DIR/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk"
NAND_MAX="$CFG_DIR/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk"
SD_MINI="$CFG_DIR/BoardConfig-SD_CARD-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk"
SD_MAX="$CFG_DIR/BoardConfig-SD_CARD-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk"
EMMC_PI="$CFG_DIR/BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Pi-IPC.mk"

echo "=== Applying Luckfox partition layout ==="

part_line() { grep -E '^[[:space:]]*export[[:space:]]+RK_PARTITION_CMD_IN_ENV=' "$1" | head -n1; }
fs_line()   { grep -E '^[[:space:]]*export[[:space:]]+RK_PARTITION_FS_TYPE_CFG=' "$1" | head -n1; }

# Delete the oem entry from RK_PARTITION_FS_TYPE_CFG for a given fstype (ubifs or
# ext4). Anchored on `oem@/oem@` so a userdata/rootfs entry can never be touched.
strip_oem_fs() {
    sed -i "s|,oem@/oem@${2}||" "$1"
}

# Set RK_BUILD_APP_TO_OEM_PARTITION=n (fold oem into the rootfs). Idempotent.
fold_oem_flag() {
    sed -i -E 's|^([[:space:]]*export[[:space:]]+RK_BUILD_APP_TO_OEM_PARTITION=).*|\1n|' "$1"
}

# ------------------------------------------------------------------ NAND Mini (128MB)
# SDK default: 30M(oem),6M(userdata),85M(rootfs). oem removed, its 20M (the
# pruned size this repo used) folded into rootfs: 93M -> 113M, so the total stays
# at 119M (the previous 20/6/93 layout).
[ -f "$NAND_MINI" ] || fail "NAND Mini BoardConfig not found: $NAND_MINI"
sed -i 's/30M(oem),6M(userdata),85M(rootfs)/6M(userdata),113M(rootfs)/' "$NAND_MINI"
strip_oem_fs "$NAND_MINI" ubifs
fold_oem_flag "$NAND_MINI"
log "Mini (NAND): oem removed, userdata 6M, rootfs 113M"

# ------------------------------------------------------------------- NAND Max (256MB)
# SDK default: 30M(oem),10M(userdata),210M(rootfs). oem's 20M folded into rootfs:
# 217M -> 237M, so the total stays 247M (the previous 20/10/217 layout).
[ -f "$NAND_MAX" ] || fail "NAND Max BoardConfig not found: $NAND_MAX"
sed -i 's/30M(oem),10M(userdata),210M(rootfs)/10M(userdata),237M(rootfs)/' "$NAND_MAX"
strip_oem_fs "$NAND_MAX" ubifs
fold_oem_flag "$NAND_MAX"
log "Max (NAND): oem removed, userdata 10M, rootfs 237M"

# --------------------------------------------------------- Mini/Max/Pi (SD/eMMC)
# The MicroSD and eMMC board configs all carry the same `32M(boot),512M(oem),
# 256M(userdata),6G(rootfs)` shape. oem 512M removed and added to the (last)
# rootfs: 6G -> 6656M. The eMMC Pi previously needed no edit because only its
# userdata mount was checked; it now gets the same treatment as the SD boards so
# one layout rule covers all four non-NAND profiles.
apply_ext4_board() {
    local file="$1" label="$2"
    [ -f "$file" ] || fail "$label BoardConfig not found: $file"
    sed -i 's/32M(boot),512M(oem),256M(userdata),6G(rootfs)/32M(boot),256M(userdata),6656M(rootfs)/' "$file"
    strip_oem_fs "$file" ext4
    fold_oem_flag "$file"
    log "$label (ext4): oem removed, userdata 256M, rootfs 6656M"
}
apply_ext4_board "$SD_MINI" "SD Mini"
apply_ext4_board "$SD_MAX"  "SD Max"
apply_ext4_board "$EMMC_PI" "EMMC Pi"

# ------------------------------------------------------------------ verification
# Hard failures. A silently unpatched table would ship a board that either still
# has an untrusted oem partition or (worse) no /oem at all — the camera tuning
# files and .ko would be missing, which builds green and shows up only as a dead
# camera on hardware.
echo ""
for entry in "$NAND_MINI" "$NAND_MAX" "$SD_MINI" "$SD_MAX" "$EMMC_PI"; do
    name="$(basename "$entry")"
    pl="$(part_line "$entry")"
    fl="$(fs_line "$entry")"

    # No oem partition anywhere, and no oem mount config.
    echo "$pl" | grep -q '(oem)' \
        && fail "oem partition still present in $name: $pl"
    echo "$fl" | grep -q 'oem@' \
        && fail "oem mount still present in $name: $fl"

    # userdata must remain: it is the partition that keeps on-device settings.
    echo "$pl" | grep -q '(userdata)' \
        || fail "userdata partition missing from $name: $pl"
    echo "$fl" | grep -q 'userdata@/userdata@' \
        || fail "userdata mount missing from $name: $fl"

    # rootfs must stay last, so growing it later never moves userdata.
    echo "$pl" | grep -qE ',[0-9]+[KMG]\(rootfs\)"?[[:space:]]*$' \
        || fail "rootfs is not the last partition in $name: $pl"

    # oem must be folded into the rootfs at pack time.
    grep -qE '^[[:space:]]*export[[:space:]]+RK_BUILD_APP_TO_OEM_PARTITION=n[[:space:]]*$' "$entry" \
        || fail "RK_BUILD_APP_TO_OEM_PARTITION is not 'n' in $name — oem would be a separate, unsigned partition"
done

# Exact expected tables, checked as whole substrings so a partial/renamed patch
# fails loudly rather than shipping a subtly different layout.
part_line "$NAND_MINI" | grep -q '4M(boot),6M(userdata),113M(rootfs)"' \
    || fail "Mini NAND partition layout unexpected: $(part_line "$NAND_MINI")"
part_line "$NAND_MAX" | grep -q '4M(boot),10M(userdata),237M(rootfs)"' \
    || fail "Max NAND partition layout unexpected: $(part_line "$NAND_MAX")"
for entry in "$SD_MINI" "$SD_MAX" "$EMMC_PI"; do
    part_line "$entry" | grep -q '32M(boot),256M(userdata),6656M(rootfs)"' \
        || fail "$(basename "$entry") partition layout unexpected: $(part_line "$entry")"
done

log "Mini table:  $(part_line "$NAND_MINI")"
log "Max table:   $(part_line "$NAND_MAX")"
log "SD/Pi table: $(part_line "$SD_MINI")"
log "✅ no oem partition on any board; userdata retained and mounted; rootfs last"
log "✅ oem folded into the signed rootfs (RK_BUILD_APP_TO_OEM_PARTITION=n)"
echo "=== partition layout applied ==="
