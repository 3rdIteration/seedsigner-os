#!/usr/bin/env bash
#
# strip-kernel-network.sh <KERNEL_DEFCONFIG_PATH> [STRIP_NET] [STRIP_WIFI]
#
# Remove networking and/or the WiFi stack from the Luckfox kernel at BUILD time,
# for non-dev (production) images. Shared by the GitHub Actions build and both
# local Docker builds (os-build.sh / build-local.sh) — change this script, never
# one caller. Must run BEFORE `./build.sh kernel`.
#
# WHY KERNEL-LEVEL: the threat model is root-level code execution (the SeedSigner
# Python app runs as root). Userspace hardening (harden-nondev.sh's loopback-only
# S40network stub, removed telnet init scripts) does NOT stop root — it can just
# run `ifconfig eth0 up; udhcpc`, or `insmod /oem/usr/ko/cfg80211.ko`. Only
# removing the capability from the kernel is a real control: a capability that
# was never compiled in cannot be restored at runtime.
#
#   STRIP_NET  1|0 (default 1) — Group A, gate on: non-dev AND debug_network=off
#   STRIP_WIFI 1|0 (default 1) — Group B, gate on: non-dev
#
# Group B is applied even to debug_network=on builds: the Ethernet debug channel
# is wired Ethernet, no Luckfox build ever uses WiFi.
#
# DO NOT ADD (verified constraints — breaking these breaks the device):
#   * CONFIG_NET / CONFIG_UNIX must stay =y. pcscd talks over an AF_UNIX socket
#     (/run/pcscd/pcscd.comm); dropping CONFIG_NET takes AF_UNIX with it and
#     kills the smartcard stack. (The Pi/La Frite non-dev policy likewise drops
#     INET/IPV6/NETDEVICES/PACKET, not NET.)
#   * CONFIG_MODULES must stay =y — the camera is modular (video_rkcif,
#     video_rkisp and the sensor drivers are all =m).
#   * CONFIG_USB_GADGET must stay =y. It is the sole provider of configfs here
#     (USB_CONFIGFS -> USB_LIBCOMPOSITE, `depends on USB_GADGET`, `select
#     CONFIGFS_FS`). Disabling it silently drops CONFIGFS_FS, so luckfox-config
#     cannot create /sys/kernel/config/device-tree/overlays/, SPI0 is never
#     enabled and THE DISPLAY DIES. ADB is prevented instead by dr_mode=host
#     (host-only dwc3 -> /sys/class/udc empty -> a configfs gadget has nothing
#     to bind to) plus the stubbed adbd from harden-nondev.sh.
#
# NOTE: Kconfig SILENTLY DROPS defconfig lines for symbols that don't exist or
# whose dependencies are unmet (proven by the bootcount work). Setting a symbol
# here does NOT prove it took effect — the callers assert against the GENERATED
# kernel .config after the build. See assert-kernel-network.sh.

set -eu

DEFCONFIG="${1:-}"
STRIP_NET="${2:-1}"
STRIP_WIFI="${3:-1}"

if [ -z "$DEFCONFIG" ] || [ ! -f "$DEFCONFIG" ]; then
    echo "strip-kernel-network: kernel defconfig '${DEFCONFIG:-<empty>}' not found" >&2
    exit 1
fi

log() { echo "  [kstrip] $*"; }

# Force a symbol off, whatever state it's currently in: drop any CONFIG_X=... or
# "# CONFIG_X is not set" line, then append the canonical disabled form. Keeps
# the script idempotent and correct for =y, =m and already-disabled symbols.
disable_sym() {
    local sym="$1"
    local before after
    before="$(grep -cE "^(# )?${sym}[= ]" "$DEFCONFIG" || true)"
    sed -i -E "/^(# )?${sym}[= ]/d" "$DEFCONFIG"
    printf '# %s is not set\n' "$sym" >> "$DEFCONFIG"
    after="$(grep -cE "^# ${sym} is not set$" "$DEFCONFIG" || true)"
    if [ "$before" -gt 0 ]; then
        log "disabled ${sym} (was present)"
    else
        log "disabled ${sym} (added)"
    fi
    [ "$after" -ge 1 ] || { echo "strip-kernel-network: failed to disable $sym" >&2; exit 1; }
}

echo "=== Stripping kernel network/WiFi in $(basename "$DEFCONFIG") (net=$STRIP_NET wifi=$STRIP_WIFI) ==="

if [ "$STRIP_NET" = "1" ]; then
    # Group A — no TCP/IP and no network devices of any kind. Root cannot create
    # an interface or open an AF_INET socket because the stack isn't there.
    disable_sym CONFIG_INET
    disable_sym CONFIG_PACKET
    disable_sym CONFIG_IPV6           # was =m: also stops ipv6.ko shipping to /oem/usr/ko
    disable_sym CONFIG_NETDEVICES
    disable_sym CONFIG_STMMAC_ETH     # the RV1106 Ethernet MAC
    disable_sym CONFIG_RK630_PHY      # its PHY
    disable_sym CONFIG_USB_CONFIGFS_RNDIS  # USB-gadget networking (dep-dropped anyway; explicit)
else
    log "networking RETAINED (debug_network=on) — Ethernet + telnet debug channel kept"
fi

if [ "$STRIP_WIFI" = "1" ]; then
    # Group B — WL_ROCKCHIP is the umbrella menuconfig: it `select`s CFG80211 +
    # MAC80211 and sources every vendor WiFi Kconfig, so disabling it removes the
    # whole 802.11 stack and all 8 vendor drivers (8188fu, 8189fs, aic8800_*,
    # atbm*, ssv6*) that would otherwise be packaged to /oem/usr/ko and be
    # loadable by root. RTL8723BS is a staging driver selected independently.
    disable_sym CONFIG_WL_ROCKCHIP
    disable_sym CONFIG_RTL8723BS
else
    log "WiFi drivers RETAINED"
fi

# Guard the constraints above: this script must never be the reason NET/UNIX/
# MODULES/USB_GADGET got turned off.
for keep in CONFIG_NET CONFIG_UNIX CONFIG_MODULES CONFIG_USB_GADGET; do
    if grep -qE "^# ${keep} is not set$" "$DEFCONFIG"; then
        echo "strip-kernel-network: REFUSING — ${keep} is disabled; see the constraints in this script's header" >&2
        exit 1
    fi
done

log "kept CONFIG_NET/CONFIG_UNIX (AF_UNIX for pcscd), CONFIG_MODULES (camera), CONFIG_USB_GADGET (configfs/display)"
echo "=== kernel network/WiFi strip complete ==="
