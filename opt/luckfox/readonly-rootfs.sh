#!/usr/bin/env bash
#
# readonly-rootfs.sh <BOARD_CONFIG> <KERNEL_DEFCONFIG> [ENABLE]
#
# Make the root filesystem read-only and immutable: squashfs instead of
# ubifs/ext4, with a tmpfs overlay at runtime (see files/S01overlay). Shared by
# the GitHub Actions build and both local Docker builds (os-build.sh /
# build-local.sh) — change this script, never one caller. Must run BEFORE
# `./build.sh kernel` and before the partition/filesystem config is consumed.
#
#   ENABLE  1|0 (default 1) — 0 makes this a logged no-op
#
# WHY: the rootfs is writable UBIFS today, and that is the corruption vector.
# Two confirmed writers make it self-damaging in normal operation:
#
#   * luckfox-config does `sed -i` on /etc/luckfox.cfg on EVERY boot. A power cut
#     mid-write leaves a truncated or lost file, luckfox_load_cfg then silently
#     `touch`es an empty one, zero device-tree overlays get created, there is no
#     /dev/spidev0.0 — and the device boots to a black screen with no way to
#     report why.
#   * the shipped Python bytecode lives on the same filesystem. A truncated .pyc
#     surfaced as `EOFError: marshal data is too short` and needed a reflash.
#
# Neither is fixable by being careful at the application layer, because the
# damage happens during UBIFS journal replay after an unclean shutdown, to files
# nobody was deliberately writing. Removing write capability from the filesystem
# is the only real control: squashfs has no journal, no allocator and no write
# path, so an unclean shutdown cannot leave it inconsistent, and no runtime
# change to / can survive a reboot because none can be committed in the first
# place.
#
# WHAT STAYS WRITABLE: /userdata (a separate partition) is the sole persistent
# store, which is why the app was moved to resolve settings there. /etc, /var,
# /root and /home get tmpfs overlays so software that expects to write keeps
# working, with the writes discarded at reboot.
#
# NOT COVERED (deliberate, follow-up): the oem partition is still read-write.
# Its surface is much smaller — no equivalent of the per-boot luckfox.cfg
# rewrite has been observed — and converting it is a separate change with its
# own hardware verification. The SDK does support `oem@/oem@squashfs`.
#
# NOTE: Kconfig SILENTLY DROPS defconfig lines for symbols that don't exist or
# whose dependencies are unmet. Setting CONFIG_OVERLAY_FS here does NOT prove it
# took effect — the callers assert against the GENERATED kernel .config after
# the build. See assert-readonly-rootfs.sh. Getting this wrong is not a cosmetic
# failure: a squashfs root with no overlayfs is a device where the first write
# to /etc fails and the display never comes up.

set -eu

BOARD_CONFIG="${1:-}"
DEFCONFIG="${2:-}"
ENABLE="${3:-1}"

if [ -z "$BOARD_CONFIG" ] || [ ! -f "$BOARD_CONFIG" ]; then
    echo "readonly-rootfs: board config '${BOARD_CONFIG:-<empty>}' not found" >&2
    exit 1
fi
if [ -z "$DEFCONFIG" ] || [ ! -f "$DEFCONFIG" ]; then
    echo "readonly-rootfs: kernel defconfig '${DEFCONFIG:-<empty>}' not found" >&2
    exit 1
fi

log() { echo "  [rorootfs] $*"; }

if [ "$ENABLE" != "1" ]; then
    log "read-only rootfs DISABLED — rootfs stays writable (ubifs/ext4)"
    exit 0
fi

echo "=== Making rootfs read-only (squashfs + tmpfs overlay) in $(basename "$BOARD_CONFIG") ==="

# --------------------------------------------------------------- kernel symbol
# Force a symbol on, whatever state it's currently in: drop any existing
# CONFIG_X= or "# CONFIG_X is not set" line, then append the enabled form.
enable_sym() {
    local sym="$1"
    sed -i -E "/^(# )?${sym}[= ]/d" "$DEFCONFIG"
    printf '%s=y\n' "$sym" >> "$DEFCONFIG"
    grep -qE "^${sym}=y$" "$DEFCONFIG" || {
        echo "readonly-rootfs: failed to enable $sym" >&2; exit 1
    }
    log "enabled ${sym}"
}

