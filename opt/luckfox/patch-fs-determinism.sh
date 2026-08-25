#!/usr/bin/env bash
#
# patch-fs-determinism.sh <LUCKFOX_PICO_DIR>
#
# Make the SDK's filesystem-image tools deterministic. Run AFTER the SDK is
# checked out and BEFORE `build.sh rootfs` (the pctools step copies these
# scripts from sysdrv/tools/pc into sysdrv/out/pc, so they must be patched at
# the source).
#
# Two builds of identical source produced different images, and comparing them
# byte by byte gave two causes in these tools:
#
# 1. ubinize picks a RANDOM image_seq when not given -Q. It lands in the UBI
#    erase-counter header at bytes 24-27 of every erase block, and the header
#    CRC at 60-63 follows it. That alone made userdata.img differ in 153 bytes
#    of 1.97 MB and oem.img in 2755 of 11.7 MB -- pure header noise over
#    byte-identical payloads.
#
# 2. mksquashfs was called without -all-time/-mkfs-time, so the filesystem
#    creation time and every file mtime went into the image. Because the
#    payload is xz-compressed, a metadata change perturbs the whole compressed
#    stream: rootfs.img differed in 88.57% of its bytes.
#
# Both are pinned to SOURCE_DATE_EPOCH, matching the rest of the build.
#
# The mksquashfs flags are probed rather than assumed: the SDK ships its own
# mksquashfs binary, and -all-time/-mkfs-time only exist in squashfs-tools
# 4.4+. If the bundled binary is older the flags are skipped with a warning
# rather than breaking the build -- an unreproducible image beats no image.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "usage: patch-fs-determinism.sh <LUCKFOX_PICO_DIR>" >&2
    exit 1
fi

EPOCH="${SOURCE_DATE_EPOCH:-0}"
UBI_TOOL="$LUCKFOX_DIR/sysdrv/tools/pc/mtd-utils/mkfs_ubi.sh"
SQUASH_TOOL="$LUCKFOX_DIR/sysdrv/tools/pc/mksquashfs/mkfs_squashfs.sh"
MKSQUASHFS_BIN="$LUCKFOX_DIR/sysdrv/tools/pc/mksquashfs/mksquashfs"

# --- 1. ubinize: pin image_seq -------------------------------------------
if [ ! -f "$UBI_TOOL" ]; then
    echo "patch-fs-determinism: $UBI_TOOL not found" >&2
    exit 1
fi

if grep -q 'MKUBINIZE_TOOL -Q' "$UBI_TOOL"; then
    echo "  ubinize already pinned (idempotent re-run)"
else
    # The invocation is echoed into a fakeroot script, so patch the echoed
    # command rather than a direct call.
    sed -i "s|\$MKUBINIZE_TOOL -o |\$MKUBINIZE_TOOL -Q $EPOCH -o |g" "$UBI_TOOL"
    if ! grep -q 'MKUBINIZE_TOOL -Q' "$UBI_TOOL"; then
        echo "patch-fs-determinism: failed to add -Q to the ubinize call in $UBI_TOOL" >&2
        grep -n 'MKUBINIZE_TOOL' "$UBI_TOOL" >&2 || true
        exit 1
    fi
    echo "  ubinize: image_seq pinned to $EPOCH"
fi

# --- 2. mksquashfs: pin filesystem and file times -------------------------
if [ ! -f "$SQUASH_TOOL" ]; then
    echo "patch-fs-determinism: $SQUASH_TOOL not found" >&2
    exit 1
fi

if grep -q 'mkfs-time' "$SQUASH_TOOL"; then
    echo "  mksquashfs already pinned (idempotent re-run)"
else
    SQUASH_FLAGS=""
    if [ -x "$MKSQUASHFS_BIN" ]; then
        # -help exits non-zero on some builds; capture both streams regardless.
        HELP="$("$MKSQUASHFS_BIN" -help 2>&1 || true)"
        case "$HELP" in
            *-mkfs-time*) SQUASH_FLAGS="$SQUASH_FLAGS -mkfs-time $EPOCH" ;;
        esac
        case "$HELP" in
            *-all-time*)  SQUASH_FLAGS="$SQUASH_FLAGS -all-time $EPOCH" ;;
        esac
    fi

    if [ -z "$SQUASH_FLAGS" ]; then
        echo "  WARNING: bundled mksquashfs supports neither -mkfs-time nor -all-time;" >&2
        echo "  WARNING: rootfs.img will keep build timestamps and stay unreproducible." >&2
    else
        # Append to both branches of the if/else (lz4 and everything else).
        sed -i "s|-comp \$squashfs_compression_args -Xhc|-comp \$squashfs_compression_args$SQUASH_FLAGS -Xhc|g" "$SQUASH_TOOL"
        # The non-lz4 branch appears twice: once as the echoed log line, which
        # ends with a quote, and once as the command, which ends the line.
        sed -i "s|-comp \$squashfs_compression_args\"|-comp \$squashfs_compression_args$SQUASH_FLAGS\"|g" "$SQUASH_TOOL"
        sed -i "s|-comp \$squashfs_compression_args\$|-comp \$squashfs_compression_args$SQUASH_FLAGS|g" "$SQUASH_TOOL"
        if ! grep -q 'mkfs-time\|all-time' "$SQUASH_TOOL"; then
            echo "patch-fs-determinism: failed to add time flags to $SQUASH_TOOL" >&2
            grep -n 'MKSQUASHFS_TOOL' "$SQUASH_TOOL" >&2 || true
            exit 1
        fi
        echo "  mksquashfs: times pinned ($SQUASH_FLAGS)"
    fi
fi

echo "patch-fs-determinism: done (SOURCE_DATE_EPOCH=$EPOCH)"
