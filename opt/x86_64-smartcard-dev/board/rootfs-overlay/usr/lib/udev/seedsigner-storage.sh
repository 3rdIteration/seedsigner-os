#!/bin/sh
# Bridge eudev block hotplug events into the shared SeedSigner mount helper.
#
# /etc/mdev/mdev.sh is written for mdev, which exports ACTION and MDEV (the
# bare kernel name, e.g. "sdb1"). eudev sets ACTION but has no MDEV variable,
# so the rule passes %k through and we map it here. Everything else -- mount
# options, /tmp/mdev_fifo app notification, unmount on remove -- stays in the
# shared helper.
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

# Never treat the boot stick's own FAT partition as a user card: it carries
# the label baked in by genimage, and seedsigner-console mounts it at
# /mnt/bootlog for the debug boot log when the marker file is present. Left
# unguarded, the coldplug "add" of the ESP would win the single
# /mnt/microsd slot and the REMOVE handler would rip the mount away.
if [ "$ACTION" = "add" ] && [ -n "$MDEV" ] && \
   blkid "/dev/$MDEV" 2>/dev/null | grep -q 'LABEL="SEEDSIGNOS"'; then
    exit 0
fi

exec /etc/mdev/mdev.sh
