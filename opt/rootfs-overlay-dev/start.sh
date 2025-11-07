#!/bin/sh

# Wait for the external MicroSD to mount before checking for a dev build.
MICROSD_MOUNTPOINT="/mnt/microsd"
MICROSD_DEV_DIR="$MICROSD_MOUNTPOINT/seedsigner/src"
MAX_WAIT=10
COUNT=0
WAIT_MSG="Waiting for external MicroSD to mount..."

# Notify on both console and display while we wait for the MicroSD card
if [ -x /usr/bin/microsd_notice.py ]; then
    echo "$WAIT_MSG"
    /usr/bin/python3 /usr/bin/microsd_notice.py --message "$WAIT_MSG" --duration "$MAX_WAIT" &
    NOTICE_PID=$!
else
    NOTICE_PID=""
fi

while [ $COUNT -lt $MAX_WAIT ] && ! mountpoint -q "$MICROSD_MOUNTPOINT"; do
    COUNT=$((COUNT + 1))
    sleep 1
done

if [ -n "$NOTICE_PID" ]; then
    kill "$NOTICE_PID" 2>/dev/null || true
fi

WIFI_CONF="$MICROSD_MOUNTPOINT/wifi.txt"

# Bring up any wired interfaces with a persistent DHCP client
for i in $(seq 1 5); do
    ETH_IFACES=$(ls /sys/class/net 2>/dev/null | grep '^eth' || true)
    if [ -n "$ETH_IFACES" ]; then
        for IFACE in $ETH_IFACES; do
            ifconfig "$IFACE" up 2>/dev/null || true
            # Run udhcpc in the background so it keeps trying even if no link yet
            udhcpc -i "$IFACE" -b -t 0 -s /usr/share/udhcpc/default.script >/dev/null 2>&1 &
        done
        break
    fi
    sleep 1
done

# Configure Wi-Fi from MicroSD credentials if present
if [ -f "$WIFI_CONF" ]; then
    WIFI_SSID=$(sed -n '1p' "$WIFI_CONF" | tr -d '\r\n')
    WIFI_PSK=$(sed -n '2p' "$WIFI_CONF" | tr -d '\r\n')
    cat > /etc/wpa_supplicant.conf <<EOF2
country=CA
network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PSK"
}
EOF2
    modprobe brcmfmac 2>/dev/null || true
    for i in $(seq 1 5); do
        if ip link show wlan0 >/dev/null 2>&1; then
            ifconfig wlan0 up 2>/dev/null || true
            wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
            # Launch udhcpc in persistent background mode for Wi-Fi
            udhcpc -i wlan0 -b -t 0 -s /usr/share/udhcpc/default.script >/dev/null 2>&1 &
            break
        fi
        sleep 1
    done
fi

if mountpoint -q "$MICROSD_MOUNTPOINT" && [ -d "$MICROSD_DEV_DIR" ]; then
    echo "Running SeedSigner from external MicroSD source"
    cd "$MICROSD_DEV_DIR" || exit 1
    if [ -x /usr/bin/microsd_notice.py ]; then
        /usr/bin/python3 /usr/bin/microsd_notice.py || true
    fi
else
    echo "Running SeedSigner from embedded source"
    cd /opt/src/ || exit 1
fi

#/usr/bin/python3 main.py >> /dev/kmsg 2>&1 &  # version that writes output to dmesg
/usr/bin/python3 main.py &

# Set the date to release so that GPG can work
/bin/date -s "2025-02-28 12:00"
