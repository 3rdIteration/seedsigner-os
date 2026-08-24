#!/bin/bash
# Test the S03zram init script's logic against a synthetic /sys, /proc and /dev.
#
# S03zram cannot be run as-is on a build host: it drives a real zram device
# through sysfs and calls mkswap/swapon on it. So each case here builds a mock
# tree, rewrites ONLY the absolute paths in a copy of the script (the six
# literals below), and puts recording stubs for mkswap/swapon/swapoff/mknod
# ahead of the real tools on PATH. Everything else about the script under test
# is byte-identical to what ships.
#
# What this is actually protecting: the sizing arithmetic, the sysfs write
# ORDER (comp_algorithm before disksize, or the driver returns -EBUSY), and the
# promise that every failure path still returns 0 — swap is headroom, and a
# board that boots without it beats a board that does not boot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${REPO_ROOT}/opt/luckfox/files/S03zram"

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

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

check_eq() {
  local what="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$what = '$actual'"
  else
    bad "$what: expected '$expected', got '$actual'"
  fi
}

check_contains() {
  local what="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    ok "$what"
  else
    bad "$what (no '$needle' in $(basename "$file"))"
    sed 's/^/       | /' "$file" >&2 2>/dev/null || true
  fi
}

check_not_contains() {
  local what="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    bad "$what (unexpected '$needle')"
  else
    ok "$what"
  fi
}

# Build a mock environment. $1 = case name, remaining args are key=value knobs:
#   mem=<kB>            MemTotal (default 51200, i.e. 50 MiB — a Mini)
#   algos=<string>      contents of comp_algorithm
#   disksize=<value>    starting contents of disksize (default 0)
#   swapped=1           pretend /dev/zram0 is already in /proc/swaps
#   nozram=1            no /sys/block/zram0 at all (kernel without zram)
#   nonode=1            do not pre-create /dev/zram0
#   swapon_rc=<n>       exit code for the swapon stub (default 0)
setup_case() {
  local name="$1"; shift
  local mem=51200 algos="lzo [lzo-rle] lz4 zstd" disksize=0
  local swapped=0 nozram=0 nonode=0 swapon_rc=0 kv

  for kv in "$@"; do
    case "$kv" in
      mem=*)       mem="${kv#mem=}" ;;
      algos=*)     algos="${kv#algos=}" ;;
      disksize=*)  disksize="${kv#disksize=}" ;;
      swapped=*)   swapped="${kv#swapped=}" ;;
      nozram=*)    nozram="${kv#nozram=}" ;;
      nonode=*)    nonode="${kv#nonode=}" ;;
      swapon_rc=*) swapon_rc="${kv#swapon_rc=}" ;;
      *) echo "unknown knob: $kv" >&2; exit 1 ;;
    esac
  done

  MOCK="${TMPROOT}/${name}"
  rm -rf "$MOCK"
  mkdir -p "$MOCK/proc/sys/vm" "$MOCK/dev" "$MOCK/bin"

  printf 'MemTotal:       %s kB\nMemFree:         1024 kB\n' "$mem" > "$MOCK/proc/meminfo"
  printf 'Filename\t\t\t\tType\t\tSize\tUsed\tPriority\n' > "$MOCK/proc/swaps"
  printf '60\n' > "$MOCK/proc/sys/vm/swappiness"
  printf '3\n' > "$MOCK/proc/sys/vm/page-cluster"
  : > "$MOCK/dev/kmsg"

  if [ "$nozram" != "1" ]; then
    mkdir -p "$MOCK/sys/block/zram0"
    printf '%s\n' "$algos"    > "$MOCK/sys/block/zram0/comp_algorithm"
    printf '%s\n' "$disksize" > "$MOCK/sys/block/zram0/disksize"
    printf 'UNSET\n'          > "$MOCK/sys/block/zram0/mem_limit"
    printf 'UNSET\n'          > "$MOCK/sys/block/zram0/reset"
    printf '254:0\n'          > "$MOCK/sys/block/zram0/dev"
  fi

  [ "$nonode" = "1" ] || : > "$MOCK/dev/zram0"

  if [ "$swapped" = "1" ]; then
    printf '%s/dev/zram0\tpartition\t25600\t0\t-2\n' "$MOCK" >> "$MOCK/proc/swaps"
  fi

  CALLS="$MOCK/calls.log"
  : > "$CALLS"

  # Recording stubs. mknod also creates the node so the script's own -e check
  # behaves the way it would against a real /dev.
  cat > "$MOCK/bin/mkswap" <<STUB
#!/bin/sh
echo "mkswap \$*" >> "$CALLS"
exit 0
STUB
  cat > "$MOCK/bin/swapon" <<STUB
#!/bin/sh
echo "swapon \$*" >> "$CALLS"
exit $swapon_rc
STUB
  cat > "$MOCK/bin/swapoff" <<STUB
#!/bin/sh
echo "swapoff \$*" >> "$CALLS"
exit 0
STUB
  cat > "$MOCK/bin/mknod" <<STUB
#!/bin/sh
echo "mknod \$*" >> "$CALLS"
: > "\$1"
exit 0
STUB
  chmod +x "$MOCK/bin/"*

  # Rewrite only the absolute paths; the logic under test is untouched.
  SUT="$MOCK/S03zram"
  sed -e "s|/sys/block/zram0|${MOCK}/sys/block/zram0|g" \
      -e "s|/dev/zram0|${MOCK}/dev/zram0|g" \
      -e "s|/dev/kmsg|${MOCK}/dev/kmsg|g" \
      -e "s|/proc/meminfo|${MOCK}/proc/meminfo|g" \
      -e "s|/proc/swaps|${MOCK}/proc/swaps|g" \
      -e "s|/proc/sys/vm/|${MOCK}/proc/sys/vm/|g" \
      "$SRC" > "$SUT"
  chmod +x "$SUT"
}

