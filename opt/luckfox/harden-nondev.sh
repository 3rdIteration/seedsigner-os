#!/usr/bin/env bash
#
# harden-nondev.sh <ROOTFS_DIR>
#
# Apply "non-dev" (production) hardening to a *built* Luckfox rootfs so the image
# is air-gapped and headless, matching the non-dev leak-vector policy in AGENTS.md
# (adapted to the Rockchip/Luckfox SDK: no HDMI, and unlike the Pi/La Frite
# profiles the SDK kernel keeps CONFIG_INET — so BOTH the USB gadget AND
# Ethernet (eth0 on Pro Max / Pico Pi) are leak vectors and are closed here in
# userspace). It closes:
#
#   1. Serial login     - console/tty getty | login | shell respawn lines in inittab
#   2. USB ADB + RNDIS  - adbd binaries, S*adb* init scripts, gadget function
#                         config, RkLunch.sh invocations (HARDEN_DISABLE_ADB,
#                         default 1). NEVER touches S50usbdevice/S*usb* init
#                         scripts: S50usbdevice is what mounts configfs, which
#                         luckfox-config needs to enable SPI0 for the display —
#                         removing it blanks the screen. The gadget itself is
#                         already impossible on non-dev because the build sets
#                         dr_mode=host (usb_mode); this is defence in depth.
#   3. Logging daemons  - syslogd / klogd autostart
#   4. Networking       - no interface bring-up: S*network*/S*dhcp* stubbed to
#                         loopback-only, udhcpc neutered, /etc/network/interfaces
#                         reduced to lo, telnet/ssh/dropbear init scripts removed
#                         (HARDEN_DISABLE_NETWORK, default 1; build with
#                         debug_network=on -> 0 to keep Ethernet+telnet for
#                         debugging a non-dev image)
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
# Usage:  [HARDEN_DISABLE_ADB=0|1] [HARDEN_DISABLE_NETWORK=0|1] harden-nondev.sh <ROOTFS_DIR>

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
# USB ADB + RNDIS gadget artifacts (HARDEN_DISABLE_ADB, default 1). The gadget
# is already impossible on non-dev builds because the DTS sets dr_mode=host
# (usb_mode step) — this strips the adb userspace anyway so a non-dev rootfs
# cannot expose adb even if it were ever booted with a gadget-mode DTB.
#
# CRITICAL: do NOT remove /etc/init.d/S*usb* (S50usbdevice, S99usb0config).
# S50usbdevice is the only thing on this SDK that mounts configfs, and the
# Luckfox overlay system (luckfox-config, run by S99luckfoxconfigload) needs
# configfs to enable SPI0 for the display — deleting it blanks the screen
# (this, plus the host-mode hang, is what broke the original disable_adb
# builds). S50usbdevice is separately patched host-aware by the build; the
# no-op stubs below make its gadget path harmless either way.
if [ "${HARDEN_DISABLE_ADB:-1}" = "1" ]; then
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

# Only adb-specific init scripts; S*usb* stays (see header note above).
for f in "$ROOTFS"/etc/init.d/S*adb*; do
    [ -e "$f" ] || continue
    rm -f "$f" && { log "removed ADB init script $(basename "$f")"; removed_any_gadget=1; }
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
    skip "no /oem/usr/bin/RkLunch.sh staged in rootfs (gadget disabled via binaries above)"
fi

[ "$removed_any_gadget" -eq 1 ] || log "WARNING: no USB gadget/adb artifact found to neutralize — verify on-device that 'adb devices' and 'usb0' are absent"
else
    log "USB ADB artifacts left in place (HARDEN_DISABLE_ADB=0) — dr_mode=host still blocks the gadget on non-dev"
fi

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

# --------------------------------------------------------------------------- 4
# Networking (HARDEN_DISABLE_NETWORK, default 1). The SDK kernel keeps
# CONFIG_INET (unlike the Pi/La Frite non-dev kernels), so with nothing done
# here eth0 comes up at boot and broadcasts DHCP (MAC + hostname) on any LAN
# it's plugged into. Close it in userspace: never bring an interface up
# (loopback only), neuter DHCP, and remove every remote-shell daemon.
# debug_network=on builds set HARDEN_DISABLE_NETWORK=0 to keep Ethernet+telnet
# as the debug/recovery channel on a non-dev image.
if [ "${HARDEN_DISABLE_NETWORK:-1}" = "1" ]; then
removed_any_net=0

# Interface bring-up: stub S*network* to loopback-only (keep the filename so
# rcS ordering is untouched; keep lo for any localhost IPC e.g. pcscd).
for f in "$ROOTFS"/etc/init.d/S*network*; do
    [ -e "$f" ] || continue
    printf '#!/bin/sh\n# [nondev] stubbed by harden-nondev.sh: loopback only, no eth0/DHCP\nifconfig lo 127.0.0.1 up 2>/dev/null\nexit 0\n' > "$f" \
        && chmod 0755 "$f" \
        && { log "stubbed $(basename "$f") to loopback-only (no interface bring-up, no DHCP)"; removed_any_net=1; }
done

# DHCP: remove any dedicated dhcp init script and udhcpc's default action
# script, so even a stray udhcpc invocation cannot configure an interface.
for f in "$ROOTFS"/etc/init.d/S*dhcp* "$ROOTFS"/usr/share/udhcpc/default.script "$ROOTFS"/etc/udhcpc.script; do
    [ -e "$f" ] || continue
    rm -f "$f" && { log "removed DHCP helper ${f#$ROOTFS}"; removed_any_net=1; }
done

# /etc/network/interfaces: loopback only (belt-and-suspenders for ifup -a).
IFACES="$ROOTFS/etc/network/interfaces"
if [ -f "$IFACES" ]; then
    printf '# [nondev] loopback only — no external interfaces are configured\nauto lo\niface lo inet loopback\n' > "$IFACES" \
        && { log "reduced /etc/network/interfaces to loopback-only"; removed_any_net=1; }
fi

# Remote shells: telnetd / sshd / dropbear must not start on a shipped image.
for f in "$ROOTFS"/etc/init.d/S*telnet* "$ROOTFS"/etc/init.d/S*sshd* "$ROOTFS"/etc/init.d/S*dropbear*; do
    [ -e "$f" ] || continue
    rm -f "$f" && { log "removed remote-shell init script $(basename "$f")"; removed_any_net=1; }
done

[ "$removed_any_net" -eq 1 ] || log "WARNING: no networking artifact found to neutralize — verify on-device that eth0 stays down and :23/:22 are closed"
else
    log "networking left ENABLED (HARDEN_DISABLE_NETWORK=0) — Ethernet + telnet retained as debug channel (debug_network=on)"
fi

echo "=== non-dev hardening complete ==="
exit 0
