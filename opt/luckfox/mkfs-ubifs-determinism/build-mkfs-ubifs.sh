#!/usr/bin/env bash
#
# build-mkfs-ubifs.sh <LUCKFOX_PICO_DIR> <OUT_BIN>
#
# Build a patched mkfs.ubifs that numbers inodes deterministically, and put it
# at OUT_BIN. Called by patch-fs-determinism.sh; the resulting binary is then
# forced on mkfs_ubi.sh via MKUBIFS_TOOL so every ubifs volume (oem, userdata)
# is packed with it.
#
# Why: stock mkfs.ubifs assigns inode numbers in the order readdir() returns
# directory entries. That order depends on the host file system (ext4 vs
# overlayfs vs tmpfs), so two builds of an identical /oem tree on different
# machines produced different inode numbers -- and therefore
# byte-different oem.img/userdata.img even though every file's content was
# identical. The patch (sort-dirents.patch) makes add_directory() collect all
# entries first and process them in strcmp-sorted name order, so the traversal
# -- and with it inode numbering, node placement, sqnums and LPT layout -- is
# a pure function of the tree's contents.
#
# The SDK ships mkfs.ubifs as a prebuilt static binary (sysdrv/out/bin/pc), so
# we rebuild it here from the pinned SDK source instead of patching in place:
#   - sources are copied to a temp dir, never modified in the checkout;
#   - lzo and uuid headers are vendored next to this script with SHA-256 pins
#     (the build image carries only the runtime .so files, no dev headers);
#   - linking is dynamic against the image's own liblzo2/libuuid/zlib, so the
#     tool runs in exactly the environment that produces the images.
#
# The SDK ships mtd-utils as a tarball (mtd-utils-2.0.1.tar.bz2) and only
# extracts it during its own tools build, which runs AFTER this script. On a
# pristine checkout the extracted tree is therefore absent; in that case we
# unpack the git-tracked tarball into our temp dir instead of the checkout.

set -eu

SDK_DIR="${1:-}"
OUT_BIN="${2:-}"
if [ -z "$SDK_DIR" ] || [ ! -d "$SDK_DIR" ] || [ -z "$OUT_BIN" ]; then
    echo "usage: build-mkfs-ubifs.sh <LUCKFOX_PICO_DIR> <OUT_BIN>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MTD_BASE="$SDK_DIR/sysdrv/tools/board/mtd-utils"
MTD_ROOT="$MTD_BASE/mtd-utils-2.0.1"
SRC="$MTD_ROOT/ubifs-utils/mkfs.ubifs"
PATCH="$SCRIPT_DIR/sort-dirents.patch"

# --- 1. verify the vendored headers -----------------------------------------
verify() { # $1=file $2=expected sha256
    local actual
    if [ ! -f "$1" ]; then
        echo "build-mkfs-ubifs: missing vendored header $1" >&2
        exit 1
    fi
    actual="$(sha256sum "$1" | cut -d' ' -f1)"
    if [ "$actual" != "$2" ]; then
        echo "build-mkfs-ubifs: SHA-256 mismatch for $1" >&2
        echo "  expected $2" >&2
        echo "  actual   $actual" >&2
        exit 1
    fi
}

verify "$SCRIPT_DIR/lzo/lzo1x.h"   010e47f9a1fb11611fec58ed71781e6129e2693448afc4dddcfd92110ac807f8
verify "$SCRIPT_DIR/lzo/lzoconf.h" 63bf0574a0df2fa703060282cc5cfa60d86e73d11b1a5f2faf261ffe6809f99d
verify "$SCRIPT_DIR/lzo/lzodefs.h" 7cdc24f7d8762f0908b30f4959442798427af8c01c6d925f5594114a45a2a89e
verify "$SCRIPT_DIR/uuid.h"        883bef35f0766a9d520bf9cfde86bea86c1dc47a675f68fae3cb1f2dcbe3088d

# --- 2. prerequisites --------------------------------------------------------
command -v gcc >/dev/null || { echo "build-mkfs-ubifs: gcc not found" >&2; exit 1; }
[ -f "$PATCH" ]            || { echo "build-mkfs-ubifs: $PATCH not found" >&2; exit 1; }

LZO_SO=/usr/lib/x86_64-linux-gnu/liblzo2.so.2
UUID_SO=/usr/lib/x86_64-linux-gnu/libuuid.so.1
[ -e "$LZO_SO" ]  || { echo "build-mkfs-ubifs: $LZO_SO not found (liblzo2 runtime missing)" >&2; exit 1; }
[ -e "$UUID_SO" ] || { echo "build-mkfs-ubifs: $UUID_SO not found (libuuid runtime missing)" >&2; exit 1; }

# --- 3. locate the mtd-utils sources -----------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$SRC/mkfs.ubifs.c" ]; then
    TARBALL="$MTD_BASE/mtd-utils-2.0.1.tar.bz2"
    if [ ! -f "$TARBALL" ]; then
        echo "build-mkfs-ubifs: no mtd-utils sources (neither $SRC nor $TARBALL)" >&2
        exit 1
    fi
    tar xjf "$TARBALL" -C "$TMP" || {
        echo "build-mkfs-ubifs: cannot extract $TARBALL" >&2
        exit 1
    }
    MTD_ROOT="$TMP/mtd-utils-2.0.1"
    SRC="$MTD_ROOT/ubifs-utils/mkfs.ubifs"
fi

[ -f "$SRC/mkfs.ubifs.c" ]      || { echo "build-mkfs-ubifs: $SRC/mkfs.ubifs.c not found (SDK source changed?)" >&2; exit 1; }
[ -f "$MTD_ROOT/include/common.h" ] || { echo "build-mkfs-ubifs: $MTD_ROOT/include/common.h not found" >&2; exit 1; }

# --- 4. copy sources, apply the patch, compile -------------------------------
cp -r "$SRC" "$TMP/src"
patch -p1 -d "$TMP/src" < "$PATCH" >/dev/null || {
    echo "build-mkfs-ubifs: sort-dirents.patch failed to apply (SDK source changed?)" >&2
    exit 1
}

mkdir -p "$(dirname "$OUT_BIN")"
gcc -O2 \
    -I"$SCRIPT_DIR" \
    -I"$TMP/src" \
    -I"$TMP/src/hashtable" \
    -I"$MTD_ROOT/include" \
    -o "$OUT_BIN" \
    "$TMP/src/mkfs.ubifs.c" \
    "$TMP/src/crc16.c" \
    "$TMP/src/lpt.c" \
    "$TMP/src/compr.c" \
    "$TMP/src/devtable.c" \
    "$TMP/src/hashtable/hashtable.c" \
    "$TMP/src/hashtable/hashtable_itr.c" \
    "$MTD_ROOT/lib/libubi.c" \
    "$MTD_ROOT/lib/libcrc32.c" \
    "$LZO_SO" "$UUID_SO" -lz -lm

[ -x "$OUT_BIN" ] || { echo "build-mkfs-ubifs: $OUT_BIN was not produced" >&2; exit 1; }
echo "build-mkfs-ubifs: deterministic mkfs.ubifs built at $OUT_BIN"
