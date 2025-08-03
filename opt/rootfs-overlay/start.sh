#!/bin/sh

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"

# Import the bundle of keys
/usr/bin/gpg --import /gpg/*.asc

cd /opt/src/

# Ensure OpenSSL loads the legacy provider so RIPEMD160 is available
export OPENSSL_CONF=/etc/ssl/openssl.cnf

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &
