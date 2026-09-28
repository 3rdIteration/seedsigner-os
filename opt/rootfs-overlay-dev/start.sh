#!/bin/sh

# Dev-image start.sh (overrides rootfs-overlay/start.sh via overlay order).
#
# Picks the code to run, in order of preference:
#   1. a checkout on the external MicroSD at /mnt/microsd/seedsigner/src
#      (SeedSigner fork: the MicroSD override, #19);
#   2. a developer checkout on the persistent data partition:
#        git clone https://github.com/SeedSigner/seedsigner.git /mnt/data/seedsigner
#      run with its virtualenv when it has one;
#   3. the code baked into the image at /opt/src.
#
# Networking (wired, usb relay, and wifi from wifi.txt / wpa_supplicant.conf on
# the MicroSD) is brought up by /etc/init.d/S35network, not here.

MICROSD_MOUNTPOINT="/mnt/microsd"
MICROSD_DEV_DIR="$MICROSD_MOUNTPOINT/seedsigner/src"
DEV_DIR="/mnt/data/seedsigner"
DEV_SRC="${DEV_DIR}/src"

# Wait for the external MicroSD to mount before checking for a dev build. It is
# also where time.txt (below) lives.
MAX_WAIT=10
COUNT=0
WAIT_MSG="Waiting for external MicroSD to mount..."

echo "$WAIT_MSG"
/usr/bin/python3 /usr/bin/microsd_notice.py --message "$WAIT_MSG" --duration "$MAX_WAIT" &
NOTICE_PID=$!

while [ $COUNT -lt $MAX_WAIT ] && ! mountpoint -q "$MICROSD_MOUNTPOINT"; do
    COUNT=$((COUNT + 1))
    sleep 1
done

kill "$NOTICE_PID" 2>/dev/null

# S02seedsigner launches this before S30devdata has mounted /mnt/data, so wait
# briefly for that mount too (skipped instantly when the data partition is
# missing or holds no checkout).
if [ -b /dev/mmcblk0p2 ] || [ -e /sys/class/block/mmcblk0p2 ]; then
    WAITED=0
    while [ $WAITED -lt 15 ] && ! grep -q ' /mnt/data ' /proc/mounts; do
        sleep 1
        WAITED=$((WAITED + 1))
    done
fi

PYTHON="/usr/bin/python3"

if mountpoint -q "$MICROSD_MOUNTPOINT" && [ -d "$MICROSD_DEV_DIR" ]; then
    echo "seedsigner: running from external MicroSD ${MICROSD_DEV_DIR}" > /dev/kmsg
    cd "$MICROSD_DEV_DIR" || exit 1
    /usr/bin/python3 /usr/bin/microsd_notice.py || true
elif [ -f "${DEV_SRC}/main.py" ]; then
    echo "seedsigner: running from ${DEV_SRC}" > /dev/kmsg
    # Use the checkout's virtualenv when one exists (either .venv or venv)
    for _venv in "${DEV_DIR}/.venv" "${DEV_DIR}/venv"; do
        if [ -x "${_venv}/bin/python3" ]; then
            PYTHON="${_venv}/bin/python3"
            break
        fi
    done
    cd "${DEV_SRC}" || exit 1
else
    echo "seedsigner: running from /opt/src" > /dev/kmsg
    cd /opt/src/ || exit 1
fi

# Set the date to release so that GPG can work. Must run BEFORE the app is
# launched: the app validates a new GPG key's expiry against the current clock
# and refuses any expiry that is not after it, so anything it timestamps at
# import time needs a real date already in place. It also has to stay AFTER the
# MicroSD mount wait above, or $TIME_FILE below is invisible.
#
# TIME_DEFAULT_FILE deliberately keeps pointing at the EMBEDDED build even when
# this image is running from another checkout -- those have no such file.
TIME_DEFAULT_FILE="/opt/src/.build_commit_time"
TIME_FALLBACK="2025-02-28 12:00"
TIME_FILE="$MICROSD_MOUNTPOINT/time.txt"
TIME_VALUE="$TIME_FALLBACK"

if [ -f "$TIME_DEFAULT_FILE" ]; then
    TIME_FROM_DEFAULT=$(tr -d '\r\n' < "$TIME_DEFAULT_FILE")
    if [ -n "$TIME_FROM_DEFAULT" ]; then
        TIME_VALUE="$TIME_FROM_DEFAULT"
    fi
fi

if [ -f "$TIME_FILE" ]; then
    TIME_FROM_FILE=$(tr -d '\r\n' < "$TIME_FILE")
    if [ -n "$TIME_FROM_FILE" ]; then
        TIME_VALUE="$TIME_FROM_FILE"
    fi
fi

/bin/date -s "$TIME_VALUE" || /bin/date -s "$TIME_FALLBACK"

# exec (not background) so the pid tracked by S02seedsigner / `seedsigner` is
# the python process itself -- that's what makes stop/restart/status reliable.
#exec ${PYTHON} main.py >> /dev/kmsg 2>&1  # version that writes output to dmesg
exec ${PYTHON} main.py
