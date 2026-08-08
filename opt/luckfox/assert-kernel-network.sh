#!/usr/bin/env bash
#
# assert-kernel-network.sh <LUCKFOX_PICO_DIR> [EXPECT_NET_OFF] [EXPECT_WIFI_OFF]
#
# Post-build verification that the non-dev kernel network/WiFi strip actually
# took effect. Shared by the GitHub Actions build and both local Docker builds.
# Run AFTER `./build.sh kernel` (and, for the oem check, after the firmware/oem
# packaging step — the check no-ops if the oem dir isn't staged yet).
#
# WHY THIS EXISTS: Kconfig SILENTLY DROPS defconfig lines whose symbol doesn't
# exist or whose dependencies are unmet. The U-Boot bootcount work proved this
# the hard way — CONFIG_BOOTCOUNT_LIMIT was accepted into the defconfig, ignored
# by Kconfig, and the compiled binary had zero bootcount code while the build
# stayed green. A green build must NOT be able to ship a networked kernel, so we
# assert on the GENERATED .config, never on the defconfig we wrote.
#
#   EXPECT_NET_OFF   1|0 (default 1)
#   EXPECT_WIFI_OFF  1|0 (default 1)

set -eu

LUCKFOX_DIR="${1:-}"
EXPECT_NET_OFF="${2:-1}"
EXPECT_WIFI_OFF="${3:-1}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "assert-kernel-network: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [kassert] $*"; }
fail() { echo "  [kassert] ❌ $*" >&2; FAILED=1; }
FAILED=0

echo "=== Verifying non-dev kernel network/WiFi strip ==="

# ---------------------------------------------------------------- generated .config
# Locate the .config the kernel was actually built with.
CFG=""
for c in \
    "$LUCKFOX_DIR/sysdrv/source/objs_kernel/.config" \
    "$LUCKFOX_DIR/sysdrv/source/kernel/.config"
do
    [ -f "$c" ] && { CFG="$c"; break; }
done
if [ -z "$CFG" ]; then
    CFG="$(find "$LUCKFOX_DIR/sysdrv" -maxdepth 4 -name '.config' -path '*kernel*' 2>/dev/null | head -n1 || true)"
fi

if [ -z "$CFG" ] || [ ! -f "$CFG" ]; then
    echo "assert-kernel-network: could not locate the generated kernel .config — cannot verify" >&2
    exit 1
fi
log "checking generated kernel config: ${CFG#$LUCKFOX_DIR/}"

# is_off: true when the symbol is absent or explicitly "is not set"
is_off() { ! grep -qE "^$1=" "$CFG"; }
is_on()  {   grep -qE "^$1=y$" "$CFG"; }

if [ "$EXPECT_NET_OFF" = "1" ]; then
    for sym in CONFIG_INET CONFIG_PACKET CONFIG_IPV6 CONFIG_NETDEVICES CONFIG_STMMAC_ETH CONFIG_RK630_PHY; do
        if is_off "$sym"; then log "✅ $sym off"; else fail "$sym is ENABLED in the built kernel ($(grep -E "^$sym=" "$CFG"))"; fi
    done
else
    log "(skip) networking expected ON (debug_network=on)"
fi

if [ "$EXPECT_WIFI_OFF" = "1" ]; then
    for sym in CONFIG_WL_ROCKCHIP CONFIG_RTL8723BS CONFIG_CFG80211 CONFIG_MAC80211; do
        if is_off "$sym"; then log "✅ $sym off"; else fail "$sym is ENABLED in the built kernel ($(grep -E "^$sym=" "$CFG"))"; fi
    done
else
    log "(skip) WiFi expected ON"
fi

