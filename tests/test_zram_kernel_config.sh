#!/bin/bash
# Test enable-zram.sh (what we write into the kernel defconfig) and
# assert-zram.sh (what we check in the kernel config the build generated).
#
# The pairing is the point. Kconfig silently drops defconfig lines whose
# dependencies are unmet — CONFIG_ZRAM `depends on` CONFIG_ZSMALLOC, so a
# defconfig asking for ZRAM alone yields a kernel with no zram and a green
# build. enable-zram.sh sets both; assert-zram.sh is what proves the kernel that
# came out the other end actually has them. These tests check that the assertion
# would really catch each way the build can lose the feature, using a synthetic
# generated .config in place of a two-hour kernel build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENABLE="${REPO_ROOT}/opt/luckfox/enable-zram.sh"
ASSERT="${REPO_ROOT}/opt/luckfox/assert-zram.sh"

PASS=0
FAIL=0
TMPROOT=""

cleanup() {
  if [ -n "${TMPROOT}" ] && [ -d "${TMPROOT}" ]; then
    rm -rf "${TMPROOT}"
  fi
}
trap cleanup EXIT
TMPROOT="$(mktemp -d)"

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_line() {
  local what="$1" line="$2" file="$3"
  if grep -qxF -- "$line" "$file"; then
    ok "$what"
  else
    bad "$what (no exact line '$line')"
  fi
}

# A minimal stand-in for the vendor defconfig: no zram symbols at all, which is
# exactly the state of luckfox_rv1106_linux_defconfig in the SDK.
make_defconfig() {
  local f="$1"
  cat > "$f" <<'CFG'
CONFIG_LOCALVERSION="-luckfox"
CONFIG_SYSVIPC=y
CONFIG_CRYPTO_ZSTD=y
# CONFIG_CRYPTO_HW is not set
CFG
}

# A synthetic GENERATED kernel .config. Every symbol enable-zram.sh asks for,
# unless a knob says to break one.
make_generated_config() {
  local dir="$1"; shift
  local zram="CONFIG_ZRAM=y" zsmalloc="CONFIG_ZSMALLOC=y"
  local lzo="CONFIG_CRYPTO_LZO=y" swap="CONFIG_SWAP=y" writeback="" kv

  for kv in "$@"; do
    case "$kv" in
      no_zram=1)      zram="# CONFIG_ZRAM is not set" ;;
      modular_zram=1) zram="CONFIG_ZRAM=m" ;;
      no_zsmalloc=1)  zsmalloc="# CONFIG_ZSMALLOC is not set" ;;
      no_lzo=1)       lzo="# CONFIG_CRYPTO_LZO is not set" ;;
      no_swap=1)      swap="# CONFIG_SWAP is not set" ;;
      writeback=1)    writeback="CONFIG_ZRAM_WRITEBACK=y" ;;
      *) echo "unknown knob: $kv" >&2; exit 1 ;;
    esac
  done

  mkdir -p "$dir/sysdrv/source/kernel"
  {
    printf '%s\n' "$zram" "$zsmalloc" "$lzo" "$swap"
    [ -n "$writeback" ] && printf '%s\n' "$writeback"
    printf 'CONFIG_BLOCK=y\n'
  } > "$dir/sysdrv/source/kernel/.config"
}

# Buildroot's busybox config, where S03zram's mkswap/swapon come from.
make_busybox_config() {
  local dir="$1" state="${2:-good}"
  local bb="$dir/sysdrv/source/buildroot/buildroot-2023.02.6/output/build/busybox-1.36.0"
  mkdir -p "$bb"
  if [ "$state" = "good" ]; then
    printf 'CONFIG_MKSWAP=y\nCONFIG_SWAPON=y\nCONFIG_SWAPOFF=y\n' > "$bb/.config"
  else
    printf 'CONFIG_MKSWAP=y\n# CONFIG_SWAPON is not set\nCONFIG_SWAPOFF=y\n' > "$bb/.config"
  fi
}

run_assert() {
  local dir="$1" expect="${2:-1}"
  set +e
  bash "$ASSERT" "$dir" "$expect" > "$dir/assert.log" 2>&1
  RC=$?
  set -e
}

