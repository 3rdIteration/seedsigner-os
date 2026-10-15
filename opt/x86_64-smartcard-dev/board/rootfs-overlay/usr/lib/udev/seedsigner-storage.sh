#!/bin/sh
# Bridge eudev block hotplug events into the shared SeedSigner mount helper.
#
# /etc/mdev/mdev.sh is written for mdev, which exports ACTION and MDEV (the
# bare kernel name, e.g. "sdb1"). eudev sets ACTION but has no MDEV variable,
# so the rule passes %k through and we map it here. Mount options and the
# /tmp/mdev_fifo app notification stay in the shared helper; this wrapper
# adds what a PC with several USB storage devices needs on top of it.
#
# SS_SKIP_DIY: there is no pinned diy-tools squashfs hash for x86_64
# (opt/rootfs-overlay/etc/diy-tools.sha256 keys armhf/aarch64 only), so tell
# the helper to stop after mounting the card instead of hashing a squashfs
# that will never verify on this architecture.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
ACTION="$1"
MDEV="$2"
SS_SKIP_DIY=1
export ACTION MDEV SS_SKIP_DIY

[ -n "$MDEV" ] || exit 0
DEV="/dev/$MDEV"
MOUNT_POINT=/mnt/microsd
FSCK_LOG=/tmp/fsck.log

# Is $DEV mounted at mountpoint $1? On "remove" the device node may already
# be gone, so this reads /proc/mounts rather than probing the device.
dev_mounted_at() {
    awk -v d="$DEV" -v m="$1" '$1==d && $2==m {f=1} END {exit !f}' /proc/mounts
}

if [ "$ACTION" = "remove" ]; then
    # The boot stick's FAT, held by the dev boot log. The system runs from
    # RAM, so pulling the stick is allowed; drop the dead mount.
    if dev_mounted_at /mnt/bootlog; then
        umount -l /mnt/bootlog 2>/dev/null
        exit 0
    fi
    # Only the device actually mounted at /mnt/microsd may unmount it: pulling
    # some other stick (the boot stick included) must not unmount the card.
    dev_mounted_at "$MOUNT_POINT" || exit 0
    # Lazy: the device is already gone, and a plain umount fails while the
    # app holds a file open, leaving a dead mount behind that the next card
    # would be stacked on (FAT "unable to read inode block" errors).
    umount -l "$MOUNT_POINT" 2>/dev/null
    exec /etc/mdev/mdev.sh
fi

[ "$ACTION" = "add" ] || exit 0

BLKID="$(blkid "$DEV" 2>/dev/null)"

# Never treat the boot stick's own FAT partition as a user card: it carries
# the label baked in by genimage, and seedsigner-console mounts it at
# /mnt/bootlog for the debug boot log when the marker file is present. Left
# unguarded, the coldplug "add" of the ESP would win the single
# /mnt/microsd slot.
case "$BLKID" in
    *'LABEL="SEEDSIGNOS"'*) exit 0 ;;
esac

# A card pulled without a matching remove (or while busy) can leave a
# mount whose device no longer exists. Clear it so the new card is not
# mounted on top of a dead filesystem; a live card stays put.
OLD_DEV="$(awk -v m="$MOUNT_POINT" '$2==m {d=$1} END {print d}' /proc/mounts)"
if [ -n "$OLD_DEV" ] && [ ! -b "$OLD_DEV" ]; then
    umount -l "$MOUNT_POINT" 2>/dev/null
fi

# Repair FAT before mounting. A card that was powered off while mounted (any
# reboot) carries the dirty bit; fsck.fat -a clears it and fixes what it
# safely can, so the card mounts clean and settings.json stays readable.
case "$BLKID" in
    *'TYPE="vfat"'*)
        echo "$(date) fsck.fat -a $DEV" >> "$FSCK_LOG"
        fsck.fat -a -w "$DEV" >> "$FSCK_LOG" 2>&1
        echo "$(date) fsck.fat exit $?" >> "$FSCK_LOG"
        ;;
esac

exec /etc/mdev/mdev.sh
