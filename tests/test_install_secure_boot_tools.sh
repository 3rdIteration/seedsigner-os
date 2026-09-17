#!/usr/bin/env bash
#
# Tests opt/build.sh's install_secure_boot_tools(), which puts the Luckfox
# secure-boot signers on the Pi / La Frite images. Those boards are not Luckfox
# boards; they are the machine that SIGNS a Luckfox release.
#
# The function is sourced out of build.sh rather than reimplemented, so this
# tests the thing that actually ships.
#
# Run: bash tests/test_install_secure_boot_tools.sh
set -o errexit -o pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src_dir="${repo_dir}/opt/luckfox/secure-boot"
signers="rkloader.py fitsign.py minisign.py"
fails=0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

ok()   { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

# Pull the function out of build.sh and run it against a throwaway overlay.
run_install() {
  local overlay="$1"
  (
    set -o errexit -o pipefail
    export SOURCE_DATE_EPOCH=0
    cur_dir="${repo_dir}/opt"
    rootfs_overlay="${overlay}"
    eval "$(sed -n '/^install_secure_boot_tools() {/,/^}/p' "${repo_dir}/opt/build.sh")"
    install_secure_boot_tools
  )
}

make_app_tree() {
  local overlay="$1" with_helper="$2" f
  mkdir -p "${overlay}/opt/src/seedsigner/helpers"
  if [ "${with_helper}" = "yes" ]; then
    mkdir -p "${overlay}/opt/src/seedsigner/helpers/luckfox_secure_boot"
    for f in ${signers}; do
      cp "${src_dir}/${f}" "${overlay}/opt/src/seedsigner/helpers/luckfox_secure_boot/${f}"
    done
  fi
}

echo "== an app tree carrying the vendored helper"
a="${work}/a"
make_app_tree "${a}" yes
run_install "${a}" >/dev/null
for f in ${signers}; do
  if [ -x "${a}/opt/secure-boot/${f}" ]; then ok "/opt/secure-boot/${f} installed and executable"
  else fail "/opt/secure-boot/${f} missing or not executable"; fi
  if cmp -s "${src_dir}/${f}" "${a}/opt/secure-boot/${f}"; then ok "${f} matches seedsigner-os"
  else fail "${f} differs from seedsigner-os"; fi
done

echo "== a drifted vendored copy is reported and corrected"
echo "# drift introduced by the test" >> "${a}/opt/src/seedsigner/helpers/luckfox_secure_boot/rkloader.py"
out="$(run_install "${a}")"
if grep -q "warning: app's vendored rkloader.py differs" <<<"${out}"; then ok "drift reported"
else fail "drift was not reported"; fi
if cmp -s "${src_dir}/rkloader.py" "${a}/opt/src/seedsigner/helpers/luckfox_secure_boot/rkloader.py"; then
  ok "drift corrected from seedsigner-os"
else fail "vendored copy still drifted"; fi

echo "== an app branch without the helper still gets the CLIs"
b="${work}/b"
make_app_tree "${b}" no
out="$(run_install "${b}")"
if [ -f "${b}/opt/secure-boot/rkloader.py" ]; then ok "CLIs installed"
else fail "CLIs not installed"; fi
if grep -q "no luckfox_secure_boot helper" <<<"${out}"; then ok "absence noted, not fatal"
else fail "absence not reported"; fi

echo "== mtimes normalised for reproducible images"
if [ -z "$(find "${a}/opt/secure-boot" -newermt "@1" -print -quit)" ]; then
  ok "installed files carry SOURCE_DATE_EPOCH"
else
  fail "installed files have live mtimes"
fi

echo "== the installed CLIs actually run"
if python3 "${a}/opt/secure-boot/rkloader.py" --help >/dev/null 2>&1; then ok "rkloader.py runs"
else fail "rkloader.py does not run"; fi
# fitsign imports rkloader from its own directory - the install must keep them together
if python3 "${a}/opt/secure-boot/fitsign.py" --help >/dev/null 2>&1; then ok "fitsign.py runs (finds rkloader beside it)"
else fail "fitsign.py cannot import rkloader from the install dir"; fi
if python3 "${a}/opt/secure-boot/minisign.py" --help >/dev/null 2>&1; then ok "minisign.py runs"
else fail "minisign.py does not run"; fi

echo
if [ "${fails}" -eq 0 ]; then
  echo "PASS"
else
  echo "FAILED (${fails})"
  exit 1
fi
