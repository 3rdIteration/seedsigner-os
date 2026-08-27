#!/bin/sh

DEVNAME="/dev/$MDEV"
DIY_HASH_FILE="/etc/diy-tools.sha256"

if [ "$ACTION" = "add" ] && [ -n "$DEVNAME" ]; then
    mkdir -p /mnt/microsd
    mount -o sync $DEVNAME /mnt/microsd 2>/tmp/diy-mount.err
    if [ $? -ne 0 ]; then
        echo "$(date) ADD $DEVNAME: FAILED to mount microsd: $(cat /tmp/diy-mount.err)" >> /tmp/diy-mount.log
        exit 1
    fi
    LOG=/mnt/microsd/diy-mount.log
    echo "$(date) ADD $DEVNAME: microsd mounted" >> "$LOG"

    # Notify userspace that a microSD was inserted.
    echo -n "add" > /tmp/mdev_fifo

    # Locate sha256sum (minimal PATH under mdev).
    SHA256SUM="$(command -v sha256sum 2>/dev/null || echo /usr/bin/sha256sum)"

    # Read the squashfs directly via open(). Do NOT gate on [ -f ]: on a 32-bit
    # kernel, stat() of a FAT file whose on-disk date is post-2038 (e.g. 2098,
    # which is what SOURCE_DATE_EPOCH=0 becomes when the buildroot mtools wraps
    # the pre-1980 date) returns EOVERFLOW, so a plain existence test wrongly
    # reports the file as missing. open()/read() still succeed, so verify by
    # hashing the file directly instead.
    actual="$("$SHA256SUM" /mnt/microsd/diy-tools.squashfs 2>/tmp/diy-sha.err | cut -d' ' -f1)"
    if [ -z "$actual" ]; then
        echo "$(date) diy-tools.squashfs NOT present/unreadable on microsd: $(cat /tmp/diy-sha.err)" >> "$LOG"
        ls -la /mnt/microsd >> "$LOG" 2>&1
        exit 0
    fi

    if [ ! -f "$DIY_HASH_FILE" ]; then
        echo "$(date) REFUSED: $DIY_HASH_FILE missing" >> "$LOG"
        exit 0
    fi

    # Pick the pinned hash for this device's architecture.
    case "$(uname -m)" in
        aarch64) key=aarch64 ;;
        *) key=armhf ;;
    esac
    pinned="$(awk -F: -v k="$key" '$1==k{print $2}' "$DIY_HASH_FILE")"
    echo "$(date) arch=$(uname -m) key=$key computed=$actual pinned=$pinned" >> "$LOG"

    if [ "$actual" != "$pinned" ]; then
        echo "$(date) DIY REFUSED: hash mismatch (computed != pinned)" >> "$LOG"
        exit 0
    fi

    mkdir -p /mnt/diy
    mount /mnt/microsd/diy-tools.squashfs /mnt/diy 2>>"$LOG"
    if [ $? -eq 0 ]; then
        echo "$(date) DIY OK: /mnt/diy mounted" >> "$LOG"
        for p in jdk ant Satochip-DIY; do
            if [ -e /mnt/diy/$p ]; then
                echo "$(date) present: /mnt/diy/$p" >> "$LOG"
            else
                echo "$(date) MISSING: /mnt/diy/$p" >> "$LOG"
            fi
        done
    else
        echo "$(date) DIY FAIL: mount /mnt/diy returned $?" >> "$LOG"
    fi
elif [ "$ACTION" = "remove" ] && [ -n "$DEVNAME" ]; then
    umount /mnt/diy 2>/dev/null; echo "$(date) remove: umount /mnt/diy rc=$?" >> /tmp/diy-mount.log 2>/dev/null
    rmdir /mnt/diy 2>/dev/null
    umount /mnt/microsd 2>/dev/null
    rmdir /mnt/microsd 2>/dev/null
    echo -n "remove" > /tmp/mdev_fifo
fi
