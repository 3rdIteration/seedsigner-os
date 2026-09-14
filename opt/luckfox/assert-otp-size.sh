#!/usr/bin/env bash
#
# assert-otp-size.sh <LUCKFOX_PICO_DIR>
#
# Post-build verification that the secure-boot fuse is readable from userspace:
# NVMEM_SYSFS + ROCKCHIP_OTP in the GENERATED kernel .config, and the
# rv1106_data.size extension in rockchip-otp.c. Shared by the GitHub Actions
# build and both local Docker builds. Run AFTER `./build.sh kernel`.
#
# WHY THIS EXISTS: /init's "SECURE BOOT not enabled" screen depends on reading
# OTP offset 0x80 through /sys/bus/nvmem/devices/rockchip-otp0/nvmem. If any
# piece is missing (Kconfig silently drops a line, an SDK bump moves the sed
# target) the read comes back empty and /init fails CLOSED — verification still
# runs, so this is feature correctness, not a security hole. But a green build
# that never shows the screen on unlocked boards is exactly the class of silent
# regression this repo asserts against: check the generated artifacts, never
# just the inputs we wrote.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "assert-otp-size: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log()  { echo "  [otpassert] $*"; }
fail() { echo "  [otpassert] FAIL: $*" >&2; FAILED=1; }
FAILED=0

echo "=== Verifying secure-boot fuse readability (nvmem) ==="

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
    echo "assert-otp-size: could not locate the generated kernel .config — cannot verify" >&2
    exit 1
fi
log "checking generated kernel config: ${CFG#$LUCKFOX_DIR/}"

for sym in CONFIG_NVMEM CONFIG_NVMEM_SYSFS CONFIG_ROCKCHIP_OTP; do
    if grep -qE "^${sym}=y$" "$CFG"; then
        log "OK: $sym=y"
    else
        fail "$sym is not =y in the built kernel — /init cannot read the secure-boot fuse (screen will never show on unlocked boards)"
    fi
done

# ---------------------------------------------------------------- size patch
OTP_C="$LUCKFOX_DIR/sysdrv/source/kernel/drivers/nvmem/rockchip-otp.c"
if [ -f "$OTP_C" ]; then
    if awk '/^static const struct rockchip_data rv1106_data = \{$/,/^\};$/' "$OTP_C" | grep -q '\.size = 0x100,'; then
        log "OK: rv1106_data.size extended to 0x100 (fuse byte at offset 0x80 exposed)"
    else
        fail "rv1106_data.size is not 0x100 in $OTP_C — the nvmem blob stays 128 bytes and the fuse byte at offset 0x80 is out of range"
    fi
else
    log "(skip) $OTP_C not found (SDK layout changed?)"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "=== FAIL: secure-boot fuse readability verification FAILED ===" >&2
    exit 1
fi
echo "=== OK: secure-boot fuse readable from userspace ==="
