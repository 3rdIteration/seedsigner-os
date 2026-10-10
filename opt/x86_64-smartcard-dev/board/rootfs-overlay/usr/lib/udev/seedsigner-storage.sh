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
exec /etc/mdev/mdev.sh
