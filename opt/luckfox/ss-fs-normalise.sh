#!/usr/bin/env bash
#
# ss-fs-normalise.sh mtimes   <DIR>  <EPOCH>
# ss-fs-normalise.sh sqfs-time <FILE> <EPOCH>
# ss-fs-normalise.sh ubifs    <FILE>
# ss-fs-normalise.sh bootimg  <FILE> [EPOCH]
#
# The operations the SDK's bundled filesystem tools cannot do themselves.
# patch-fs-determinism.sh injects calls to this script into the fakeroot
# scripts that mkfs_ubi.sh generates -- around mksquashfs and after
# mkfs.ubifs. It exists as a real file rather than as text echoed into those
# scripts because the fixes need binary handling, and threading escapes through
# awk inside sh inside a generated script mangles them.
#
#   mtimes     set every mtime under DIR to EPOCH (the -all-time equivalent;
#              the bundled mksquashfs 4.3-git predates -all-time/-mkfs-time).
#              Matters more than it sounds: the squashfs payload is
#              xz-compressed, so varying mtimes perturb the whole compressed
#              stream rather than a few inode bytes.
#
#   sqfs-time  overwrite the squashfs superblock's mkfs_time, a little-endian
#              u32 at offset 8 (magic 0-3, inodes 4-7, mkfs_time 8-11). The
#              magic is checked first so a wrong path cannot silently corrupt
#              something else. Nothing checksums this field.
#
#   ubifs      pin the two non-deterministic fields mkfs.ubifs bakes into an
#              image, then repair each affected node's CRC:
#                - the superblock node (type 6) carries a RANDOM uuid[16]
#                  (uuid_generate_random() in write_super()); zero it;
#                - every inode node (type 0) stores atime_sec/ctime_sec/
#                  mtime_sec straight from stat(); ctime cannot be normalised
#                  with touch, so zero all three (nsec fields are already 0).
#              Node CRCs are mtd_crc32(0xFFFFFFFF, node+8..end) -- standard
#              table-driven CRC-32 without the final XOR, i.e.
#              zlib.crc32(buf) ^ 0xFFFFFFFF -- recomputed after each edit so
#              the kernel's on-mount verification still passes. The image is
#              walked node by node (magic + length + type + CRC validated),
#              which also catches nodes that do not start at a min_io-aligned
#              offset, as this mtd-utils fork places some of them.
#
#   bootimg    pin the releaseTime field of a Rockchip rk_boot_header image --
#              download.bin (tag "LDR ", packed by rkbin/tools/boot_merger) and
#              update.img (tag "RKFW", packed by Linux_Pack_Firmware/rkImageMaker).
#              Both tools stamp localtime(time(NULL)) into the header at build
#              time, so two builds of identical source differ in exactly those
#              bytes plus the trailer checksum that covers them:
#                - releaseTime is a packed rk_time (year u16 LE, month, day,
#                  hour, minute, second) at header offset 14..20; set it to EPOCH.
#                - download.bin's last 4 bytes are CRC-32 over the rest of the
#                  file -- table-driven, init 0, no final XOR, polynomial
#                  0x04C10DB7 (boot_merger.c's gTable_Crc32; NOT the standard
#                  0x04C11DB7) -- recomputed after the edit.
#                - update.img's last 32 bytes are the ASCII lowercase hex MD5 of
#                  everything before them ("Generating MD5 data..."); recomputed.
#              The magic is checked first so a wrong path cannot silently
#              corrupt something else.

set -eu

MODE="${1:-}"
TARGET="${2:-}"
EPOCH="${3:-0}"

if [ -z "$MODE" ] || [ -z "$TARGET" ]; then
    echo "usage: ss-fs-normalise.sh <mtimes|sqfs-time|ubifs|bootimg> <path> [epoch]" >&2
    exit 1
fi

case "$MODE" in

mtimes)
    if [ ! -d "$TARGET" ]; then
        echo "ss-fs-normalise: '$TARGET' is not a directory -- skipping mtime pin" >&2
        exit 0
    fi
    # -h so symlinks get their own timestamp set rather than their target's.
    find "$TARGET" -exec touch -h -d "@$EPOCH" {} + 2>/dev/null || true
    echo "ss-fs-normalise: mtimes under $TARGET pinned to $EPOCH"
    ;;

sqfs-time)
    if [ ! -f "$TARGET" ]; then
        echo "ss-fs-normalise: '$TARGET' not found -- skipping mkfs_time pin" >&2
        exit 0
    fi

    magic="$(head -c 4 "$TARGET" | od -An -tx1 | tr -d ' \n')"
    if [ "$magic" != "68737173" ]; then   # 'hsqs' little-endian squashfs magic
        echo "ss-fs-normalise: $TARGET is not squashfs (magic $magic) -- skipping" >&2
        exit 0
    fi

    b0=$(( EPOCH & 255 ))
    b1=$(( (EPOCH >> 8) & 255 ))
    b2=$(( (EPOCH >> 16) & 255 ))
    b3=$(( (EPOCH >> 24) & 255 ))
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' "$b0" "$b1" "$b2" "$b3")" \
        | dd of="$TARGET" bs=1 seek=8 count=4 conv=notrunc status=none
    echo "ss-fs-normalise: $TARGET mkfs_time set to $EPOCH"
    ;;

