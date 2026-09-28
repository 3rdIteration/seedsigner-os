#!/bin/sh
#
# embit's secp256k1 must be the compiled libsecp256k1 and there must be no
# trace of the pure python secp256k1 fallback.
#
# Two things can go wrong, and they are not equally visible:
#
#   - libsecp256k1 is missing or unusable. embit raises at import and the app
#     never starts. Loud, but much better caught at build time than on first
#     boot. Checks 2-4.
#
#   - The pure python fallback is back in the image. Now if the library ever
#     fails to load, embit no longer raises -- it quietly signs with python
#     instead, on a device that looks and behaves like a working one. Checks 1
#     and 5.
#
# Rewritten (SeedSigner fork, 3rdIteration) for embit 0.8.2, as upstream's
# version of this script anticipated: embit no longer ships prebuilt binaries,
# so python-embit.mk builds libsecp256k1 itself and installs it as the single
# prebuilt/libsecp256k1.so (checks 3-4), patches secp256k1.py to bind only the
# compiled library, and checks at build time that the library exports every
# symbol the bindings use. Check 5 proves that patch reached the image.
#
# Still deliberately coupled to the layout python-embit.mk produces: an embit
# bump that changes it trips a check rather than passing quietly.
#
# Usage: verify-secp256k1-binary.sh <target-dir>
#
# Called at the end of each board's post-build.sh -- the last thing to touch the
# target tree.

set -u
set -e

TARGET_DIR="${1:?usage: verify-secp256k1-binary.sh <target-dir>}"

fail() {
	echo "ERROR: verify-secp256k1-binary: $1" >&2
	exit 1
}

# usr/lib/python3 (and python3.10 on some boards) are symlinks to the real
# python3.X tree, so resolve to the one physical directory rather than globbing
# (which would report each file several times). Boards without the python3
# symlink are found through python3.*.
UTIL_DIR=""
for sp in "${TARGET_DIR}/usr/lib/python3/site-packages" "${TARGET_DIR}"/usr/lib/python3.*/site-packages; do
	if UTIL_DIR="$(cd "${sp}/embit/util" 2>/dev/null && pwd -P)"; then
		break
	fi
	UTIL_DIR=""
done
[ -n "${UTIL_DIR}" ] || fail "embit is not installed under ${TARGET_DIR}/usr/lib/python3*/site-packages"

# 1. The pure-Python implementation must not be installed, as source or bytecode.
#    Scanning the whole tree rather than the known path also catches a stray copy
#    left anywhere else in the image. The glob deliberately covers every form the
#    module could take: py_secp256k1.py, the flat py_secp256k1.pyc that
#    site-packages ships, and the py_secp256k1.cpython-312.pyc that a __pycache__
#    directory would hold.
#
#    Two separate failures, in this order:
#      a) the sweep itself did not finish (find exited non-zero, e.g. a directory
#         it could not read), so part of the tree went unexamined and a clean
#         result would only mean "did not look there";
#      b) the sweep finished and turned something up.
#    (a) has to be ruled out first: an empty result from a find that died reads
#    exactly like an empty result from a find that found nothing.
if ! STRAYS="$(find "${TARGET_DIR}" -name 'py_secp256k1.*')"; then
	fail "could not scan ${TARGET_DIR} for the pure-Python fallback -- see find's errors above. The scan did not cover the whole tree, so the python secp256k1 fallback's absence is unproven and the build stops here."
fi
if [ -n "${STRAYS}" ]; then
	fail "pure-Python secp256k1 fallback is present in the image:
${STRAYS}"
fi

# 2. The ctypes bindings and the module that selects them must both survive the
#    .py/.pyc sweeps. Release images ship .pyc only; dev images ship both.
for mod in secp256k1 ctypes_secp256k1; do
	[ -f "${UTIL_DIR}/${mod}.pyc" ] || [ -f "${UTIL_DIR}/${mod}.py" ] \
		|| fail "embit/util/${mod} is missing -- embit cannot bind to libsecp256k1"
done

# 3. The library python-embit.mk builds must ship, at the architecture-neutral
#    name embit's loader probes in prebuilt/ (libsecp256k1.so). Buildroot's
#    check-bin-arch has already confirmed it is built for the target.
[ -f "${UTIL_DIR}/prebuilt/libsecp256k1.so" ] \
	|| fail "prebuilt/libsecp256k1.so is missing -- embit has no library to load"

# 4. Nothing else should be in prebuilt/. A second library here could be the one
#    embit's loader picks, and a foreign-platform binary is dead weight in a
#    signing image.
#    Same two-part shape as check 1: the scan must complete before an empty
#    result can be read as "nothing extra".
#    -mindepth 1 rather than -type f, so a symlink or a subdirectory counts as
#    "something else" too, and -path rather than -name, so the exemption
#    applies to that exact entry and not to any file that merely shares its
#    basename further down.
if ! EXTRA="$(find "${UTIL_DIR}/prebuilt" -mindepth 1 \
	! -path "${UTIL_DIR}/prebuilt/libsecp256k1.so")"; then
	fail "could not scan ${UTIL_DIR}/prebuilt -- see find's errors above"
fi
if [ -n "${EXTRA}" ]; then
	fail "unexpected files in embit/util/prebuilt:
${EXTRA}"
fi

# 5. The shipped secp256k1 module must not import py_secp256k1. Unpatched embit
#    0.8.2 does so unconditionally (to fill in optional functions), so with check
#    1 satisfied it could not even be imported; this catches the SeedSignerOS
#    patch not having been applied. The name survives compilation as a string
#    constant, so the .pyc can be searched as well as the .py.
for f in "${UTIL_DIR}/secp256k1.py" "${UTIL_DIR}/secp256k1.pyc"; do
	[ -f "${f}" ] || continue
	if grep -aq 'py_secp256k1' "${f}"; then
		fail "${f#"${TARGET_DIR}"} still references py_secp256k1 -- 0001-SeedSignerOS-secp256k1-compiled-library-only.patch was not applied"
	fi
done

echo "verify-secp256k1-binary: OK (compiled libsecp256k1 only, no Python fallback)"
