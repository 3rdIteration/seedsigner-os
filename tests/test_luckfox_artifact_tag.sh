#!/usr/bin/env bash
#
# Tests opt/luckfox/artifact-tag.sh, the Luckfox artifact name tag shared by
# os-build.sh and build-local.sh.
#
# The case that motivated the -dev-<lever> tokens: the SeSi-0.8.7+ShSi-B13-pre
# seedsigner-os release was a non-dev build with the serial console forced on.
# It was named "...-osproduction-signed-devkey", and a user flashed it as a
# production image; it stalls after the secure-boot screen.
#
# Run: bash tests/test_luckfox_artifact_tag.sh
set -o errexit -o pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="${repo_dir}/opt/luckfox/artifact-tag.sh"
fails=0

ok()   { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

expect() {  # <expected tag> <key=value>...
  local want="$1"; shift
  local got
  got="$(bash "${tool}" "$@")" || { fail "exit $? for: $*"; return; }
  if [ "${got}" = "${want}" ]; then ok "${want}"
  else fail "want ${want}, got ${got} (args: $*)"; fi
}

expect_error() {  # <description> <key=value>...
  local desc="$1"; shift
  if bash "${tool}" "$@" >/dev/null 2>&1; then fail "accepted ${desc}"
  else ok "rejects ${desc}"; fi
}

ref="appref=SeSi-0.8.7+ShSi-B13"
prod="${ref} variant=non-dev fit_signature=1"

echo "== clean production names are unchanged"
expect "SeSi-0.8.7_ShSi-B13-osproduction-signed-devkey" ${prod}
expect "SeSi-0.8.7_ShSi-B13-osproduction-unsigned" ${ref} variant=non-dev
expect "SeSi-0.8.7_ShSi-B13-osproduction-signed-devkey" ${prod} \
  usb_mode=host debug_network=off readonly_rootfs=1 boot_log=off harden_adb=on
expect "SeSi-0.8.7_ShSi-B13-osproduction-burnable-realkey" ${prod} burn_key_hash=1 real_key=1

echo "== the B13-pre release: production with the console on"
expect "SeSi-0.8.7_ShSi-B13-pre-osproduction-dev-uart-signed-devkey" \
  appref=SeSi-0.8.7+ShSi-B13-pre variant=non-dev fit_signature=1 uart_console=on

echo "== develop builds: only uart and testing are named"
expect "dev-osdevelop-signed-devkey" appref=dev variant=dev fit_signature=1 \
  usb_mode=gadget debug_network=on readonly_rootfs=0 boot_log=on harden_adb=off
expect "dev-osdevelop-dev-uart-signed-devkey" appref=dev variant=dev fit_signature=1 uart_console=on
expect "dev-osdevelop-dev-testing-unsigned" appref=dev variant=dev testing=1

echo "== every production lever, in fixed order"
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-adb-signed-devkey" ${prod} usb_mode=gadget
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-otg-signed-devkey" ${prod} usb_mode=otg
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-net-signed-devkey" ${prod} debug_network=on
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-rw-signed-devkey" ${prod} readonly_rootfs=0
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-bootlog-signed-devkey" ${prod} boot_log=on
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-adbfiles-signed-devkey" ${prod} harden_adb=off
expect "SeSi-0.8.7_ShSi-B13-osproduction-dev-uart-dev-testing-dev-adb-dev-net-dev-rw-dev-bootlog-dev-adbfiles-signed-devkey" \
  ${prod} harden_adb=off boot_log=on readonly_rootfs=0 debug_network=on usb_mode=gadget testing=1 uart_console=on

echo "== production auto values resolve to production defaults"
expect "SeSi-0.8.7_ShSi-B13-osproduction-signed-devkey" ${prod} usb_mode=auto debug_network=auto readonly_rootfs=auto

echo "== bad input fails instead of naming silently"
expect_error "a missing appref" variant=non-dev
expect_error "an unknown variant" ${ref} variant=prod
expect_error "an unknown key" ${prod} uart=on
expect_error "a bare argument" ${prod} uart_console
expect_error "a non on/off uart_console" ${prod} uart_console=1
expect_error "an unknown usb_mode" ${prod} usb_mode=device

if [ "${fails}" -ne 0 ]; then
  echo "${fails} failure(s)"
  exit 1
fi
echo "all passed"
