#!/bin/sh

DEVNAME="/dev/$MDEV"

DIY_HASH_FILE="/etc/diy-tools.sha256"

if [ $ACTION == "add" ] && [ -n "$DEVNAME" ]; then
    mkdir -p /mnt/microsd
    mount -o sync $DEVNAME /mnt/microsd
    echo -n "add" > /tmp/mdev_fifo
    # Only mount diy-tools.squashfs if its SHA-256 matches a pinned, known-good
    # value. The squashfs lives on the (attacker-controlled) microSD, so a
    # swapped/trojaned image must never be mounted or its binaries executed.
    if [ -f /mnt/microsd/diy-tools.squashfs ]; then
        if [ -f "$DIY_HASH_FILE" ]; then
            actual="$(sha256sum /mnt/microsd/diy-tools.squashfs | cut -d' ' -f1)"
            if awk -F: -v a="$actual" '$2==a{found=1} END{exit !found}' "$DIY_HASH_FILE"; then
                mkdir -p /mnt/diy
                mount /mnt/microsd/diy-tools.squashfs /mnt/diy
            else
                echo "diy-tools.squashfs hash mismatch; refusing to mount" >&2
            fi
        else
            echo "diy-tools.sha256 missing; refusing to mount unverified diy-tools" >&2
        fi
    fi
elif [ $ACTION == "remove" ] && [ -n "$DEVNAME" ]; then
	umount /mnt/diy
	rmdir /mnt/diy
    umount /mnt/microsd
    rmdir /mnt/microsd
    echo -n "remove" > /tmp/mdev_fifo
fi
