#!/bin/sh

DEVNAME="/dev/$MDEV"
DIY_HASH_FILE="/etc/diy-tools.sha256"

if [ $ACTION == "add" ] && [ -n "$DEVNAME" ]; then
    mkdir -p /mnt/microsd
    mount -o sync $DEVNAME /mnt/microsd 2>/tmp/diy-mount.err
    if [ $? -ne 0 ]; then
        echo "$(date) ADD $DEVNAME: FAILED to mount microsd: $(cat /tmp/diy-mount.err)" >> /tmp/diy-mount.log
        exit 1
    fi
    LOG=/mnt/microsd/diy-mount.log
    echo "$(date) ADD $DEVNAME: microsd mounted" >> "$LOG"
    echo -n "add" > /tmp/mdev_fifo

    if [ -f /mnt/microsd/diy-tools.squashfs ]; then
        echo "$(date) diy-tools.squashfs present on microsd" >> "$LOG"
        if [ -f "$DIY_HASH_FILE" ]; then
            echo "$(date) $DIY_HASH_FILE present" >> "$LOG"
            # Pick the pinned hash for this device's architecture.
            case "$(uname -m)" in
                aarch64) key=aarch64 ;;
                *) key=armhf ;;
            esac
            pinned="$(awk -F: -v k="$key" '$1==k{print $2}' "$DIY_HASH_FILE")"
            echo "$(date) arch=$(uname -m) key=$key pinned=$pinned" >> "$LOG"

            # Verify with `sha256sum -c` -- the same busybox-safe check
            # SeedSigner's gpg code uses (gpg_views.py). mdev runs with a
            # minimal PATH, so locate sha256sum explicitly, then verify a
            # relative checksum file from inside the mounted microSD.
            SHA256SUM="$(command -v sha256sum 2>/dev/null || echo /usr/bin/sha256sum)"
            echo "$(date) sha256sum=$SHA256SUM" >> "$LOG"
            actual="$("$SHA256SUM" /mnt/microsd/diy-tools.squashfs 2>/tmp/diy-sha.err | cut -d' ' -f1)"
            echo "$(date) computed=$actual" >> "$LOG"
            if [ -z "$actual" ]; then
                echo "$(date) sha256sum produced no hash: $(cat /tmp/diy-sha.err)" >> "$LOG"
            fi

            printf '%s  diy-tools.squashfs\n' "$pinned" > /tmp/diy-tools.sha256
            ( cd /mnt/microsd && "$SHA256SUM" -c /tmp/diy-tools.sha256 ) >> "$LOG" 2>&1
            if [ $? -eq 0 ]; then
                mkdir -p /mnt/diy
                mount /mnt/microsd/diy-tools.squashfs /mnt/diy 2>>"$LOG"
                if [ $? -eq 0 ]; then
                    echo "$(date) DIY OK: /mnt/diy mounted" >> "$LOG"
                else
                    echo "$(date) DIY FAIL: mount /mnt/diy returned $?" >> "$LOG"
                fi
            else
                echo "$(date) DIY REFUSED: hash mismatch (computed != pinned)" >> "$LOG"
            fi
            rm -f /tmp/diy-tools.sha256
        else
            echo "$(date) REFUSED: $DIY_HASH_FILE missing" >> "$LOG"
        fi
    else
        echo "$(date) diy-tools.squashfs NOT present on microsd" >> "$LOG"
    fi
elif [ $ACTION == "remove" ] && [ -n "$DEVNAME" ]; then
    umount /mnt/diy 2>/dev/null; echo "$(date) remove: umount /mnt/diy rc=$?" >> /tmp/diy-mount.log 2>/dev/null
    rmdir /mnt/diy 2>/dev/null
    umount /mnt/microsd 2>/dev/null
    rmdir /mnt/microsd 2>/dev/null
    echo -n "remove" > /tmp/mdev_fifo
fi
