#!/bin/sh

DEVNAME="/dev/$MDEV"

if [ $ACTION == "add" ] && [ -n "$DEVNAME" ]; then
    mkdir -p /mnt/microsd
    mount -o sync $DEVNAME /mnt/microsd
    echo -n "add" > /tmp/mdev_fifo
	mkdir -p /mnt/diy
	mount /mnt/microsd/diy-tools.squashfs /mnt/diy
elif [ $ACTION == "remove" ] && [ -n "$DEVNAME" ]; then
    umount /mnt/microsd
    rmdir /mnt/microsd
    echo -n "remove" > /tmp/mdev_fifo
	umount /mnt/diy
	rmdir /mnt/diy
fi
