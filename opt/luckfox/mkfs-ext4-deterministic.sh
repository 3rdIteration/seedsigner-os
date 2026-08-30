#!/bin/bash
# SS_DETERMINISM: SeedSigner deterministic ext4 builder (marker for idempotency)
#
# mkfs-ext4-deterministic.sh <source dir> <dest image> <partition size bytes>
#
# Drop-in replacement for the SDK's sysdrv/tools/pc/e2fsprogs/mkfs_ext4.sh
# (same interface), installed by patch-fs-determinism.sh section 7.
#
# The stock script runs `mkfs.ext4 -d <src>`, which is non-deterministic in
# three independent ways:
#
#   1. mke2fs -d populates the filesystem by walking the source tree with
#      readdir(), so inode NUMBERING and block placement depend on the host
#      file system (ext4 vs overlayfs vs tmpfs) and on how the staging tree
#      was populated -- not on its contents. Two builds of identical source
#      differed in ~16 MB of a 35 MB oem.img, purely from inode numbering
#      (e.g. /usr/bin was ino 24 on one machine and 13 on the other).
#   2. No -U is passed, so mke2fs generates a RANDOM UUID per build.
#   3. Every timestamp it writes -- superblock s_wtime/s_lastcheck, the
#      directory hash seed (s_hash_seed), and atime/ctime/mtime on every
#      inode including the reserved metadata inodes (bad_ino, resize_inode,
#      journal) -- is wall-clock build time.
#
# The fix builds an EMPTY filesystem with a fixed UUID, pins s_hash_seed
# BEFORE any directory entry exists (htree hashes are computed from it), then
# populates via debugfs from an explicitly SORTED file list so inode numbers
# and block placement depend only on the tree's contents. A final pass pins
# every remaining timestamp to SOURCE_DATE_EPOCH, and e2fsck -fn verifies the
# result before it is accepted.
#
# Verified byte-identical across repeated builds (4K-block trees, 1K-block
# trees with 128-byte inodes, and empty source dirs), with e2fsck clean.

set -eu

err() { echo "mkfs-ext4-deterministic: $*" >&2; exit 1; }

src="${1:-}"
dst="${2:-}"
part_size="${3:-}"

if [ -z "$src" ] || [ -z "$dst" ] || [ -z "$part_size" ] || [ ! -d "$src" ]; then
    echo "command format: $(basename "$0") <source> <dest image> <partition size>" >&2
    exit 1
fi

# Resolve the source to an absolute path: the debugfs command file references
# native files by that path, and build_mkimg may invoke us from an arbitrary
# CWD. The image path can stay as given -- this script never changes directory
# outside a subshell.
src="$(readlink -f "$src")" || err "cannot resolve source dir $src"

# Same tool resolution as the stock script: prefer an e2fsprogs build sitting
# next to this one, else whatever is on PATH. Both CI and local run in the
# same Docker image, so whichever wins is consistent across builds.
cwd="$(dirname "$(readlink -f "$0")")"
export PATH="$cwd:$PATH"

command -v mkfs.ext4 >/dev/null 2>&1 || err "mkfs.ext4 not found on PATH"
command -v debugfs   >/dev/null 2>&1 || err "debugfs not found on PATH"
command -v resize2fs >/dev/null 2>&1 || err "resize2fs not found on PATH"
command -v e2fsck    >/dev/null 2>&1 || err "e2fsck not found on PATH"
command -v python3   >/dev/null 2>&1 || err "python3 not found on PATH"

EPOCH="${SOURCE_DATE_EPOCH:-0}"
case "$EPOCH" in (*[!0-9]*|'') err "invalid SOURCE_DATE_EPOCH: $EPOCH" ;; esac

# The stock script truncates the partition size to whole MiB; keep that so the
# image it produces is the same shape as before (and, after resize2fs -M, no
# larger than its slot in the assembled disk image).
dst_size="$(( part_size / 1024 / 1024 ))M"

rm -f "$dst"
mkdir -p "$(dirname "$dst")"

