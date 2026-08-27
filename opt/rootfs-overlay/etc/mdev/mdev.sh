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
            # Pick the pinned hash for this device's architecture.
            case "$(uname -m)" in
                aarch64) key=aarch64 ;;
                *) key=armhf ;;
            esac
            pinned="$(awk -F: -v k="$key" '$1==k{print $2}' "$DIY_HASH_FILE")"
            if [ -n "$pinned" ]; then
                # Verify with `sha256sum -c` -- the same busybox-safe check
                # SeedSigner's gpg code uses (gpg_views.py). mdev runs with a
                # minimal PATH, so locate sha256sum explicitly, then verify a
                # relative checksum file from inside the mounted microSD (the
                # exact pattern gpg_views.py relies on).
                SHA256SUM="$(command -v sha256sum 2>/dev/null || echo /usr/bin/sha256sum)"
                # Write the checksum file to /tmp and verify from inside the
                # mount so the relative path resolves (mirrors gpg_views.py,
                # which runs sha256sum -c with cwd at the file).
                printf '%s  diy-tools.squashfs\n' "$pinned" > /tmp/diy-tools.sha256
                ( cd /mnt/microsd && "$SHA256SUM" -c /tmp/diy-tools.sha256 >/dev/null 2>&1 )
                if [ $? -eq 0 ]; then
                    mkdir -p /mnt/diy
                    mount /mnt/microsd/diy-tools.squashfs /mnt/diy
                else
                    echo "diy-tools.squashfs hash mismatch; refusing to mount" >&2
                fi
                rm -f /tmp/diy-tools.sha256
            else
                echo "no pinned hash for $key; refusing to mount" >&2
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
