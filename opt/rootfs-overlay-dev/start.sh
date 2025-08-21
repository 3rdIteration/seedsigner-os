#!/bin/sh

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"

# Wait for the external MicroSD to be mounted before checking for a dev build.
MICROSD_DEV_DIR="/mnt/microsd/seedsigner-dev"
MAX_WAIT=10
COUNT=0
while [ $COUNT -lt $MAX_WAIT ] && [ ! -d "$MICROSD_DEV_DIR" ]; do
    COUNT=$((COUNT + 1))
    sleep 1
done

if [ -d "$MICROSD_DEV_DIR" ]; then
    echo "Running SeedSigner from external MicroSD source"
    cd "$MICROSD_DEV_DIR" || exit 1
    /usr/bin/python3 /usr/bin/microsd_notice.py || true
else
    echo "Running SeedSigner from embedded source"
    cd /opt/src/ || exit 1
fi

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &

# Import the bundle of keys a few seconds after the app starts
(sleep 5 && /usr/bin/gpg --import /gpg/*.asc) &
