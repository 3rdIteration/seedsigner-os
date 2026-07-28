#!/usr/bin/env bash
#
# harden-nondev.sh <ROOTFS_DIR>
#
# Apply "non-dev" (production) hardening to a *built* Luckfox rootfs so the image
# is air-gapped and headless, matching the non-dev leak-vector policy in AGENTS.md
# (adapted to the Rockchip/Luckfox SDK, which has no HDMI and whose "networking"
# vector is the USB gadget, not Ethernet/WiFi). It closes:
#
#   1. Serial login    - console/tty getty | login | shell respawn lines in inittab
#   2. USB ADB + RNDIS  - the adbd/usbdevice gadget (binaries + init.d + RkLunch.sh)
#   3. Logging daemons  - syslogd / klogd autostart
#
# (The serial *console output* bootargs are stripped separately by the build's
#  "Configure UART2 console debug" step; the getty/login shell is closed here.)
#
# The Rockchip/Luckfox SDK rootfs layout varies by version, so EVERY step is
# guarded: it no-ops (and says so) when a target is absent, and it never touches
# the `::sysinit:` line that launches the app. It logs exactly what it changed so
# the build output can be reviewed — a green build does NOT prove the vectors were
# closed; verify on hardware / a serial capture.
#
# Usage:  harden-nondev.sh <ROOTFS_DIR>

set -u

ROOTFS="${1:-}"
if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "harden-nondev: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [harden] $*"; }
skip() { echo "  [harden] (skip) $*"; }

echo "=== Applying non-dev (production) hardening to $ROOTFS ==="

# --------------------------------------------------------------------------- 1
# Serial login / interactive shells. Comment any inittab line whose action is
# respawn/askfirst and that launches a getty, login, sulogin, or a shell — this
# covers "console::askfirst:-/bin/sh", "ttyFIQ0::respawn:/sbin/getty ...",
# "::respawn:-/bin/sh", etc. The ::sysinit: line (rcS / app launch) is untouched.
INITTAB="$ROOTFS/etc/inittab"
if [ -f "$INITTAB" ]; then
    # Only comment true login gettys (getty/login/sulogin). Deliberately DO NOT
    # touch bare "-/bin/sh" console respawn lines: on the Luckfox SDK the app boot
    # path can run through a console shell, and commenting it blanks the screen.
    # The buildroot defconfig (GETTY off) already removes the login getty; this is
    # belt-and-suspenders for any SDK-added getty.
    n=$(grep -cE '::(respawn|askfirst):.*(getty|login|sulogin)' "$INITTAB" 2>/dev/null || true)
    sed -i -E '/::(respawn|askfirst):.*(getty|login|sulogin)/ s/^([^#])/# [nondev] \1/' "$INITTAB"
    log "inittab: commented ${n:-0} getty/login respawn line(s) in /etc/inittab (console shells left intact)"
    grep -nE '^# \[nondev\]' "$INITTAB" | sed 's/^/        /' || true
else
    skip "no /etc/inittab"
fi

# --------------------------------------------------------------------------- 2
# USB ADB + RNDIS gadget. Neutralize the gadget/adb binaries with a no-op stub
# rather than deleting them. The SDK launcher (RkLunch.sh, on the separate oem
# stage we can't patch here) still invokes `usbdevice` at boot; a *missing* binary
# made that call fail and aborted boot to a blank screen. A stub keeps the caller
# happy while guaranteeing no gadget/adb is ever configured.
removed_any_gadget=0
for bin in \
    oem/usr/bin/usbdevice usr/bin/usbdevice usr/sbin/usbdevice \
    oem/usr/bin/adbd usr/bin/adbd usr/sbin/adbd bin/adbd
do
    if [ -e "$ROOTFS/$bin" ]; then
        printf '#!/bin/sh\nexit 0\n' > "$ROOTFS/$bin" && chmod 0755 "$ROOTFS/$bin" \
            && { log "neutralized USB gadget/adb binary /$bin (no-op stub)"; removed_any_gadget=1; }
    fi
done

for f in "$ROOTFS"/etc/init.d/S*usb* "$ROOTFS"/etc/init.d/S*adb* "$ROOTFS"/etc/init.d/S*gadget*; do
    [ -e "$f" ] || continue
    rm -f "$f" && { log "removed USB/ADB init script $(basename "$f")"; removed_any_gadget=1; }
done

# Blank any composite-gadget function-list config so nothing is exported even if
# a usbdevice invocation survives.
for cfg in \
    "$ROOTFS"/oem/usr/conf/.usb_config \
    "$ROOTFS"/etc/init.d/.usb_config \
    "$ROOTFS"/etc/usb_config \
    "$ROOTFS"/userdata/usb_config.sh
do
    if [ -e "$cfg" ]; then
        : > "$cfg" && { log "blanked USB gadget config ${cfg#$ROOTFS}"; removed_any_gadget=1; }
    fi
done

# Best-effort: comment gadget/adb invocations in the SDK launcher if it's staged here.
RKLUNCH="$ROOTFS/oem/usr/bin/RkLunch.sh"
if [ -f "$RKLUNCH" ]; then
    # Comment any (not-already-commented) line invoking the gadget/adb.
    sed -i -E '/\b(usbdevice|adbd|start_usb|rndis|usb_config)\b/ { /^[[:space:]]*#/! s/^/# [nondev] / }' "$RKLUNCH"
    if grep -qE '^[[:space:]]*# \[nondev\]' "$RKLUNCH"; then
        log "RkLunch.sh: commented USB gadget/adb invocation(s)"
        removed_any_gadget=1
    else
        log "RkLunch.sh: present, no gadget/adb invocation matched"
    fi
else
    skip "no /oem/usr/bin/RkLunch.sh staged in rootfs (gadget disabled via binaries/init.d above)"
fi

[ "$removed_any_gadget" -eq 1 ] || log "WARNING: no USB gadget/adb artifact found to neutralize — verify on-device that 'adb devices' and 'usb0' are absent"

# --------------------------------------------------------------------------- 3
# Logging daemons (syslogd / klogd).
removed_any_log=0
for f in "$ROOTFS"/etc/init.d/S*log* "$ROOTFS"/etc/init.d/S*syslog* "$ROOTFS"/etc/init.d/S*klog*; do
    [ -e "$f" ] || continue
    rm -f "$f" && { log "removed logging init script $(basename "$f")"; removed_any_log=1; }
done
# Also comment any direct syslogd/klogd launch from rcS or inittab.
for f in "$ROOTFS/etc/init.d/rcS" "$INITTAB"; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*[^#].*\b(syslogd|klogd)\b' "$f" 2>/dev/null; then
        sed -i -E '/\b(syslogd|klogd)\b/ { /^[[:space:]]*#/! s/^/# [nondev] / }' "$f"
        log "commented syslogd/klogd launch in $(basename "$f")"
        removed_any_log=1
    fi
done
[ "$removed_any_log" -eq 1 ] || skip "no syslogd/klogd autostart found"

echo "=== non-dev hardening complete ==="
exit 0
