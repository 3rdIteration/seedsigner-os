#!/usr/bin/env bash
#
# lock-kernel-cmdline.sh <LUCKFOX_PICO_DIR>
#
# Signed builds only (SEEDSIGNER_FIT_SIGNATURE=1): stop the unsigned env
# partition from contributing ANYTHING to the kernel command line. Shared by
# the GitHub Actions build and both local Docker builds (os-build.sh /
# build-local.sh) — change this script, never one caller. Run it BEFORE
# `./build.sh uboot`, next to apply_fit_signature_config().
#
# WHY THIS EXISTS (M1, confirmed on a fused board 2026-09-23). The env
# partition is unsigned, and U-Boot imports the variables named in
# CONFIG_ENVF_LIST from it into its global environment (env/envf.c
# envf_load() -> himport_r(..., envf_list)). arch/arm/mach-rockchip/board.c
# bootargs_add_partition() then appends whatever `mtdparts`/`blkdevparts` the
# environment holds to /chosen/bootargs verbatim. Appending ` rdinit=/bin/sh`
# to the env's blkdevparts value (and recomputing the ENVF CRC) put it into
# the kernel cmdline and the kernel ran a shell from the signed initramfs
# INSTEAD of the rootfs verifier — a silent, persistent, pre-verification
# root-shell bypass on a fused board. See docs/luckfox/secure-boot.md §6.4 /
# §7.11.
#
# THE FIX. Drop `blkdevparts` and `mtdparts` from CONFIG_ENVF_LIST so they are
# never imported into the global environment; board.c then finds nothing to
# append, and the env partition contributes no token to the cmdline at all.
# The kernel still gets its partition layout: apply_signed_nand_bootargs bakes
# the same string (mtdparts= / blkdevparts= built from RK_PARTITION_CMD_IN_ENV)
# into the SIGNED DTB's /chosen/bootargs, where an attacker cannot reach it.
#
# WHY THIS DOES NOT BREAK U-Boot'S OWN BOOT (A3). U-Boot/SPL resolve their own
# partitions through disk/part_env.c — a block-layer partition driver that
# reads env.img DIRECTLY from the device via envf_get() -> envf_read(). That
# path never touches the global environment or CONFIG_ENVF_LIST, so removing
# the two tokens from the import list leaves `boot_fit` (which finds its image
# by partition NAME through the block layer) and the SPL's FIT loading fully
# intact. Only the himport_r() whitelist changes. The env partition itself is
# untouched: Provision MicroSD / sd_update still see it, only its cmdline
# influence is gone.
#
# SCOPE. Gated on SEEDSIGNER_FIT_SIGNATURE=1 exactly like apply_fit_signature_config:
# unsigned builds keep the SDK's stock behaviour (u-boot rewrites /chosen at
# runtime there, so the env import is how they get their cmdline). sys_bootargs
# stays in the list — under FIT_SIGNATURE it is already refused by both import
# paths in envf.c (env_get_string() and envf_init_vars()), and keeping it makes
# this patch minimal.
#
# WHERE THE VALUE LIVES. Every Luckfox board config points at
# RK_UBOOT_DEFCONFIG=luckfox_rv1106_uboot_defconfig, which carries the explicit
# CONFIG_ENVF_LIST; rv1106-luckfox_defconfig carries a second copy. Patch every
# *luckfox* defconfig that defines it (idempotent), and fail loudly if none is
# found — a renamed/removed defconfig must not ship an unpatched list silently.
# The GENERATED .config is re-checked after the build by
# assert-uboot-fit-signature.sh (Kconfig can rewrite string options, so the
# defconfig edit alone is not proof).

set -u

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "lock-kernel-cmdline: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || exit 0

log()  { echo "  [cmdline-lock] $*"; }
fail() { echo "  [cmdline-lock] ❌ $*" >&2; exit 1; }

CFG_DIR="$LUCKFOX_DIR/sysdrv/source/uboot/u-boot/configs"
[ -d "$CFG_DIR" ] || fail "U-Boot configs dir not found: $CFG_DIR"

# Remove one whole word from the quoted CONFIG_ENVF_LIST value, preserving the
# order of every other token. Idempotent: with the token already gone it is a
# no-op (the grep -vw filter changes nothing).
strip_token() { # <file> <token>
    local f="$1" tok="$2" line val
    line="$(grep -E '^CONFIG_ENVF_LIST=' "$f" | head -n1)" || return 0
    [ -n "$line" ] || return 0
    printf '%s\n' "$line" | grep -qw "$tok" || return 0
    # The value is the quoted string; split on whitespace, drop the token, rejoin.
    val="$(printf '%s\n' "$line" \
        | sed -E 's/^CONFIG_ENVF_LIST="([^"]*)".*$/\1/' \
        | tr '[:space:]' '\n' | grep -v '^$' | grep -vw "$tok" | paste -sd' ' -)"
    [ -n "$val" ] || fail "stripping $tok emptied CONFIG_ENVF_LIST in $(basename "$f")"
    sed -i "s|^CONFIG_ENVF_LIST=.*|CONFIG_ENVF_LIST=\"$val\"|" "$f" \
        || fail "failed to rewrite CONFIG_ENVF_LIST in $f"
}

patched=0
for f in "$CFG_DIR"/*luckfox*defconfig; do
    [ -f "$f" ] || continue
    if grep -qE '^CONFIG_ENVF_LIST=' "$f"; then
        strip_token "$f" blkdevparts
        strip_token "$f" mtdparts
        patched=$((patched + 1))
        log "$(basename "$f"): CONFIG_ENVF_LIST -> $(grep -E '^CONFIG_ENVF_LIST=' "$f" | head -n1)"
    fi
done

[ "$patched" -ge 1 ] \
    || fail "no *luckfox* defconfig with CONFIG_ENVF_LIST under $CFG_DIR — SDK layout changed; refusing to build an unverified cmdline lock"

# Hard check: neither token may survive in any luckfox defconfig. A partial
# patch (one of the two left behind) would still ship a working injection path.
for f in "$CFG_DIR"/*luckfox*defconfig; do
    [ -f "$f" ] || continue
    if grep -E '^CONFIG_ENVF_LIST=' "$f" | grep -qw 'blkdevparts\|mtdparts'; then
        fail "$(basename "$f") still whitelists blkdevparts/mtdparts: $(grep -E '^CONFIG_ENVF_LIST=' "$f" | head -n1)"
    fi
done

log "✅ env partition can no longer reach the kernel cmdline (blkdevparts/mtdparts removed from CONFIG_ENVF_LIST)"