run_sut() {
  local action="${1:-start}"
  set +e
  PATH="$MOCK/bin:$PATH" sh "$SUT" "$action" > "$MOCK/out.log" 2>&1
  RC=$?
  set -e
}

echo "=== S03zram: happy path on a 50 MiB Mini ==="
setup_case happy
run_sut start
check_eq "exit code" "0" "$RC"
# 50% of 51200 kB = 25600 kB; 25% = 12800 kB. Written with a K suffix, which is
# what the kernel's memparse() expects.
check_eq "disksize"  "25600K" "$(cat "$MOCK/sys/block/zram0/disksize")"
check_eq "mem_limit" "12800K" "$(cat "$MOCK/sys/block/zram0/mem_limit")"
check_eq "compressor" "lzo-rle" "$(cat "$MOCK/sys/block/zram0/comp_algorithm")"
check_eq "swappiness" "100" "$(cat "$MOCK/proc/sys/vm/swappiness")"
check_eq "page-cluster" "0" "$(cat "$MOCK/proc/sys/vm/page-cluster")"
check_contains "mkswap ran on the zram device" "mkswap ${MOCK}/dev/zram0" "$CALLS"
check_contains "swapon ran on the zram device" "swapon ${MOCK}/dev/zram0" "$CALLS"
# busybox here is built without FEATURE_SWAPON_PRI, so a -p would just fail.
check_not_contains "swapon is called without -p" "swapon -p" "$CALLS"
check_contains "reports the size it brought up" "compressed swap active: 25 MiB" "$MOCK/out.log"
check_contains "logs to the kernel ring buffer" "[zram]" "$MOCK/dev/kmsg"

echo "=== S03zram: sizing scales with RAM (256 MiB board) ==="
setup_case big mem=249856
run_sut start
check_eq "exit code" "0" "$RC"
check_eq "disksize"  "124928K" "$(cat "$MOCK/sys/block/zram0/disksize")"
check_eq "mem_limit" "62464K" "$(cat "$MOCK/sys/block/zram0/mem_limit")"

echo "=== S03zram: kernel without zram is a clean skip, not a failure ==="
setup_case nozram nozram=1
run_sut start
check_eq "exit code" "0" "$RC"
check_contains "says the image lost its headroom" "running WITHOUT compressed swap" "$MOCK/out.log"
check_eq "nothing was swapped on" "" "$(cat "$CALLS")"

echo "=== S03zram: already-active swap is left alone ==="
setup_case active swapped=1 disksize=26214400
run_sut start
check_eq "exit code" "0" "$RC"
check_contains "recognizes the active device" "already swapped on" "$MOCK/out.log"
check_eq "disksize untouched" "26214400" "$(cat "$MOCK/sys/block/zram0/disksize")"
check_eq "no mkswap/swapon" "" "$(cat "$CALLS")"

echo "=== S03zram: an initialized device is reset before resizing ==="
setup_case reinit disksize=8388608
run_sut start
check_eq "exit code" "0" "$RC"
check_eq "reset was written" "1" "$(cat "$MOCK/sys/block/zram0/reset")"
check_eq "disksize re-sized" "25600K" "$(cat "$MOCK/sys/block/zram0/disksize")"

echo "=== S03zram: unknown compressors leave the kernel default in place ==="
setup_case algo "algos=[zstd] deflate"
run_sut start
check_eq "exit code" "0" "$RC"
check_eq "comp_algorithm untouched" "[zstd] deflate" "$(cat "$MOCK/sys/block/zram0/comp_algorithm")"
check_contains "says it kept the default" "keeping the kernel default" "$MOCK/out.log"
check_contains "still brought swap up" "swapon ${MOCK}/dev/zram0" "$CALLS"

echo "=== S03zram: lzo is used when lzo-rle is absent ==="
setup_case algo_lzo "algos=[lzo] lz4"
run_sut start
check_eq "compressor" "lzo" "$(cat "$MOCK/sys/block/zram0/comp_algorithm")"

echo "=== S03zram: the device node is created when devtmpfs did not ==="
setup_case nonode nonode=1
run_sut start
check_eq "exit code" "0" "$RC"
check_contains "mknod used the sysfs major:minor" "mknod ${MOCK}/dev/zram0 b 254 0" "$CALLS"
check_contains "swap still came up" "swapon ${MOCK}/dev/zram0" "$CALLS"

echo "=== S03zram: a failing swapon does not fail the boot ==="
setup_case swaponfail swapon_rc=1
run_sut start
check_eq "exit code" "0" "$RC"
check_contains "reports the failure" "swapon failed" "$MOCK/out.log"

echo "=== S03zram: implausible MemTotal is skipped rather than acted on ==="
setup_case tiny mem=4096
run_sut start
check_eq "exit code" "0" "$RC"
check_contains "refuses a pointless device" "too small" "$MOCK/out.log"
check_eq "nothing was swapped on" "" "$(cat "$CALLS")"

echo "=== S03zram: stop swaps the device off ==="
setup_case stopcase swapped=1
run_sut stop
check_eq "exit code" "0" "$RC"
check_contains "swapoff ran" "swapoff ${MOCK}/dev/zram0" "$CALLS"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] || exit 1