# The only symbol actually missing from the stock defconfig. SQUASHFS,
# SQUASHFS_XZ, MTD_UBI_BLOCK (for the NAND boards' ubiblock root) and TMPFS are
# all already =y there; the post-build assertion re-checks every one of them
# against the generated .config rather than trusting that to stay true.
enable_sym CONFIG_OVERLAY_FS

# ---------------------------------------------------------------- rootfs fstype
# RK_PARTITION_FS_TYPE_CFG is a comma-separated list of name@mountpoint@fstype.
# Rewrite only the rootfs entry; oem and userdata must keep their own types
# (userdata in particular MUST stay writable — it is the only persistent store).
FS_LINE="$(grep -nE '^[[:space:]]*export[[:space:]]+RK_PARTITION_FS_TYPE_CFG=' "$BOARD_CONFIG" | head -n1 || true)"
if [ -z "$FS_LINE" ]; then
    echo "readonly-rootfs: no RK_PARTITION_FS_TYPE_CFG in $BOARD_CONFIG — cannot set the rootfs type" >&2
    exit 1
fi
log "before: ${FS_LINE#*:}"

# rootfs@IGNORE@<anything> -> rootfs@IGNORE@squashfs. Anchored on the "rootfs@"
# name so a userdata or oem entry can never be rewritten by accident.
sed -i -E 's/(^|[,=" ])(rootfs@[^@,"]*@)[A-Za-z0-9]+/\1\2squashfs/' "$BOARD_CONFIG"

FS_AFTER="$(grep -E '^[[:space:]]*export[[:space:]]+RK_PARTITION_FS_TYPE_CFG=' "$BOARD_CONFIG" | head -n1)"
log "after:  $FS_AFTER"

if ! echo "$FS_AFTER" | grep -qE 'rootfs@[^@,"]*@squashfs'; then
    echo "readonly-rootfs: rootfs is not squashfs after patching: $FS_AFTER" >&2
    exit 1
fi
# Guard the store the device cannot lose. If the sed above ever widened, this is
# what catches it: a squashfs userdata is a device that silently discards every
# setting the user saves.
if echo "$FS_AFTER" | grep -qE 'userdata@[^@,"]*@squashfs'; then
    echo "readonly-rootfs: REFUSING — userdata was rewritten to squashfs: $FS_AFTER" >&2
    exit 1
fi

# ------------------------------------------------------------- squashfs codec
# xz gives the best ratio of the codecs the kernel has here (CONFIG_SQUASHFS_XZ
# is the only decompressor enabled; ZLIB is explicitly off), and decompression
# cost is paid on a device that is otherwise idle at boot. The stock board
# configs carry this line commented out.
if grep -qE '^[[:space:]]*export[[:space:]]+RK_SQUASHFS_COMP=' "$BOARD_CONFIG"; then
    sed -i -E 's/^([[:space:]]*export[[:space:]]+RK_SQUASHFS_COMP=).*/\1xz/' "$BOARD_CONFIG"
    log "set RK_SQUASHFS_COMP=xz (was already uncommented)"
else
    printf '\n# [seedsigner] read-only rootfs: xz is the only squashfs decompressor in the kernel\nexport RK_SQUASHFS_COMP=xz\n' >> "$BOARD_CONFIG"
    log "appended RK_SQUASHFS_COMP=xz"
fi
grep -qE '^[[:space:]]*export[[:space:]]+RK_SQUASHFS_COMP=xz[[:space:]]*$' "$BOARD_CONFIG" || {
    echo "readonly-rootfs: failed to set RK_SQUASHFS_COMP=xz" >&2; exit 1
}

# ------------------------------------------------------------------ bootargs
# Nothing to do: the SDK derives root= and rootfstype= from the fs type we just
# set (project/build.sh, __GET_TARGET_PARTITION_FS_TYPE). For spi_nand that is
# `ubi.block=0,rootfs root=/dev/ubiblock0_0 rootfstype=squashfs`, for emmc
# `root=/dev/mmcblk0p<n> rootfstype=squashfs`. Hand-patching them would fight
# the generator; the assertion step checks the result instead.
log "bootargs are derived by the SDK from the fs type — not patched here"

echo "=== read-only rootfs configuration complete ==="
