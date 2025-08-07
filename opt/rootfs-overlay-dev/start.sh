#!/bin/sh

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"

# Import the bundle of keys 
/usr/bin/gpg --import /gpg/*.asc

if [ -d /mnt/microsd/seedsigner-dev ]; then
    cd /mnt/microsd/seedsigner-dev
    /usr/bin/python3 /usr/bin/microsd_notice.py || true
else
    cd /opt/src/
fi

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &
