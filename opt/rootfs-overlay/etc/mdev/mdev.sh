#!/bin/sh

DEVNAME="/dev/$MDEV"
DIY_HASH_FILE="/etc/diy-tools.sha256"
LOG=/tmp/diy-mount.log

# Append a timestamped line to the log.
log() { echo "$(date) $*" >> "$LOG"; }

# Emit a machine-readable result block for the SeedSigner app to parse and
# report. The app reads /tmp/diy-mount.log, takes the last "=== diy-tools
# result ===" block, and reports status + reason (and computed/pinned hashes
# when the hash was not recognised).
#   usage: emit_result <status> <reason> [key=value ...]
emit_result() {
    local status="$1" reason="$2"; shift 2
    {
        echo "=== diy-tools result ==="
        echo "status=$status"
        echo "reason=$reason"
        for kv in "$@"; do echo "$kv"; done
    } >> "$LOG"
}

if [ "$ACTION" = "add" ] && [ -n "$DEVNAME" ]; then
    log "ADD $DEVNAME: mounting microsd"
    mkdir -p /mnt/microsd
    if ! mount -o sync "$DEVNAME" /mnt/microsd 2>>"$LOG"; then
        emit_result MICROSD_MOUNT_FAILED "could not mount microSD partition $DEVNAME" dev="$DEVNAME"
        exit 1
    fi

    # Notify userspace that a microSD was inserted.
    echo -n "add" > /tmp/mdev_fifo 2>/dev/null

    # Locate sha256sum (minimal PATH under mdev).
    SHA256SUM="$(command -v sha256sum 2>/dev/null || echo /usr/bin/sha256sum)"

    # Pick the pinned-hash key for this device's architecture.
    case "$(uname -m)" in
        aarch64) key=aarch64 ;;
        *) key=armhf ;;
    esac

    # Read the squashfs directly via open(). Do NOT gate on [ -f ]: on a 32-bit
    # kernel, stat() of a FAT file whose on-disk date is post-2038 (e.g. 2098)
    # returns EOVERFLOW and would wrongly report the file missing; open()/read()
    # succeed regardless, so verify by hashing the file directly instead.
    actual="$("$SHA256SUM" /mnt/microsd/diy-tools.squashfs 2>/tmp/diy-sha.err | cut -d' ' -f1)"

    if [ -z "$actual" ]; then
        detail="$(tr '\n' ' ' < /tmp/diy-sha.err 2>/dev/null)"
        emit_result NOT_PRESENT "no readable diy-tools.squashfs on microSD" arch="$key" detail="$detail"
        exit 0
    fi

    if [ ! -f "$DIY_HASH_FILE" ]; then
        emit_result HASH_FILE_MISSING "pinned hash file $DIY_HASH_FILE not found in rootfs" arch="$key" computed="$actual"
        exit 0
    fi

    pinned="$(awk -F: -v k="$key" '$1==k{print $2}' "$DIY_HASH_FILE")"
    log "arch=$(uname -m) key=$key computed=$actual pinned=$pinned"

    if [ -z "$pinned" ]; then
        emit_result NO_PINNED_HASH "no pinned hash for arch $key in $DIY_HASH_FILE" arch="$key" computed="$actual"
        exit 0
    fi

    if [ "$actual" != "$pinned" ]; then
        emit_result REFUSED_HASH_MISMATCH "diy-tools.squashfs hash does not match the pinned value; refusing to mount an unverified image" \
            arch="$key" computed="$actual" pinned="$pinned"
        exit 0
    fi

    mkdir -p /mnt/diy
    if ! mount /mnt/microsd/diy-tools.squashfs /mnt/diy 2>>"$LOG"; then
        emit_result MOUNT_FAILED "hash verified but mounting the squashfs onto /mnt/diy failed" arch="$key" computed="$actual" pinned="$pinned"
        exit 0
    fi

    # Informational: confirm expected top-level entries are present.
    missing=""
    for p in jdk ant Satochip-DIY; do
        [ -e "/mnt/diy/$p" ] || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        emit_result OK "mounted at /mnt/diy, but expected entries missing:$missing" arch="$key" computed="$actual" pinned="$pinned" mount=/mnt/diy
    else
        emit_result OK "diy-tools verified and mounted at /mnt/diy" arch="$key" computed="$actual" pinned="$pinned" mount=/mnt/diy
    fi

elif [ "$ACTION" = "remove" ] && [ -n "$DEVNAME" ]; then
    log "REMOVE $DEVNAME: unmounting"
    umount /mnt/diy 2>/dev/null
    rmdir /mnt/diy 2>/dev/null
    umount /mnt/microsd 2>/dev/null
    rmdir /mnt/microsd 2>/dev/null
    echo -n "remove" > /tmp/mdev_fifo 2>/dev/null
fi