# Canaries: things the strip must NOT have taken down as collateral.
#   CONFIGFS_FS -> device-tree overlays -> SPI0 -> the display
#   NET/UNIX    -> AF_UNIX -> pcscd -> smartcards
#   MODULES     -> camera drivers are =m
if is_on CONFIG_CONFIGFS_FS; then log "✅ CONFIGFS_FS=y (display overlays)"; else fail "CONFIGFS_FS is NOT =y — luckfox-config cannot create device-tree overlays, the SPI display will not come up"; fi
if is_on CONFIG_NET;         then log "✅ NET=y (AF_UNIX for pcscd)";        else fail "CONFIG_NET is not =y — AF_UNIX is gone, pcscd/smartcards will break"; fi
if is_on CONFIG_UNIX;        then log "✅ UNIX=y (pcscd socket)";            else fail "CONFIG_UNIX is not =y — pcscd socket will break"; fi
if is_on CONFIG_MODULES;     then log "✅ MODULES=y (camera drivers are =m)"; else fail "CONFIG_MODULES is not =y — the camera modules cannot load"; fi

# ------------------------------------------------- out-of-tree wifi drv_ko
# The SDK builds wifi drivers from sysdrv/drv_ko/wifi/* when RK_ENABLE_WIFI=y,
# independently of the kernel defconfig. With the in-kernel cfg80211 stripped
# they fail modpost ("cfg80211_* undefined!") and kill build_rootfs — this is
# what broke non-dev SPI_NAND on Pro Max and Mini. If any built wifi .ko is
# sitting here, RK_ENABLE_WIFI was not disabled and the strip is incoherent.
if [ "$EXPECT_WIFI_OFF" = "1" ]; then
    DRVKO="$LUCKFOX_DIR/sysdrv/drv_ko/wifi"
    if [ -d "$DRVKO" ]; then
        built="$(find "$DRVKO" -name '*.ko' 2>/dev/null | head -20 || true)"
        if [ -n "$built" ]; then
            fail "out-of-tree wifi modules were built despite the WiFi strip (RK_ENABLE_WIFI not disabled?):"
            echo "$built" | sed 's|^|        |' >&2
        else
            log "✅ no out-of-tree wifi .ko built"
        fi
    else
        log "✅ no sysdrv/drv_ko/wifi tree (out-of-tree wifi build disabled)"
    fi
fi

# ---------------------------------------------------------------- oem payload
# The SDK packages every built .ko to the oem partition at /oem/usr/ko
# (build.sh __PACKAGE_RESOURCES -> __COPY_FILES kernel_drv_ko/ $OEM/usr/ko).
# No rootfs hardening touches /oem, so a stray .ko landing there is directly
# loadable by root.
#
# Wireless and networking modules are checked SEPARATELY against their own
# expectation. They were originally lumped together, which failed a
# debug_network=on build over ipv6.ko — correctly retained there, because that
# build deliberately keeps networking. A false failure on an intended
# configuration is as bad as a missed real one.
WIFI_KO_PATTERN='cfg80211|mac80211|8188fu|8189fs|aic8800|atbm|r8723bs|ssv6'
NET_KO_PATTERN='ipv6'
KO_DIR="$LUCKFOX_DIR/output/out/oem/usr/ko"

check_oem_payload() {
    local label="$1" pattern="$2"
    local stray
    stray="$(find "$KO_DIR" -maxdepth 1 -name '*.ko' 2>/dev/null | grep -EI "$pattern" || true)"
    if [ -n "$stray" ]; then
        fail "$label modules present in /oem/usr/ko (loadable by root):"
        echo "$stray" | sed 's|^|        |' >&2
    else
        log "✅ no $label .ko in oem payload"
    fi
}

if [ -d "$KO_DIR" ]; then
    [ "$EXPECT_WIFI_OFF" = "1" ] && check_oem_payload "wireless" "$WIFI_KO_PATTERN"
    [ "$EXPECT_NET_OFF" = "1" ] && check_oem_payload "networking" "$NET_KO_PATTERN"
    log "oem payload: $(find "$KO_DIR" -maxdepth 1 -name '*.ko' | wc -l) modules total"
elif [ "$EXPECT_WIFI_OFF" = "1" ] || [ "$EXPECT_NET_OFF" = "1" ]; then
    log "(skip) oem dir not staged yet: ${KO_DIR#$LUCKFOX_DIR/}"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "=== ❌ kernel network/WiFi strip verification FAILED ===" >&2
    exit 1
fi
echo "=== ✅ kernel network/WiFi strip verified ==="
