#!/usr/bin/env bash
#
# assert-zram.sh <LUCKFOX_PICO_DIR> [EXPECT_ZRAM]
#
# Post-build verification that compressed swap actually made it into the image.
# Shared by the GitHub Actions build and both local Docker builds. Run AFTER
# `./build.sh kernel` (the kernel .config check); the busybox and staged-rootfs
# checks no-op until those parts of the build exist.
#
#   EXPECT_ZRAM  1|0 (default 1) — 0 asserts the kernel has NO zram device
#
# WHY THIS EXISTS: Kconfig SILENTLY DROPS defconfig lines whose symbol doesn't
# exist or whose dependencies are unmet, so CONFIG_ZRAM=y in a defconfig proves
# nothing about the kernel that got built. zram has a specific trap here — it
# `depends on` ZSMALLOC, and an unmet `depends on` is discarded without a word,
# so a defconfig that sets ZRAM alone produces a kernel with no zram at all and
# a completely green build. Every check below is against the GENERATED kernel
# .config or a built artifact, never against the inputs we wrote.
#
# The failure this prevents is quiet rather than dramatic: the device boots,
# S03zram logs that this kernel has no zram device, and the Mini runs with the
# 64 MB it always had. Nobody notices until it OOMs in someone's hands, and the
# report that comes back ("it froze while signing") looks nothing like a missing
# kernel symbol. That is worth a build failure.
#
# It also asserts the one thing that must NOT be there: CONFIG_ZRAM_WRITEBACK,
# which would let zram push pages out to a backing block device. Those pages
# hold seed material, and this device is built to leave nothing on flash.

set -eu

LUCKFOX_DIR="${1:-}"
EXPECT_ZRAM="${2:-1}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "assert-zram: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [zramassert] $*"; }
fail() { echo "  [zramassert] ❌ $*" >&2; FAILED=1; }
FAILED=0

# ---------------------------------------------------------------- generated .config
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
    echo "assert-zram: could not locate the generated kernel .config — cannot verify" >&2
    exit 1
fi

is_on() { grep -qE "^$1=y$" "$CFG"; }

if [ "$EXPECT_ZRAM" != "1" ]; then
    echo "=== Verifying the kernel has NO zram (zram disabled for this build) ==="
    log "checking generated kernel config: ${CFG#"$LUCKFOX_DIR"/}"
    if is_on CONFIG_ZRAM; then
        fail "CONFIG_ZRAM=y but zram was supposed to be off for this build"
    else
        log "CONFIG_ZRAM is not enabled, as expected"
    fi
    [ "$FAILED" -eq 0 ] || exit 1
    echo "=== verification complete ==="
    exit 0
fi

echo "=== Verifying zram (compressed swap in RAM) ==="
log "checking generated kernel config: ${CFG#"$LUCKFOX_DIR"/}"

# ZRAM and ZSMALLOC are the two we add, and ZSMALLOC is the one whose absence
# silently takes ZRAM with it. CRYPTO_LZO provides the lzo/lzo-rle compressor
# S03zram asks for by name; SWAP is `default y` and pinned so that a kernel with
# a zram device but no swap support cannot ship unnoticed.
for sym in CONFIG_ZRAM CONFIG_ZSMALLOC CONFIG_CRYPTO_LZO CONFIG_SWAP; do
    if is_on "$sym"; then
        log "$sym=y"
    else
        fail "$sym is NOT enabled in the generated kernel config"
    fi
done

# The security-relevant negative. See the header: a backing device turns zram
# from RAM-only into a path from swapped pages to flash.
if is_on CONFIG_ZRAM_WRITEBACK; then
    fail "CONFIG_ZRAM_WRITEBACK=y — zram could write swapped pages (seed material) to flash"
else
    log "CONFIG_ZRAM_WRITEBACK is off (swap stays in RAM, nothing reaches flash)"
fi

# Built-in rather than modular: modules are packaged to /oem/usr/ko and inserted
# late by the vendor's RkLunch.sh, well after S03zram has run and after the boot
# window the headroom is for.
if grep -qE '^CONFIG_ZRAM=m$' "$CFG"; then
    fail "CONFIG_ZRAM=m — a modular zram is not loaded until long after S03zram runs"
fi

# ------------------------------------------------------------------- busybox
# S03zram calls mkswap and swapon, which on this rootfs are busybox applets.
# Buildroot's default busybox.config enables both, so this is a regression guard
# rather than an expected failure — but an applet that is silently absent turns
# into a device with a zram block device and no swap on it, logged once at boot
# and never again.
# Depth 5 is the layout this SDK uses today
# (buildroot-<ver>/output/build/busybox-<ver>/.config); the bound is loose enough
# to survive a per-config output directory if an SDK bump introduces one, because
# a check that silently stops finding its input is a check that stops working.
BB_CFG="$(find "$LUCKFOX_DIR/sysdrv/source/buildroot" -maxdepth 7 -path '*/build/busybox-*/.config' 2>/dev/null | head -n1 || true)"
if [ -n "$BB_CFG" ] && [ -f "$BB_CFG" ]; then
    log "checking generated busybox config: $(basename "$(dirname "$BB_CFG")")/.config"
    for applet in CONFIG_MKSWAP CONFIG_SWAPON CONFIG_SWAPOFF; do
        if grep -qE "^$applet=y$" "$BB_CFG"; then
            log "$applet=y"
        else
            fail "busybox $applet is not enabled — S03zram cannot bring swap up"
        fi
    done
else
    log "(busybox has not been configured yet — skipping the applet check)"
fi

# ------------------------------------------------------------- staged rootfs
# Same soft treatment as the S01overlay check in assert-readonly-rootfs.sh: the
# staging directory name varies by SDK revision, so not finding it is at least
# as likely to mean "looked in the wrong place" as "not installed".
for r in "$LUCKFOX_DIR/output/out/rootfs_uclibc_rv1106/etc/init.d/S03zram" \
         "$LUCKFOX_DIR/output/out/rootfs_uclibc_rv1103/etc/init.d/S03zram"
do
    if [ -f "$r" ]; then
        log "S03zram is staged in the rootfs"
        if [ -x "$r" ]; then
            log "S03zram is executable"
        else
            fail "S03zram is staged but NOT executable — init will skip it"
        fi
        FOUND_ZRAM_SCRIPT=1
        break
    fi
done
if [ -z "${FOUND_ZRAM_SCRIPT:-}" ]; then
    log "(could not locate S03zram in a staged rootfs — check the install step)"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "  [zramassert] zram verification FAILED" >&2
    exit 1
fi
echo "=== zram verified ==="