# Fixed UUID derived from the destination name: stable across builds and
# machines, distinct per partition (oem vs userdata). Nothing on-device mounts
# these by UUID (bootargs use /dev/mmcblkXpY), so a constant is safe.
h="$(printf '%s' "seedsigner-os-ext4-$(basename "$dst")" | sha256sum | cut -c1-32)"
uuid="${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"

echo "mkfs.ext4 (deterministic) src=$src dst=$dst size=$dst_size uuid=$uuid epoch=$EPOCH"

# 1. Empty filesystem, fixed UUID, features pinned explicitly so the output
#    does not depend on this mke2fs's defaults (^metadata_csum matters: with
#    it set, pinning timestamps below would invalidate superblock/inode
#    checksums; the stock SDK images do not carry it).
mkfs.ext4 -q -r 1 -N 0 -m 5 -L "" -O ^64bit,^huge_file,^metadata_csum \
    -U "$uuid" "$dst" "$dst_size" || err "mkfs.ext4 failed for $dst"

# 2. Pin s_hash_seed (16 bytes at superblock offset +0xEC) in every superblock
#    instance BEFORE populating: directory entry hashes are computed from it,
#    so changing it afterwards would desync the stored htree hashes.
python3 - "$dst" <<'PYEOF' || err "hash-seed pinning failed"
import sys, struct
path = sys.argv[1]
seed = bytes.fromhex("00112233445566778899aabbccddeeff")
d = bytearray(open(path, 'rb').read())
n = len(d); i = 0; cnt = 0
while True:
    i = d.find(b'\x53\xef', i)          # s_magic (LE-stored EF53), at sb+0x38
    if i < 0: break
    sb = i - 0x38
    if sb >= 0 and sb + 0xE8 <= n:
        inodes = struct.unpack_from('<I', d, sb)[0]
        blocks = struct.unpack_from('<I', d, sb+4)[0]
        logbs  = struct.unpack_from('<I', d, sb+0x18)[0]
        if 0 < inodes < (1<<22) and 0 < blocks < (1<<26) and logbs in (0, 1, 2):
            d[sb+0xEC:sb+0xEC+16] = seed
            cnt += 1
    i += 1
if cnt == 0: sys.exit("no superblocks found")
open(path, 'wb').write(bytes(d))
print(f"  pinned s_hash_seed in {cnt} superblock instance(s)")
PYEOF

# 3. Populate from an explicitly sorted file list (LC_ALL=C sort by path), one
#    debugfs session. Parent paths always sort before their children, so no
#    separate directory pass is needed. Inode numbers and block placement now
#    depend only on the tree's contents.
cmds="$(mktemp)" || err "mktemp failed"
trap 'rm -f "$cmds" "$cmds.raw"' EXIT

( cd "$src" && find . -mindepth 1 -printf '%y %n %p\n' | LC_ALL=C sort -k3 ) > "$cmds.raw" \
    || err "find failed in $src"
: > "$cmds"
while read -r type links path; do
    [ -n "$path" ] || continue
    case "$type$path" in (*[[:space:]]*) err "unsupported filename (whitespace): $path" ;; esac
    p="${path#./}"
    case "$type" in
        d) echo "mkdir /$p" >> "$cmds" ;;
        f)
            if [ "${links:-1}" -gt 1 ]; then
                err "hard link at $path (nlink=$links): not handled, refusing to silently duplicate it"
            fi
            echo "write $src/$p /$p" >> "$cmds" ;;
        l) tgt="$(readlink "$src/$p")"; echo "symlink /$p $tgt" >> "$cmds" ;;
        *) err "unsupported entry type '$type' at $path (special files are not handled)" ;;
    esac
done < "$cmds.raw"

if [ -s "$cmds" ]; then
    debugfs -w -f "$cmds" "$dst" >/dev/null 2>&1 || err "debugfs populate failed for $dst"
fi

# 4. Shrink to the minimum size that fits the data (the stock script does this
#    too; it also keeps the file smaller than its slot in the assembled disk
#    image, where blkenvflash dd's it with no count limit).
resize2fs -M "$dst" >/dev/null 2>&1 || err "resize2fs -M failed for $dst"

