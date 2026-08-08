#!/usr/bin/env bash
#
# assert-readonly-rootfs.sh <LUCKFOX_PICO_DIR> <BOARD_CONFIG> [EXPECT_RO]
#
# Post-build verification that the read-only rootfs actually took effect. Shared
# by the GitHub Actions build and both local Docker builds. Run AFTER
# `./build.sh kernel` (the .config check) and ideally after `./build.sh firmware`
# (the image checks, which no-op if the images aren't built yet).
#
#   EXPECT_RO  1|0 (default 1) — 0 asserts the rootfs is NOT squashfs
#
# WHY THIS EXISTS: Kconfig SILENTLY DROPS defconfig lines whose symbol doesn't
# exist or whose dependencies are unmet, so writing CONFIG_OVERLAY_FS=y into a
# defconfig proves nothing. Every check here is against the GENERATED kernel
# .config or a built artifact, never against the inputs we wrote.
#
# The failure this prevents is not subtle but it is silent at build time: a
# squashfs root on a kernel without overlayfs boots, mounts, and then fails the
# first write to /etc. luckfox-config cannot rewrite /etc/luckfox.cfg, no
# device-tree overlays are created, there is no /dev/spidev0.0, and the device
# comes up with a black screen and no way to report why. That is indistinguish-
# able on the bench from the display bugs we have been chasing for weeks, which
# is exactly why it has to fail the build instead.

set -eu

LUCKFOX_DIR="${1:-}"
BOARD_CONFIG="${2:-}"
EXPECT_RO="${3:-1}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "assert-readonly-rootfs: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [roassert] $*"; }
fail() { echo "  [roassert] ❌ $*" >&2; FAILED=1; }
FAILED=0

if [ "$EXPECT_RO" != "1" ]; then
    echo "=== Verifying rootfs is WRITABLE (read-only rootfs disabled) ==="
    if [ -n "$BOARD_CONFIG" ] && [ -f "$BOARD_CONFIG" ]; then
        if grep -qE 'rootfs@[^@,"]*@squashfs' "$BOARD_CONFIG"; then
            fail "rootfs is squashfs but the read-only rootfs was supposed to be off"
        else
            log "rootfs filesystem type is not squashfs, as expected"
        fi
    fi
    [ "$FAILED" -eq 0 ] || exit 1
    echo "=== verification complete ==="
    exit 0
fi

echo "=== Verifying read-only rootfs (squashfs + overlayfs) ==="

# ---------------------------------------------------------------- generated .config
CFG=""
for c in \
    "$LUCKFOX_DIR/sysdrv/source/objs_kernel/.config" \
    "$LUCKFOX_DIR/sysdrv/source/kernel/.config"
do
    [ -f "$c" ] && { CFG="$c"; break; }
done
if [ -z "$CFG" ]; then
    CFG="$(find "$LUCKFOX_DIR/sysdrv" -maxdepth 4 -name '.config' -path '*kernel*' 2>/dev/null | head -n1 || true)"
fi

if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
    echo "assert-readonly-rootfs: could not locate the generated kernel .config — cannot verify" >&2
    exit 1
fi
log "checking generated kernel config: ${CFG#"$LUCKFOX_DIR"/}"

is_on() { grep -qE "^$1=y$" "$CFG"; }

# OVERLAY_FS is the one we add, so it is the one most likely to have been
# dropped. The rest ship =y in the stock defconfig and are asserted so that an
# SDK bump cannot quietly remove the ground this stands on.
for sym in CONFIG_OVERLAY_FS CONFIG_SQUASHFS CONFIG_SQUASHFS_XZ CONFIG_TMPFS; do
    if is_on "$sym"; then
        log "$sym=y"
    else
        fail "$sym is NOT enabled in the generated kernel config"
    fi
done

# NAND boards mount the squashfs root through a ubiblock device
# (root=/dev/ubiblock0_0); without this the kernel cannot mount / at all.
if [ -n "$BOARD_CONFIG" ] && [ -f "$BOARD_CONFIG" ] \
   && grep -qiE 'RK_BOOT_MEDIUM=.*(spi_nand|slc_nand)' "$BOARD_CONFIG"; then
    if is_on CONFIG_MTD_UBI_BLOCK; then
        log "CONFIG_MTD_UBI_BLOCK=y (needed for root=/dev/ubiblock0_0 on NAND)"
    else
        fail "CONFIG_MTD_UBI_BLOCK is NOT enabled — a NAND squashfs root cannot be mounted"
    fi
fi

# ------------------------------------------------------------------ board config
if [ -n "$BOARD_CONFIG" ] && [ -f "$BOARD_CONFIG" ]; then
    FS_CFG="$(grep -E '^[[:space:]]*export[[:space:]]+RK_PARTITION_FS_TYPE_CFG=' "$BOARD_CONFIG" | head -n1 || true)"
    if echo "$FS_CFG" | grep -qE 'rootfs@[^@,"]*@squashfs'; then
        log "rootfs filesystem type is squashfs"
    else
        fail "rootfs is not squashfs in the board config: ${FS_CFG:-<missing>}"
    fi

    # /userdata is the only persistent writable store on the device. If it ever
    # became read-only the app would keep running and silently discard every
    # setting the user saved -- a failure with no symptom until state is lost.
    if echo "$FS_CFG" | grep -qE 'userdata@[^@,"]*@(squashfs|erofs|cramfs|romfs)'; then
        fail "userdata has a read-only filesystem type: $FS_CFG"
    else
        log "userdata keeps a writable filesystem type"
    fi
fi

# ----------------------------------------------------------------- built images
# Only meaningful once firmware packaging has run; silently skipped otherwise so
# this script can also be called right after the kernel build.
IMG="$LUCKFOX_DIR/output/image/rootfs.img"
if [ -f "$IMG" ]; then
    # squashfs magic is "hsqs" (little-endian) at offset 0. On NAND the squashfs
    # is wrapped in a UBI image, whose magic is "UBI#", so accept either and
    # report which -- the point is to catch an ext4/ubifs image slipping through.
    MAGIC="$(head -c 4 "$IMG" | tr -d '\0')"
    case "$MAGIC" in
        hsqs)  log "rootfs.img is a squashfs image ($(du -h "$IMG" | cut -f1))" ;;
        UBI*)  log "rootfs.img is a UBI image wrapping the squashfs volume ($(du -h "$IMG" | cut -f1))" ;;
        *)     fail "rootfs.img has unexpected magic '$MAGIC' — expected squashfs (hsqs) or UBI" ;;
    esac
else
    log "(rootfs.img not built yet — skipping image check)"
fi

# The overlay init script has to be present, or a read-only root ships with
# nothing to make /etc writable.
for r in "$LUCKFOX_DIR/output/out/rootfs_uclibc_rv1106/etc/init.d/S01overlay" \
         "$LUCKFOX_DIR/output/out/rootfs_uclibc_rv1103/etc/init.d/S01overlay"
do
    if [ -f "$r" ]; then
        log "S01overlay is staged in the rootfs"
        FOUND_OVERLAY_SCRIPT=1
        break
    fi
done
if [ -z "${FOUND_OVERLAY_SCRIPT:-}" ]; then
    # Not a hard failure: the rootfs staging directory name varies by SDK
    # revision, so an absent file here is at least as likely to mean "looked in
    # the wrong place" as "not installed".
    log "(could not locate S01overlay in a staged rootfs — check the install step)"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "  [roassert] read-only rootfs verification FAILED" >&2
    exit 1
fi
echo "=== read-only rootfs verified ==="
