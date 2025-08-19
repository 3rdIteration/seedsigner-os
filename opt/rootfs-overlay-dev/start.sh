#!/bin/sh

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"

if [ -d /mnt/microsd/seedsigner-dev ]; then
    echo "Running SeedSigner from external MicroSD source"
    cd /mnt/microsd/seedsigner-dev || exit
    /usr/bin/python3 /usr/bin/microsd_notice.py || true
else
    echo "Running SeedSigner from embedded source"
    cd /opt/src/ || exit
fi

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg

LOG_FILE="/mnt/microsd/main.log"
if [ -d /mnt/microsd ]; then
    /usr/bin/python3 main.py >> "${LOG_FILE}" 2>&1 &
else
    /usr/bin/python3 main.py &
fi

# Import the bundle of keys a few seconds after the app starts
(sleep 5 && /usr/bin/gpg --import /gpg/*.asc) &
