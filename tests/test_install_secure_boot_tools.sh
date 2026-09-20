#!/usr/bin/env bash
#
# Tests opt/build.sh's install_secure_boot_tools(), which puts the Luckfox
# secure-boot signers on the Pi / La Frite images as OS-provided tooling.
#
# These boards are not Luckfox boards; they are the machine that SIGNS a Luckfox
# release. The OS owns the signers and the app imports them at runtime, so this
# install is the only copy on the image.
#
# The function is sourced out of build.sh rather than reimplemented, so this
# tests what actually ships.
#
# Run: bash tests/test_install_secure_boot_tools.sh
set -o errexit -o pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src_dir="${repo_dir}/opt/luckfox/secure-boot"
rel="usr/lib/seedsigner/secure-boot"
signers="rkloader.py fitsign.py minisign.py luckfox_release.py"
fails=0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

ok()   { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }

# Pull the function out of build.sh and run it against a throwaway overlay.
# $1 = overlay dir, $2 = board config dir
run_install() {
  (
    set -o errexit -o pipefail
    export SOURCE_DATE_EPOCH=0
    cur_dir="${repo_dir}/opt"
    rootfs_overlay="$1"
    config_dir="$2"
    eval "$(sed -n '/^install_secure_boot_tools() {/,/^}/p' "${repo_dir}/opt/build.sh")"
    install_secure_boot_tools
  )
}

echo "== a board that carries the tooling"
a="${work}/a"; board_a="${work}/board-a"
mkdir -p "${a}" "${board_a}"
run_install "${a}" "${board_a}" >/dev/null
for f in ${signers}; do
  if [ -x "${a}/${rel}/${f}" ]; then ok "${rel}/${f} installed and executable"
  else fail "${rel}/${f} missing or not executable"; fi
  if cmp -s "${src_dir}/${f}" "${a}/${rel}/${f}"; then ok "${f} matches seedsigner-os"
  else fail "${f} differs from seedsigner-os"; fi
done

echo "== installed outside /opt, so the app clone cannot disturb it"
if [ ! -e "${a}/opt" ]; then ok "nothing written under /opt"
else fail "wrote into /opt, which download_app_repo() wipes"; fi

echo "== a board whose defconfig opts out"
b="${work}/b"; board_b="${work}/board-b"
mkdir -p "${b}" "${board_b}"
touch "${board_b}/no-secure-boot-tools"
out="$(run_install "${b}" "${board_b}")"
if [ ! -d "${b}/${rel}" ]; then ok "tooling not installed"
else fail "tooling installed despite the opt-out"; fi
if grep -q "skipped" <<<"${out}"; then ok "skip reported"
else fail "skip not reported"; fi

echo "== opting out on a no-clean rebuild clears a previously installed copy"
touch "${board_a}/no-secure-boot-tools"
run_install "${a}" "${board_a}" >/dev/null
if [ ! -d "${a}/${rel}" ]; then ok "stale copy removed"
else fail "stale copy left behind"; fi
rm -f "${board_a}/no-secure-boot-tools"

echo "== mtimes normalised for reproducible images"
run_install "${a}" "${board_a}" >/dev/null
if [ -z "$(find "${a}/${rel}" -newermt "@1" -print -quit)" ]; then
  ok "installed files carry SOURCE_DATE_EPOCH"
else
  fail "installed files have live mtimes"
fi

echo "== the installed signers run, and import each other"
if python3 "${a}/${rel}/rkloader.py" --help >/dev/null 2>&1; then ok "rkloader.py runs"
else fail "rkloader.py does not run"; fi
# fitsign imports rkloader from its own directory -- this is what breaks if the
# three are ever installed apart.
if python3 "${a}/${rel}/fitsign.py" --help >/dev/null 2>&1; then ok "fitsign.py runs (finds rkloader beside it)"
else fail "fitsign.py cannot import rkloader from the install dir"; fi
if python3 "${a}/${rel}/minisign.py" --help >/dev/null 2>&1; then ok "minisign.py runs"
else fail "minisign.py does not run"; fi
if python3 "${a}/${rel}/luckfox_release.py" --help >/dev/null 2>&1; then ok "luckfox_release.py runs (finds all three signers beside it)"
else fail "luckfox_release.py cannot import the signers from the install dir"; fi

# The Luckfox builds have their own copy (os-build.sh, kept in lockstep with
# build-local.sh). Every board carries the tooling - including the Pico Mini:
# the signers are ~55 KB of stdlib and the heavy paths stream, so an earlier
# OOM there was a full-file read bug since fixed. The app warns when free
# memory is low before running the heavy actions.
run_luckfox_install() {
  (
    set -o errexit -o pipefail
    export SOURCE_DATE_EPOCH=0
    SEEDSIGNER_LUCKFOX_DIR="${repo_dir}/opt/luckfox"
    ROOTFS_DIR="$1"
    print_info() { :; }; print_success() { :; }; print_error() { echo "$*" >&2; }
    eval "$(sed -n '/^install_secure_boot_tools() {/,/^}/p' "${repo_dir}/opt/luckfox/os-build.sh")"
    install_secure_boot_tools
  )
}

echo "== Luckfox: every board carries the tooling, Pico Mini included"
for board in max pi mini; do
  r="${work}/luckfox-${board}"; mkdir -p "${r}"
  run_luckfox_install "${r}"
  if [ -x "${r}/${rel}/luckfox_release.py" ]; then ok "${board}: installed"
  else fail "${board}: not installed"; fi
done

echo
if [ "${fails}" -eq 0 ]; then
  echo "PASS"
else
  echo "FAILED (${fails})"
  exit 1
fi
