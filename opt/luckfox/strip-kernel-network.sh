#!/usr/bin/env bash
#
# strip-kernel-network.sh <KERNEL_DEFCONFIG_PATH> [STRIP_NET] [STRIP_WIFI]
#                         [BOARD_CONFIG] [STRIP_COREDUMP]
#
# Remove networking, the WiFi stack and/or core-dump support from the Luckfox
# kernel at BUILD time, for non-dev (production) images. Shared by the GitHub
# Actions build and both local Docker builds (os-build.sh / build-local.sh) —
# change this script, never one caller. Must run BEFORE `./build.sh kernel`.
#
# WHY KERNEL-LEVEL: the threat model is root-level code execution (the SeedSigner
# Python app runs as root). Userspace hardening (harden-nondev.sh's loopback-only
# S40network stub, removed telnet init scripts) does NOT stop root — it can just
# run `ifconfig eth0 up; udhcpc`, or `insmod /oem/usr/ko/cfg80211.ko`. Only
# removing the capability from the kernel is a real control: a capability that
# was never compiled in cannot be restored at runtime.
#
#   STRIP_NET      1|0 (default 1) — Group A, gate on: non-dev AND debug_network=off
#   STRIP_WIFI     1|0 (default 1) — Group B, gate on: non-dev
#   STRIP_COREDUMP 1|0 (default 1) — Group C, gate on: non-dev
#
# Group B is applied even to debug_network=on builds: the Ethernet debug channel
# is wired Ethernet, no Luckfox build ever uses WiFi.
#
# Group C (core dumps) is likewise applied to every non-dev build. A core dump is
# a verbatim copy of a process's memory written to disk by the kernel. On this
# device the SeedSigner app runs as ROOT and holds seed material, so a dump is a
# direct path from a crash to secrets on storage — and in practice the SDK writes
# them to whatever core_pattern points at, which has been observed to be the
# user's removable microSD (48 dumps / 815 MB of rkaiq_3A_server and rkipc cores
# were found on one card, alongside the FAT corruption that repeated
# power-cycling mid-write produces).
#
# It is stripped at the KERNEL level for the same reason as the network stack:
# userspace settings (core_pattern, `ulimit -c`) are not a control against root,
# and the SDK's RkLunch.sh sets `ulimit -c unlimited` and its own core_pattern
# (/data/core-%p-%e) late in boot, after any rootfs-level hardening has run —
# so a userspace knob set earlier is simply overwritten. CONFIG_COREDUMP=n is
# the whole control: with no do_coredump() in the kernel, nothing can re-enable
# dumping, and RkLunch.sh's two lines become inert rather than needing patching.
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
BOARD_CONFIG="${4:-}"
STRIP_COREDUMP="${5:-1}"

if [ -z "$DEFCONFIG" ] || [ ! -f "$DEFCONFIG" ]; then
    echo "strip-kernel-network: kernel defconfig '${DEFCONFIG:-<empty>}' not found" >&2
    exit 1
fi
if [ -n "$BOARD_CONFIG" ] && [ ! -f "$BOARD_CONFIG" ]; then
    echo "strip-kernel-network: board config '$BOARD_CONFIG' not found" >&2
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

echo "=== Stripping kernel network/WiFi/coredump in $(basename "$DEFCONFIG") (net=$STRIP_NET wifi=$STRIP_WIFI coredump=$STRIP_COREDUMP) ==="

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

    # ALSO disable the SDK's OUT-OF-TREE wifi drivers. These live in
    # sysdrv/drv_ko/wifi/* and are built by the sysdrv Makefile's `build-usb`
    # target when RK_ENABLE_WIFI=y — completely independently of the kernel
    # defconfig. Disabling CONFIG_WL_ROCKCHIP alone removes the in-kernel
    # cfg80211/mac80211 those drivers link against, so they then fail modpost
    # with hundreds of `"cfg80211_*" undefined!` errors and the whole build dies
    # in build_rootfs. That is exactly what broke non-dev SPI_NAND on Pro Max and
    # Mini (both set RK_ENABLE_WIFI=y); Pico Pi EMMC survived only because its
    # board config has the line commented out.
    #
    # Turning it off is also the better security outcome: these are the very
    # 8188fu/8189fs/aic8800/atbm/ssv6 modules that were being packaged to
    # /oem/usr/ko and left loadable by root.
    if [ -n "$BOARD_CONFIG" ]; then
        if grep -qE '^[[:space:]]*export[[:space:]]+RK_ENABLE_WIFI=n[[:space:]]*$' "$BOARD_CONFIG"; then
            log "RK_ENABLE_WIFI already disabled in $(basename "$BOARD_CONFIG")"
        elif grep -qE '^[[:space:]]*export[[:space:]]+RK_ENABLE_WIFI=' "$BOARD_CONFIG"; then
            sed -i -E 's/^([[:space:]]*export[[:space:]]+RK_ENABLE_WIFI=).*/# [seedsigner] out-of-tree wifi drivers disabled with the kernel WiFi strip\n\1n/' "$BOARD_CONFIG"
            log "disabled RK_ENABLE_WIFI in $(basename "$BOARD_CONFIG") (no out-of-tree wifi drv_ko build)"
        else
            log "RK_ENABLE_WIFI not set in $(basename "$BOARD_CONFIG") — no out-of-tree wifi build to disable"
        fi

        # The wifi/BT firmware overlay only ships blobs for hardware we've just
        # removed the drivers for. Dropping it saves space and keeps firmware for
        # a non-existent radio off the image. Guarded: no-op if absent.
        if grep -qE '^[[:space:]]*export[[:space:]]+RK_POST_OVERLAY=.*overlay-luckfox-wifibt-firmware' "$BOARD_CONFIG"; then
            sed -i -E 's/([[:space:]]*)overlay-luckfox-wifibt-firmware//' "$BOARD_CONFIG"
            log "removed overlay-luckfox-wifibt-firmware from RK_POST_OVERLAY"
        fi

        if grep -qE '^[[:space:]]*export[[:space:]]+RK_ENABLE_WIFI=y' "$BOARD_CONFIG"; then
            echo "strip-kernel-network: failed to disable RK_ENABLE_WIFI in $BOARD_CONFIG" >&2
            exit 1
        fi
    else
        log "WARNING: no board config passed — RK_ENABLE_WIFI not checked; if this board sets it, the out-of-tree wifi build will fail modpost"
    fi
else
    log "WiFi drivers RETAINED"
fi

if [ "$STRIP_COREDUMP" = "1" ]; then
    # Group C — no process core dumps. A core dump is a verbatim copy of a
    # process's memory written to storage by the kernel. The SeedSigner app runs
    # as ROOT and holds seed material, so a dump is a direct path from a crash to
    # secrets in flash (or on the user's removable card, which is where 48 dumps
    # / 815 MB of rkaiq_3A_server and rkipc cores were actually found).
    #
    # CONFIG_COREDUMP is ABSENT from the stock defconfig, and its Kconfig default
    # is `y` — so leaving it alone leaves dumping ON. It has to be set explicitly.
    #
    # This is the only real control. The SDK's RkLunch.sh runs `ulimit -c
    # unlimited` and points core_pattern at /data/core-%p-%e late in boot, after
    # any userspace hardening; with do_coredump() compiled out, both are inert.
    disable_sym CONFIG_COREDUMP
    # depends on COREDUMP, so Kconfig drops it anyway — explicit for the reader.
    disable_sym CONFIG_ELF_CORE
else
    log "core dumps RETAINED"
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
echo "=== kernel network/WiFi/coredump strip complete ==="
