#!/bin/sh

cd /opt/src/

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &

# Set the date to release so that GPG can work
TIME_DEFAULT_FILE="/opt/src/.build_commit_time"
TIME_FALLBACK="2025-02-28 12:00"
TIME_FILE="/mnt/microsd/time.txt"
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
