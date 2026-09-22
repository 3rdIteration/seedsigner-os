#!/usr/bin/env bash
#
# patch-otp-size.sh <LUCKFOX_PICO_DIR>
#
# Extend the RV1106 OTP nvmem region from 0x80 to 0x100 bytes so userspace can
# read the secure-boot enable fuse at offset 0x80. Shared by the GitHub Actions
# build and both local Docker builds (os-build.sh / build-local.sh) — change
# this script, never one caller. Must run BEFORE the kernel/DTB is built.
#
# WHY: the rootfs verifier's /init needs to know whether the board's secure
# boot is fused so it can show a "SECURE BOOT not enabled" screen and skip
# verification on unfused boards (the same signed image must boot on unlocked
# devices too). U-Boot SPL reads exactly this byte — OTP_SECURE_BOOT_ENABLE_ADDR
# = 0x80, include/configs/rv1106_common.h; a fully blown word reads 0xff, blank
# reads 0x00. The kernel's rockchip-otp nvmem driver already probes on all three
# boards (the otp@ff3d0000 node in rv1106.dtsi is included from rv1103.dtsi and
# CONFIG_ROCKCHIP_OTP=y ships in the vendor defconfig), but its
# rv1106_data.size = 0x80 caps the exposed region at 0x00-0x7F, leaving the
# flag byte just out of reach.
#
# Verified on a fused Mini: /sys/bus/nvmem/devices/rockchip-otp0/nvmem is
# readable from userspace (no hardware read protection), so this only extends
# what is already exposed by one word past its current end.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "patch-otp-size: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

OTP_C="$LUCKFOX_DIR/sysdrv/source/kernel/drivers/nvmem/rockchip-otp.c"
if [ ! -f "$OTP_C" ]; then
    echo "patch-otp-size: $OTP_C not found (SDK layout changed?)" >&2
    exit 1
fi

# Idempotent: a re-run on an already-patched tree is a no-op.
if awk '/^static const struct rockchip_data rv1106_data = \{$/,/^\};$/' "$OTP_C" | grep -q '\.size = 0x100,'; then
    echo "=== OTP size already extended to 0x100 ==="
    exit 0
fi

# Only the rv1106_data block: other SoC entries in this file carry their own
# .size values (px30 is also 0x80), so a global sed would corrupt them.
sed -i '/^static const struct rockchip_data rv1106_data = {$/,/^\};$/ s/\.size = 0x80,/.size = 0x100,/' "$OTP_C"

# Assert rather than warn: if the target moved (SDK bump), a silent no-op would
# ship an image where /init cannot read the fuse byte — and on unfused boards
# that means "secure boot not enabled" is never shown. A changed target can
# silently no-op where a missing one fails loudly; check the result, not the sed.
if ! awk '/^static const struct rockchip_data rv1106_data = \{$/,/^\};$/' "$OTP_C" | grep -q '\.size = 0x100,'; then
    echo "patch-otp-size: ERROR — could not extend rv1106_data.size to 0x100 in $OTP_C" >&2
    awk '/^static const struct rockchip_data rv1106_data = \{$/,/^\};$/' "$OTP_C" >&2 || true
    exit 1
fi

echo "=== OTP nvmem region extended to 0x100 (secure-boot fuse at offset 0x80 now readable) ==="
