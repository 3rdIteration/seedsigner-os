#!/usr/bin/env bash
#
# ss-fs-normalise.sh mtimes   <DIR>  <EPOCH>
# ss-fs-normalise.sh sqfs-time <FILE> <EPOCH>
#
# The two operations the SDK's bundled mksquashfs (4.3-git, 2014) cannot do
# itself, because -all-time and -mkfs-time only arrived in squashfs-tools 4.4.
#
# patch-fs-determinism.sh injects calls to this script into the fakeroot script
# that mkfs_ubi.sh generates -- once before mksquashfs runs and once after. It
# exists as a real file rather than as text echoed into that script because the
# superblock write needs binary escapes, and threading those through awk inside
# sh inside a generated script mangles them into literal NUL bytes.
#
#   mtimes     set every mtime under DIR to EPOCH (the -all-time equivalent).
#              Matters more than it sounds: the squashfs payload is
#              xz-compressed, so varying mtimes perturb the whole compressed
#              stream rather than a few inode bytes.
#
#   sqfs-time  overwrite the squashfs superblock's mkfs_time, a little-endian
#              u32 at offset 8 (magic 0-3, inodes 4-7, mkfs_time 8-11). The
#              magic is checked first so a wrong path cannot silently corrupt
#              something else. Nothing checksums this field.

set -eu

MODE="${1:-}"
TARGET="${2:-}"
EPOCH="${3:-0}"

if [ -z "$MODE" ] || [ -z "$TARGET" ]; then
    echo "usage: ss-fs-normalise.sh <mtimes|sqfs-time> <path> [epoch]" >&2
    exit 1
fi

case "$MODE" in

mtimes)
    if [ ! -d "$TARGET" ]; then
        echo "ss-fs-normalise: '$TARGET' is not a directory -- skipping mtime pin" >&2
        exit 0
    fi
    # -h so symlinks get their own timestamp set rather than their target's.
    find "$TARGET" -exec touch -h -d "@$EPOCH" {} + 2>/dev/null || true
    echo "ss-fs-normalise: mtimes under $TARGET pinned to $EPOCH"
    ;;

sqfs-time)
    if [ ! -f "$TARGET" ]; then
        echo "ss-fs-normalise: '$TARGET' not found -- skipping mkfs_time pin" >&2
        exit 0
    fi

    magic="$(head -c 4 "$TARGET" | od -An -tx1 | tr -d ' \n')"
    if [ "$magic" != "68737173" ]; then   # 'hsqs' little-endian squashfs magic
        echo "ss-fs-normalise: $TARGET is not squashfs (magic $magic) -- skipping" >&2
        exit 0
    fi

    b0=$(( EPOCH & 255 ))
    b1=$(( (EPOCH >> 8) & 255 ))
    b2=$(( (EPOCH >> 16) & 255 ))
    b3=$(( (EPOCH >> 24) & 255 ))
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' "$b0" "$b1" "$b2" "$b3")" \
        | dd of="$TARGET" bs=1 seek=8 count=4 conv=notrunc status=none
    echo "ss-fs-normalise: $TARGET mkfs_time set to $EPOCH"
    ;;

*)
    echo "ss-fs-normalise: unknown mode '$MODE'" >&2
    exit 1
    ;;
esac
