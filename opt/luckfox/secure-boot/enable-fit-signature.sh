#!/usr/bin/env bash
#
# enable-fit-signature.sh <SDK_DIR>
#
# Turn ON FIT signature *enforcement* in a checked-out Luckfox SDK's U-Boot
# defconfig, so SPL and U-Boot REQUIRE a valid signature to boot. Idempotent.
#
# WHY THIS IS A SEPARATE, MANUAL SCRIPT and not one of the auto-applied patches
# in ../patches/luckfox-sdk/: those are applied to EVERY build. Enforcing
# signatures on a build whose images are then NOT signed produces a device that
# refuses to boot. This must be opt-in, paired with a signing step
# (sign-secure-boot.sh) and, ultimately, an OTP burn. See
# docs/luckfox/secure-boot-bench-procedure.md.
#
# It edits, in the SDK you point it at:
#   sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig
# adding:
#   CONFIG_FIT_SIGNATURE=y        (U-Boot requires a signed boot.img)
#   CONFIG_SPL_FIT_SIGNATURE=y    (SPL requires a signed uboot.img)
# The prerequisites it depends on (CONFIG_RSA, CONFIG_SPL_RSA,
# CONFIG_FIT_HW_CRYPTO, CONFIG_SPL_FIT_HW_CRYPTO, CONFIG_SPL_ROCKCHIP_SECURE_OTP)
# are already present in the stock defconfig; it checks and warns if not.
#
set -euo pipefail

SDK="${1:-}"
[ -n "$SDK" ] || { echo "usage: $0 <SDK_DIR>" >&2; exit 1; }

CFG="$SDK/sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig"
[ -f "$CFG" ] || { echo "ERROR: defconfig not found: $CFG" >&2; exit 1; }

ensure() {
  local sym="$1"
  if grep -q "^${sym}=y$" "$CFG"; then
    echo "  [fit-sig] already set: ${sym}=y"
  else
    # drop any '# CONFIG_x is not set' or '=n', then append '=y'
    sed -i -E "/^# ${sym} is not set\$/d; /^${sym}=/d" "$CFG"
    echo "${sym}=y" >> "$CFG"
    echo "  [fit-sig] enabled: ${sym}=y"
  fi
}

echo "  [fit-sig] editing $CFG"
ensure CONFIG_FIT_SIGNATURE
ensure CONFIG_SPL_FIT_SIGNATURE

echo "  [fit-sig] checking prerequisites (should already be present):"
for sym in CONFIG_RSA CONFIG_SPL_RSA CONFIG_FIT_HW_CRYPTO CONFIG_SPL_FIT_HW_CRYPTO CONFIG_SPL_ROCKCHIP_SECURE_OTP; do
  if grep -q "^${sym}=y$" "$CFG"; then echo "    ok   ${sym}=y"
  else echo "    WARN ${sym} not =y — signature verification may not build/work"; fi
done

echo "  [fit-sig] done. Now build U-Boot in the SDK, then sign the output with"
echo "  [fit-sig] sign-secure-boot.sh (see docs/luckfox/secure-boot-bench-procedure.md)."
echo "  [fit-sig] REMINDER: an enforcing build that is not signed will NOT boot."