ubifs)
    if [ ! -f "$TARGET" ]; then
        echo "ss-fs-normalise: '$TARGET' not found -- skipping ubifs pin" >&2
        exit 0
    fi

    magic="$(head -c 4 "$TARGET" | od -An -tx1 | tr -d ' \n')"
    if [ "$magic" != "31181006" ]; then   # LE-encoded UBIFS node magic 0x06101831
        echo "ss-fs-normalise: $TARGET is not a ubifs volume (magic $magic) -- skipping" >&2
        exit 0
    fi

    python3 - "$TARGET" "$EPOCH" <<'PYEOF'
import struct, sys, zlib

MAGIC_B = b"\x31\x18\x10\x06"   # LE(0x06101831)
INO_NODE, SB_NODE = 0, 6

def mtd_crc32(buf):
    return (zlib.crc32(buf) & 0xFFFFFFFF) ^ 0xFFFFFFFF

path = sys.argv[1]
epoch = int(sys.argv[2]) if len(sys.argv) > 2 else 0
data = bytearray(open(path, "rb").read())
leb_size = struct.unpack_from("<I", data, 36)[0]
times = struct.pack("<QQQ", epoch, epoch, epoch)

def try_node(pos):
    if pos + 24 > len(data) or data[pos:pos+4] != MAGIC_B:
        return None
    l, = struct.unpack_from("<I", data, pos + 16)
    t = data[pos + 20]
    if not (24 <= l <= leb_size) or t > 11:
        return None
    if mtd_crc32(bytes(data[pos+8:pos+l])) != struct.unpack_from("<I", data, pos + 4)[0]:
        return None
    return l, t

fixed_sb = fixed_ino = 0
for lnum in range(len(data) // leb_size):
    off = lnum * leb_size
    end = off + leb_size
    pos = off
    while pos < end:
        r = try_node(pos)
        if r is None:
            nxt = data.find(MAGIC_B, pos + 1, end - 23)
            if nxt == -1:
                break
            pos = nxt
            continue
        l, t = r
        if t == SB_NODE:
            # uuid[16] sits at node offset 108..123 (after time_gran).
            data[pos+108:pos+124] = b"\x00" * 16
            fixed_sb += 1
        elif t == INO_NODE:
            # atime_sec/ctime_sec/mtime_sec, three LE u64s at node offset 56.
            data[pos+56:pos+80] = times
            fixed_ino += 1
        if t in (SB_NODE, INO_NODE):
            struct.pack_into("<I", data, pos + 4, mtd_crc32(bytes(data[pos+8:pos+l])))
        pos += l

open(path, "wb").write(data)
print("ss-fs-normalise: %s: pinned uuid in %d superblock node(s), set times to %d in %d inode node(s)"
      % (path, fixed_sb, epoch, fixed_ino))
PYEOF
    ;;

bootimg)
    if [ ! -f "$TARGET" ]; then
        echo "ss-fs-normalise: '$TARGET' not found -- skipping boot image pin" >&2
        exit 0
    fi

    magic="$(head -c 4 "$TARGET" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
        4c445220) ;;   # "LDR " -- download.bin (boot_merger)
        524b4657) ;;   # "RKFW" -- update.img (rkImageMaker)
        *)
            echo "ss-fs-normalise: $TARGET is not an rk_boot_header image (magic $magic) -- skipping" >&2
            exit 0
            ;;
    esac

    python3 - "$TARGET" "$EPOCH" <<'PYEOF'
import datetime, hashlib, struct, sys

# rk_boot_header (boot_merger.h, #pragma pack(1)): tag[4], size u16 @4,
# version u32 @6, mergerVersion u32 @10, releaseTime @14..20 (rk_time:
# year u16 LE, month, day, hour, minute, second), chipType u32 @21.
RELEASE_TIME_OFF = 14

def rk_crc32(data):
    # boot_merger.c CRC_32(): MSB-first table-driven, init 0, no final XOR,
    # polynomial 0x04C10DB7 (its gTable_Crc32; the standard 0x04C11DB7 does
    # NOT match -- verified against both a real download.bin and the source).
    table = []
    for i in range(256):
        crc = i << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C10DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
        table.append(crc)
    acc = 0
    for b in data:
        acc = ((acc << 8) & 0xFFFFFFFF) ^ table[((acc >> 24) ^ b) & 0xFF]
    return acc

path = sys.argv[1]
epoch = int(sys.argv[2]) if len(sys.argv) > 2 else 0
data = bytearray(open(path, "rb").read())
tag = bytes(data[:4])

# datetime, not time.gmtime: this image's Python build returns ABSOLUTE years
# in struct_time.tm_year (gmtime(0).tm_year == 1970, not 70), which would make
# tm_year + 1900 write year 3870 into the header. datetime is unaffected.
dt = datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc)
struct.pack_into("<HBBBBB", data, RELEASE_TIME_OFF,
                 dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)

if tag == b"LDR ":
    if len(data) < 8:
        sys.exit("ss-fs-normalise: %s too small to be an LDR image" % path)
    crc = rk_crc32(bytes(data[:-4]))
    struct.pack_into("<I", data, len(data) - 4, crc)
    trailer = "crc32(0x%08x)" % crc
elif tag == b"RKFW":
    if len(data) < 40:
        sys.exit("ss-fs-normalise: %s too small to be an RKFW image" % path)
    md5 = hashlib.md5(bytes(data[:-32])).hexdigest()
    data[-32:] = md5.encode("ascii")
    trailer = "md5(%s)" % md5

open(path, "wb").write(data)
print("ss-fs-normalise: %s (%s): releaseTime set to epoch %d, recomputed %s"
      % (path, tag.decode(), epoch, trailer))
PYEOF
    ;;

*)
    echo "ss-fs-normalise: unknown mode '$MODE'" >&2
    exit 1
    ;;
esac