echo "=== enable-zram.sh: writes the symbols the driver needs ==="
DC="${TMPROOT}/defconfig"
make_defconfig "$DC"
bash "$ENABLE" "$DC" 1 > "${TMPROOT}/enable.log" 2>&1
check_line "CONFIG_ZRAM=y"      "CONFIG_ZRAM=y" "$DC"
# The trap: a `depends on`, never auto-enabled, silently takes ZRAM with it.
check_line "CONFIG_ZSMALLOC=y"  "CONFIG_ZSMALLOC=y" "$DC"
check_line "CONFIG_CRYPTO_LZO=y" "CONFIG_CRYPTO_LZO=y" "$DC"
check_line "CONFIG_SWAP=y"      "CONFIG_SWAP=y" "$DC"
# Writeback is the one thing that could put swapped pages (seed material) on flash.
check_line "CONFIG_ZRAM_WRITEBACK is off" "# CONFIG_ZRAM_WRITEBACK is not set" "$DC"
if [ "$(grep -c '^CONFIG_ZRAM=y$' "$DC")" = "1" ]; then
  ok "no duplicate CONFIG_ZRAM lines"
else
  bad "CONFIG_ZRAM=y appears $(grep -c '^CONFIG_ZRAM=y$' "$DC") times"
fi

echo "=== enable-zram.sh: rewrites an existing opposite setting ==="
DC2="${TMPROOT}/defconfig2"
make_defconfig "$DC2"
printf '# CONFIG_ZRAM is not set\nCONFIG_ZRAM_WRITEBACK=y\n' >> "$DC2"
bash "$ENABLE" "$DC2" 1 > /dev/null 2>&1
check_line "'is not set' replaced by =y" "CONFIG_ZRAM=y" "$DC2"
if grep -qxF '# CONFIG_ZRAM is not set' "$DC2"; then
  bad "the old '# CONFIG_ZRAM is not set' line survived"
else
  ok "the old 'is not set' line was removed"
fi
if grep -qxF 'CONFIG_ZRAM_WRITEBACK=y' "$DC2"; then
  bad "CONFIG_ZRAM_WRITEBACK=y survived"
else
  ok "a pre-existing CONFIG_ZRAM_WRITEBACK=y was turned off"
fi

echo "=== enable-zram.sh: ENABLE=0 is a no-op ==="
DC3="${TMPROOT}/defconfig3"
make_defconfig "$DC3"
BEFORE="$(cat "$DC3")"
bash "$ENABLE" "$DC3" 0 > /dev/null 2>&1
if [ "$BEFORE" = "$(cat "$DC3")" ]; then
  ok "defconfig untouched with ENABLE=0"
else
  bad "ENABLE=0 modified the defconfig"
fi

echo "=== enable-zram.sh: a missing defconfig is a hard error ==="
set +e
bash "$ENABLE" "${TMPROOT}/does-not-exist" 1 > /dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] && ok "exits non-zero on a missing defconfig" || bad "accepted a missing defconfig"

echo "=== assert-zram.sh: passes on a good build ==="
GOOD="${TMPROOT}/good"
make_generated_config "$GOOD"
make_busybox_config "$GOOD" good
run_assert "$GOOD" 1
[ "$RC" -eq 0 ] && ok "exit 0 on a kernel with zram" || { bad "rejected a good build"; cat "$GOOD/assert.log" >&2; }

echo "=== assert-zram.sh: catches every way the feature can be lost ==="
for knob in no_zram=1 no_zsmalloc=1 no_lzo=1 no_swap=1 modular_zram=1 writeback=1; do
  DIR="${TMPROOT}/broken_${knob%%=*}"
  make_generated_config "$DIR" "$knob"
  make_busybox_config "$DIR" good
  run_assert "$DIR" 1
  if [ "$RC" -ne 0 ]; then
    ok "fails the build on ${knob%%=*}"
  else
    bad "${knob%%=*} was NOT caught"
  fi
done

echo "=== assert-zram.sh: catches a busybox without the swap applets ==="
BB="${TMPROOT}/nobusyboxswap"
make_generated_config "$BB"
make_busybox_config "$BB" bad
run_assert "$BB" 1
[ "$RC" -ne 0 ] && ok "fails when busybox has no swapon applet" || bad "a busybox without swapon was accepted"

echo "=== assert-zram.sh: EXPECT_ZRAM=0 inverts the check ==="
OFF="${TMPROOT}/off"
make_generated_config "$OFF" no_zram=1
run_assert "$OFF" 0
[ "$RC" -eq 0 ] && ok "exit 0 when zram is off and expected off" || bad "rejected a legitimately zram-less build"
run_assert "$GOOD" 0
[ "$RC" -ne 0 ] && ok "fails when zram is on but expected off" || bad "did not notice zram was enabled"

echo "=== assert-zram.sh: a missing kernel .config is a hard error ==="
EMPTY="${TMPROOT}/empty"
mkdir -p "$EMPTY/sysdrv"
run_assert "$EMPTY" 1
[ "$RC" -ne 0 ] && ok "exits non-zero when it cannot find the generated config" || bad "verified nothing and said it was fine"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
