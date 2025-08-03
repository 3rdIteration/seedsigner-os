#!/bin/sh

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"

# Import the bundle of keys 
/usr/bin/gpg --import /gpg/*.asc

cd /opt/src/

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &
