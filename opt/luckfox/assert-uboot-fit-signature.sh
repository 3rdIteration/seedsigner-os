#!/usr/bin/env bash
#
# assert-uboot-fit-signature.sh <LUCKFOX_PICO_DIR>
#
# Verify FIT signature ENFORCEMENT actually landed in the *built* U-Boot .config.
# Shared by the GitHub Actions build and both local Docker builds — change this
# script, never one caller. Run AFTER the U-Boot build (`build.sh uboot`).
#
# WHY THIS EXISTS. apply_fit_signature_config() appends CONFIG_FIT_SIGNATURE=y and
# CONFIG_SPL_FIT_SIGNATURE=y to the U-Boot defconfig, but Kconfig SILENTLY DROPS a
# symbol whose dependencies are unmet — the exact failure mode AGENTS.md warns
# about, and the one that shipped a "green but non-functional" U-Boot bootcount
# image once already. For secure boot the consequence is the worst kind: the SDK
# still signs the FIT during the build and `deterministic-sign.sh` still verifies
# those signatures, so signing + verification both pass — only *enforcement* is
# missing, and the board boots unsigned firmware while every build check is green.
# There is an assert-kernel-network.sh for the kernel; this is its U-Boot analogue.
#
# Assert on the GENERATED .config, never the defconfig we wrote. No-op unless
# SEEDSIGNER_FIT_SIGNATURE=1.
#
# Policy: a missing symbol in a present .config is a HARD FAIL (that is the bug
# this catches). A .config that cannot be found is a loud WARNING rather than a
# failure — the path can drift across SDK versions, and failing the build over a
# path change would be a worse regression than the (already loudly-flagged) gap.

set -u

LUCKFOX_DIR="${1:-}"

[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || exit 0

log()  { echo "  [uboot-fitsig] $*"; }
fail() { echo "  [uboot-fitsig] ❌ $*" >&2; exit 1; }
warn() { echo "  [uboot-fitsig] ⚠️  $*" >&2; }

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    fail "luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found"
fi

# The built config the U-Boot signature enforcement is (or is not) compiled from.
# Same path os-build.sh already reads for the FIT sign tree.
UBOOT_CFG="$LUCKFOX_DIR/sysdrv/source/uboot/u-boot/.config"
if [ ! -f "$UBOOT_CFG" ]; then
    UBOOT_CFG="$(find "$LUCKFOX_DIR/sysdrv" -maxdepth 5 -name '.config' -path '*uboot*' 2>/dev/null | head -n1 || true)"
fi
if [ -z "$UBOOT_CFG" ] || [ ! -f "$UBOOT_CFG" ]; then
    warn "could not locate the built U-Boot .config under $LUCKFOX_DIR/sysdrv — CANNOT verify FIT"
    warn "signature enforcement. If secure boot is expected, confirm CONFIG_FIT_SIGNATURE=y in the"
    warn "generated U-Boot .config by hand, and update this script's path."
    exit 0
fi

log "checking $(echo "$UBOOT_CFG" | sed "s|^$LUCKFOX_DIR/||")"
for sym in CONFIG_FIT_SIGNATURE CONFIG_SPL_FIT_SIGNATURE; do
    if ! grep -q "^${sym}=y" "$UBOOT_CFG"; then
        fail "$sym is NOT enabled in the built U-Boot .config — Kconfig dropped it (unmet dep?).
        The image signs and verifies in-tool but the board will NOT enforce signatures at boot:
        a 'signed but unprotected' build. Fix the U-Boot config dependency, do not ship this."
    fi
done
log "✅ FIT signature enforcement present (CONFIG_FIT_SIGNATURE=y, CONFIG_SPL_FIT_SIGNATURE=y)"
