#!/bin/sh
#
# embit's secp256k1 must be the pre-compiled libsecp256k1 and there must be no
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
#     instead, on a device that looks and behaves like a working one. Check 1.
#
# This is a gatekeeper for the embit version pinned in python-embit.mk, not a
# permanent fixture. Both projects are moving the same direction: upstream embit
# has dropped the prebuilt binaries from its recent releases, on the reasoning
# that each application is better off compiling libsecp256k1 itself, and there is
# an open PR there to remove the pure python fallback outright. SeedSigner
# intends to land in the same place -- no fallback in the tree at all, and our
# own build of libsecp256k1. At that point checks 3 and 4 describe a layout that
# no longer exists and this script should be rewritten or retired.
#
# Until then it stays deliberately coupled to the layout embit ships today. An
# embit bump will trip checks 3 and 4 rather than pass quietly, and that is the
# intended behavior: bumping embit here is a rare and deliberate act, so the
# build stopping is how it earns the attention it deserves.
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

# usr/lib/python3 and python3.10 are symlinks to python3.12, so resolve to the
# one physical tree rather than globbing (which would report each file 3x).
UTIL_DIR="$(cd "${TARGET_DIR}/usr/lib/python3/site-packages/embit/util" 2>/dev/null && pwd -P)" \
	|| fail "embit is not installed under ${TARGET_DIR}/usr/lib/python3/site-packages"

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

# 3. Both ARM prebuilts must ship. All eight board configs are 32-bit ARM
#    (BR2_arm=y), so platform.machine() reports armv6l (pi0) or armv7l (the rest)
#    and embit looks up prebuilt/libsecp256k1_linux_<machine>.so by that exact
#    name. Neither file alone covers every board.
for so in libsecp256k1_linux_armv6l.so libsecp256k1_linux_armv7l.so; do
	[ -f "${UTIL_DIR}/prebuilt/${so}" ] \
		|| fail "prebuilt/${so} is missing -- boards reporting that machine type would have no library to load"
done

# 4. Nothing else should be in prebuilt/. A foreign-platform binary here is dead
#    weight in a signing image, and its presence means the post-build cleanup has
#    drifted from the set of files embit actually installs.
#    Same two-part shape as check 1: the scan must complete before an empty
#    result can be read as "nothing extra".
#    -mindepth 1 rather than -type f, so a symlink or a subdirectory counts as
#    "something else" too, and -path rather than -name, so the two exemptions
#    apply to those exact two entries and not to any file that merely shares
#    their basename further down.
if ! EXTRA="$(find "${UTIL_DIR}/prebuilt" -mindepth 1 \
	! -path "${UTIL_DIR}/prebuilt/libsecp256k1_linux_armv6l.so" \
	! -path "${UTIL_DIR}/prebuilt/libsecp256k1_linux_armv7l.so")"; then
	fail "could not scan ${UTIL_DIR}/prebuilt -- see find's errors above"
fi
if [ -n "${EXTRA}" ]; then
	fail "unexpected files in embit/util/prebuilt:
${EXTRA}"
fi

echo "verify-secp256k1-binary: OK (pre-compiled libsecp256k1 only, no Python fallback)"
