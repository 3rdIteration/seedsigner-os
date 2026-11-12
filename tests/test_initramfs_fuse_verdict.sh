#!/bin/sh
# test_initramfs_fuse_verdict.sh - the rootfs verifier's fuse decision, in isolation.
#
# opt/luckfox/secure-boot/initramfs/init decides per board whether the rootfs
# signature is checked. The rule is VERIFY BY DEFAULT: only an explicit
# `fuse.programmed=0` (with no `fuse.programmed=1`) may skip it. This test cuts
# the decision block out of the real /init and runs it against a fake kernel
# command line and a fake OTP byte, so a regression to "no flag -> skip" (what
# an earlier revision did, via an OTP byte that is the chip ID on every board)
# is caught in a second, without a board.
#
# Runs anywhere with a POSIX sh, sed and sha256sum. Exit 0 = all cases pass.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INIT="$HERE/../opt/luckfox/secure-boot/initramfs/init"
[ -f "$INIT" ] || { echo "SKIP: $INIT not found"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: sha256sum not available"; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# The block: from its initial assignment to the "unknown" log line.
sed -n '/^SECURE_BOOT_FUSED=1$/,/fuse state unknown, verifying"$/p' "$INIT" > "$WORK/block.sh"
[ -s "$WORK/block.sh" ] || { echo "FAIL: could not extract the fuse-decision block from /init"; exit 1; }
grep -q 'FUSE_VERDICT=unknown' "$WORK/block.sh" \
    || { echo "FAIL: extracted block has no FUSE_VERDICT (the /init layout changed - update this test)"; exit 1; }

fails=0

# run_case <name> <cmdline> <otp: ff|chipid|empty> <want FUSED> <want VERDICT>
run_case() {
    name="$1"; cmdline="$2"; otp="$3"; want_fused="$4"; want_verdict="$5"
    case "$otp" in
        ff)     printf '\377' > "$WORK/otp" ;;
        chipid) printf 'R'    > "$WORK/otp" ;;      # what a real board reads at 0x80
        empty)  : > "$WORK/otp" ;;
    esac
    printf '%s\n' "$cmdline" > "$WORK/cmdline"
    out="$(
        # Stand-ins for the two things the block reads: /proc/cmdline via cat,
        # the nvmem byte via dd.
        cat() { command cat "$WORK/cmdline"; }
        dd()  { command cat "$WORK/otp"; }
        log() { :; }
        . "$WORK/block.sh"
        echo "$SECURE_BOOT_FUSED $FUSE_VERDICT"
    )"
    if [ "$out" = "$want_fused $want_verdict" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: got '$out', want '$want_fused $want_verdict'"
        fails=$((fails + 1))
    fi
}

BASE="root=/dev/mmcblk1p6 rootfstype=squashfs rk_dma_heap_cma=1M"

run_case "fused flag verifies"                       "$BASE fuse.programmed=1"                    chipid 1 fused
run_case "explicit unfused flag skips"               "$BASE fuse.programmed=0"                    chipid 0 unfused
# The regression this test exists for: no flag at all must NOT read as unfused.
run_case "no flag at all verifies (chip-id OTP)"     "$BASE"                                      chipid 1 unknown
run_case "no flag at all verifies (empty OTP read)"  "$BASE"                                      empty  1 unknown
run_case "no flag at all verifies (0xff OTP)"        "$BASE"                                      ff     1 unknown
# =1 wins over =0 in either order.
run_case "=1 beats a later =0"                       "$BASE fuse.programmed=1 fuse.programmed=0"  chipid 1 fused
run_case "=1 beats an earlier =0"                    "$BASE fuse.programmed=0 fuse.programmed=1"  chipid 1 fused
# The OTP byte may only ever turn verification ON.
run_case "0xff OTP overrides an unfused flag"        "$BASE fuse.programmed=0"                    ff     1 fused
run_case "empty OTP read cannot turn it on or off"   "$BASE fuse.programmed=0"                    empty  0 unfused
# Whole-word match: a look-alike token is not the flag.
run_case "prefixed look-alike is not the flag"       "$BASE xfuse.programmed=0"                   chipid 1 unknown
run_case "suffixed look-alike is not the flag"       "$BASE fuse.programmed=00"                   chipid 1 unknown
run_case "empty command line verifies"               ""                                           chipid 1 unknown

if [ "$fails" -ne 0 ]; then
    echo "$fails case(s) FAILED"
    exit 1
fi
echo "all fuse-verdict cases pass"
