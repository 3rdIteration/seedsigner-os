#!/bin/sh

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"

if [ -d /mnt/microsd/seedsigner-dev ]; then
    echo "Running SeedSigner from external MicroSD source"
    cd /mnt/microsd/seedsigner-dev
    /usr/bin/python3 /usr/bin/microsd_notice.py || true
else
    echo "Running SeedSigner from embedded source"
    cd /opt/src/
fi

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &

# Import the bundle of keys a few seconds after the app starts
(sleep 5 && /usr/bin/gpg --import /gpg/*.asc) &