# 5. Pin every remaining timestamp to EPOCH: superblock s_mtime/s_wtime/
#    s_lastcheck (+ one more time field at +0x108) in every superblock
#    instance, and atime/ctime/mtime/dtime (plus the extra-region time field
#    at inode offset +0x90 when inodes are 256 bytes) on EVERY inode slot --
#    including the reserved metadata inodes (bad_ino, resize_inode, journal),
#    which mke2fs stamps with wall-clock time and which cannot be reached by
#    name. The GDT is located by candidate search with structural sanity
#    checks (slot 1 must be free, slot 2 must be the root dir) before any byte
#    is touched; inode size is one of {128, 256} and proven by those same
#    checks.
python3 - "$dst" "$EPOCH" <<'PYEOF' || err "timestamp pinning failed"
import sys, struct
path, epoch = sys.argv[1], int(sys.argv[2])
d = bytearray(open(path, 'rb').read())
n = len(d); i = 0; sbcnt = 0; ino_done = False
while True:
    i = d.find(b'\x53\xef', i)          # s_magic (LE-stored EF53), at sb+0x38
    if i < 0: break
    sb = i - 0x38
    i += 1                              # always advance, even on the continue path below
    if sb >= 0 and sb + 0xE8 <= n:
        inodes = struct.unpack_from('<I', d, sb)[0]
        blocks = struct.unpack_from('<I', d, sb+4)[0]
        logbs  = struct.unpack_from('<I', d, sb+0x18)[0]
        if 0 < inodes < (1<<22) and 0 < blocks < (1<<26) and logbs in (0, 1, 2):
            for off in (0x2C, 0x30, 0x40, 0x108):   # s_mtime, s_wtime, s_lastcheck, + time field
                struct.pack_into('<I', d, sb+off, epoch)
            sbcnt += 1
            if ino_done: continue   # backup SBs: timestamps only; the inode table belongs to the main SB
            bs = 1024 << logbs
            found = None
            for cand in (1536, 1*bs, 2*bs):         # GDT candidates (never inside the superblock)
                if 1024 <= cand < 1024 + 512: continue
                if cand + 0x0C > n: continue
                v = struct.unpack_from('<I', d, cand + 0x08)[0]   # bg_inode_table_lo
                for ino_size in (128, 256):
                    if not (0 < v and v*bs + inodes*ino_size <= n): continue
                    base1 = v*bs              # slot 1 (bad_ino): mode must be 0
                    base2 = v*bs + ino_size   # slot 2 (root dir): mode must be 40755
                    if base2 + 2 > n: continue
                    m1 = struct.unpack_from('<H', d, base1)[0]
                    m2 = struct.unpack_from('<H', d, base2)[0]
                    if m1 == 0 and m2 == 0o40755:
                        found = (v, ino_size); break
                if found: break
            if not found: sys.exit(f"cannot locate inode table (GDT) in {path}")
            ict, ino_size = found
            offs = (0x08, 0x0C, 0x10, 0x14) + ((0x90,) if ino_size > 0x93 else ())
            for slot in range(inodes):
                base = ict*bs + slot*ino_size
                if base + ino_size > n: break
                for off in offs:             # atime, ctime, mtime, dtime (+ extra-region time)
                    v = struct.unpack_from('<I', d, base+off)[0]
                    if v != epoch: struct.pack_into('<I', d, base+off, epoch)
            ino_done = True
if sbcnt == 0: sys.exit("no superblocks found")
open(path, 'wb').write(bytes(d))
print(f"  pinned timestamps to {epoch} in {sbcnt} superblock instance(s)")
PYEOF

# 6. Verify the result before accepting it (checksums, structure). -n = no
#    changes. If a future mke2fs re-enables metadata_csum despite ^metadata_csum,
#    or any pin above desyncs a checksum, this fails the build loudly instead
#    of shipping an image that only breaks on-device.
e2fsck -fn "$dst" >/dev/null 2>&1 || err "e2fsck rejected $dst after determinism pins"

echo "mkfs-ext4-deterministic: $dst done ($(stat -c%s "$dst") bytes)"
