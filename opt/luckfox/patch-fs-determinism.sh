#!/usr/bin/env bash
#
# patch-fs-determinism.sh <LUCKFOX_PICO_DIR>
#
# Make the SDK's filesystem-image tools deterministic. Run AFTER the SDK is
# checked out and BEFORE `build.sh rootfs` (the pctools step copies these
# scripts from sysdrv/tools/pc into sysdrv/out/pc, so they must be patched at
# the source).
#
# Two builds of identical source produced different images. Comparing them byte
# by byte gave two causes in these tools:
#
# 1. ubinize picks a RANDOM image_seq when not given -Q. It lands in the UBI
#    erase-counter header at bytes 24-27 of every erase block, and the header
#    CRC at 60-63 follows it. That alone was the entire difference in two
#    images -- userdata.img differed in 153 bytes of 1.97 MB and oem.img in
#    2755 of 11.7 MB, pure header noise over byte-identical payloads.
#
# 2. mksquashfs recorded the filesystem creation time and every file mtime.
#    The payload is xz-compressed, so that metadata perturbs the whole
#    compressed stream: rootfs.img differed in 88.57% of its bytes even though
#    only two of its 3121 files differed in content.
#
# Both are pinned to SOURCE_DATE_EPOCH, matching the rest of the build.
#
# For (2) the modern fix is mksquashfs -all-time/-mkfs-time, but those arrived
# in squashfs-tools 4.4 and the SDK bundles 4.3-git (2014). So the flags are
# PROBED, and when absent the wrapper is patched to do the same work by hand:
# normalise source mtimes before packing, and overwrite the superblock's
# mkfs_time afterwards.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "usage: patch-fs-determinism.sh <LUCKFOX_PICO_DIR>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPOCH="${SOURCE_DATE_EPOCH:-0}"
UBI_TOOL="$LUCKFOX_DIR/sysdrv/tools/pc/mtd-utils/mkfs_ubi.sh"
SQUASH_TOOL="$LUCKFOX_DIR/sysdrv/tools/pc/mksquashfs/mkfs_squashfs.sh"
MKSQUASHFS_BIN="$LUCKFOX_DIR/sysdrv/tools/pc/mksquashfs/mksquashfs"

# --- 1. ubinize: pin image_seq -------------------------------------------
if [ ! -f "$UBI_TOOL" ]; then
    echo "patch-fs-determinism: $UBI_TOOL not found" >&2
    exit 1
fi

if grep -q 'MKUBINIZE_TOOL -Q' "$UBI_TOOL"; then
    echo "  ubinize already pinned (idempotent re-run)"
else
    # The invocation is echoed into a fakeroot script, so patch the echoed
    # command rather than a direct call.
    sed -i "s|\$MKUBINIZE_TOOL -o |\$MKUBINIZE_TOOL -Q $EPOCH -o |g" "$UBI_TOOL"
    if ! grep -q 'MKUBINIZE_TOOL -Q' "$UBI_TOOL"; then
        echo "patch-fs-determinism: failed to add -Q to the ubinize call in $UBI_TOOL" >&2
        grep -n 'MKUBINIZE_TOOL' "$UBI_TOOL" >&2 || true
        exit 1
    fi
    echo "  ubinize: image_seq pinned to $EPOCH"
fi

# --- 2. mksquashfs: pin filesystem and file times -------------------------
if [ ! -f "$SQUASH_TOOL" ]; then
    echo "patch-fs-determinism: $SQUASH_TOOL not found" >&2
    exit 1
fi

if grep -q 'SS_DETERMINISM' "$SQUASH_TOOL"; then
    echo "  mksquashfs already pinned (idempotent re-run)"
else
    SQUASH_FLAGS=""
    if [ -x "$MKSQUASHFS_BIN" ]; then
        # -help exits non-zero on some builds; capture both streams regardless.
        HELP="$("$MKSQUASHFS_BIN" -help 2>&1 || true)"
        case "$HELP" in *-mkfs-time*) SQUASH_FLAGS="$SQUASH_FLAGS -mkfs-time $EPOCH" ;; esac
        case "$HELP" in *-all-time*)  SQUASH_FLAGS="$SQUASH_FLAGS -all-time $EPOCH" ;; esac
    fi

    if [ -n "$SQUASH_FLAGS" ]; then
        # squashfs-tools >= 4.4: let the tool do it.
        sed -i "s|-comp \$squashfs_compression_args -Xhc|-comp \$squashfs_compression_args$SQUASH_FLAGS -Xhc|g" "$SQUASH_TOOL"
        sed -i "s|-comp \$squashfs_compression_args\"|-comp \$squashfs_compression_args$SQUASH_FLAGS\"|g" "$SQUASH_TOOL"
        sed -i "s|-comp \$squashfs_compression_args\$|-comp \$squashfs_compression_args$SQUASH_FLAGS|g" "$SQUASH_TOOL"
        echo "# SS_DETERMINISM: times pinned via mksquashfs flags" >> "$SQUASH_TOOL"
        echo "  mksquashfs: times pinned ($SQUASH_FLAGS)"
    else
        # squashfs-tools 4.3 (what the SDK ships): do the same work by hand.
        #
        # Normalise mtimes before packing -- the -all-time equivalent. Inserted
        # before `rm -f $dst`, which is the last line before the tool runs.
        awk -v epoch="$EPOCH" '
            /^rm -f \$dst$/ && !done {
                print "# SS_DETERMINISM: pin every source mtime before packing."
                print "# The bundled mksquashfs predates -all-time; this is the equivalent."
                print "find \"$src\" -exec touch -h -d \"@" epoch "\" {} + 2>/dev/null || true"
                print ""
                done = 1
            }
            { print }
        ' "$SQUASH_TOOL" > "$SQUASH_TOOL.tmp" && mv "$SQUASH_TOOL.tmp" "$SQUASH_TOOL"
        chmod +x "$SQUASH_TOOL"

        if ! grep -q 'SS_DETERMINISM: pin every source mtime' "$SQUASH_TOOL"; then
            echo "patch-fs-determinism: failed to insert mtime normalisation into $SQUASH_TOOL" >&2
            exit 1
        fi

        # Overwrite the superblock mkfs_time -- the -mkfs-time equivalent. It is
        # a little-endian u32 at offset 8 (magic 0-3, inodes 4-7, mkfs_time
        # 8-11); nothing checksums it.
        {
            echo ''
            echo '# SS_DETERMINISM: overwrite the squashfs superblock mkfs_time (LE u32 at'
            echo '# offset 8). Equivalent to -mkfs-time, which this mksquashfs lacks.'
            echo "ss_epoch=$EPOCH"
            echo 'printf "$(printf "\\\\x%02x\\\\x%02x\\\\x%02x\\\\x%02x" \'
            echo '    $(( ss_epoch & 255 )) $(( (ss_epoch >> 8) & 255 )) \'
            echo '    $(( (ss_epoch >> 16) & 255 )) $(( (ss_epoch >> 24) & 255 )))" \'
            echo '    | dd of="$dst" bs=1 seek=8 count=4 conv=notrunc status=none \'
            echo '    || echo "warning: could not pin squashfs mkfs_time"'
        } >> "$SQUASH_TOOL"

        echo "  mksquashfs is 4.3 (no time flags): wrapper patched instead"
        echo "    - source mtimes normalised to $EPOCH before packing"
        echo "    - superblock mkfs_time overwritten to $EPOCH after packing"
    fi
fi

# --- 3. mkfs_ubi.sh's OWN mksquashfs call --------------------------------
#
# THIS is the one that builds rootfs.img on a readonly_rootfs SPI_NAND image.
# mkfs_ubi.sh does not call mkfs_squashfs.sh -- for a squashfs-on-UBI volume it
# has its own mksquashfs invocation, echoed into a fakeroot script. Patching
# mkfs_squashfs.sh alone left rootfs.img differing in 88% of its bytes while the
# UBI headers were already pinned, because that file only serves the plain
# squashfs rootfs type, which this build does not use.
#
# The work is delegated to ss-fs-normalise.sh rather than echoed inline: the
# superblock write needs binary escapes, and threading those through awk into a
# generated script turns them into literal NUL bytes and corrupts the file.
HELPER="$SCRIPT_DIR/ss-fs-normalise.sh"
if [ ! -f "$HELPER" ]; then
    echo "patch-fs-determinism: helper not found at $HELPER" >&2
    exit 1
fi

if grep -q 'SS_DETERMINISM' "$UBI_TOOL"; then
    echo "  mkfs_ubi.sh squashfs call already pinned (idempotent re-run)"
else
    awk -v epoch="$EPOCH" -v helper="$HELPER" '
        # Before the mksquashfs call: pin the source mtimes.
        /if \[ "\$squashfs_compression_args" = "lz4" \]; then/ && !pre {
            print "			# SS_DETERMINISM: pin source mtimes (bundled mksquashfs is 4.3,"
            print "			# which has no -all-time)."
            print "			echo \"" helper " mtimes $UBI_SRC_DIR " epoch "\" >> $UBI_IMAGE_FAKEROOT"
            pre = 1
        }
        { print }
        # After it: pin the resulting squashfs superblock mkfs_time.
        /^[[:space:]]*fi[[:space:]]*$/ && pre && !post {
            print "			# SS_DETERMINISM: pin the squashfs superblock mkfs_time."
            print "			echo \"" helper " sqfs-time $temp_image " epoch "\" >> $UBI_IMAGE_FAKEROOT"
            post = 1
        }
    ' "$UBI_TOOL" > "$UBI_TOOL.tmp" && mv "$UBI_TOOL.tmp" "$UBI_TOOL"
    chmod +x "$UBI_TOOL"

    # Two marker comments are injected: one before mksquashfs, one after.
    if [ "$(grep -c 'SS_DETERMINISM' "$UBI_TOOL")" -lt 2 ]; then
        echo "patch-fs-determinism: failed to patch the mksquashfs call inside $UBI_TOOL" >&2
        exit 1
    fi
    echo "  mkfs_ubi.sh: squashfs mtimes + superblock mkfs_time pinned to $EPOCH"
fi

# --- 4. Force single-threaded mksquashfs and disable fragments --------------
#
# The mtime/superblock-time fixes above were not enough: rootfs.img was still
# byte-different between two builds even with EVERY file hashing identical,
# the squashfs metadata (inode count, fragment count, id/xattr counts)
# identical, and the full name/size/permission listing in the same order --
# only the compressed bytes differed, by megabytes, plus a few bytes of total
# size.
#
# Two independent non-determinisms in this mksquashfs (4.3-git 2014) were
# found by re-running it directly against a surviving copy of the packed
# source tree:
#
# (a) Multi-threaded compression (-processors N>1): reproduced with random
#     input, outputs differed in megabytes; -processors 1 settled that part.
#     (Note: that reproduction used urandom files, which are stored raw and
#     never reach xz -- it proved nothing about single-threaded xz itself.)
#
# (b) Fragment packing: even with -processors 1, two runs on the identical
#     tree still differed in ~5 MB of bytes and by a few bytes of total size,
#     while every extracted file hashed identically. Isolated with a small
#     controlled input: default flags DIFFER, -no-fragments IDENTICAL,
#     -no-duplicates alone still DIFFERS -- the non-determinism is in how
#     fragment blocks are built and compressed (the 4.3-git fragment buffer
#     carries uninitialised tail bytes into the xz stream; only the used
#     length is recorded, so extracted content stays correct while the
#     compressed bytes vary run to run). A modern mksquashfs (tested 4.5)
#     packs fragments deterministically, but -no-fragments avoids swapping
#     binaries: each partial block becomes its own data block instead of
#     sharing a fragment block. Cost on this rootfs: ~1.7 MB for 349
#     fragments, against a 93 MB partition -- acceptable.
#
# `-processors N` appears twice per file (the lz4 branch and the default
# branch) in both mkfs_squashfs.sh and mkfs_ubi.sh's embedded squashfs call.
# The value being replaced ($parallel_jobs) is a shell variable in a plain
# script, not text destined for a further-nested Makefile or fakeroot layer,
# so a direct literal substitution is enough -- no $$-escaping concerns here.
#
# Squashfs packing is a small fraction of total build time next to the kernel
# and Rust builds, so trading multi-core speed for a build that reproduces at
# all is the right side of that trade.
for f in "$SQUASH_TOOL" "$UBI_TOOL"; do
    [ -f "$f" ] || continue
    if grep -q -- '-processors 1 -no-fragments' "$f"; then
        echo "  $(basename "$f"): already forced to -processors 1 -no-fragments (idempotent re-run)"
        continue
    fi
    sed -i 's|-processors \$parallel_jobs|-processors 1 -no-fragments|g' "$f"
    if ! grep -q -- '-processors 1 -no-fragments' "$f"; then
        echo "patch-fs-determinism: failed to force -processors 1 -no-fragments in $f" >&2
        grep -n -- '-processors' "$f" >&2 || true
        exit 1
    fi
    echo "  $(basename "$f"): forced -processors 1 -no-fragments (multi-threaded xz and fragment packing are non-deterministic)"
done

# --- 5. mkfs.ubifs: pin the random uuid and stat() times --------------------
#
# The ubifs volumes (oem, userdata) were still byte-different between two
# builds after all of the above. Extracting them and walking every node with a
# CRC-verified parser showed ALL differing bytes fall in exactly two places:
#
#   - the superblock node carries a RANDOM uuid[16] -- write_super() calls
#     uuid_generate_random(). It lands at node offset 108..123 and perturbs
#     that node's CRC (offsets 4-7).
#   - every inode node stores atime_sec/ctime_sec/mtime_sec straight from
#     stat() of the source tree. ctime cannot be normalised with touch, so a
#     pre-pack mtime pass is not enough; the fields are pinned in the image
#     itself instead (node offset 56..79), again perturbing each node's CRC.
#
# Everything else -- sqnums, LEB allocation, index layout, lzo-compressed data
# nodes -- was verified byte-stable by re-running mkfs.ubifs twice on a
# surviving source tree (only the uuid and its CRC differed).
#
# The fix runs ss-fs-normalise.sh ubifs over each volume right after
# mkfs.ubifs produces it: zero the uuid, set the three time fields to EPOCH,
# recompute mtd_crc32 for every touched node so on-mount verification passes.
if grep -q 'SS_UBIFS_NORMALISE' "$UBI_TOOL"; then
    echo "  mkfs_ubi.sh ubifs call already pinned (idempotent re-run)"
else
    awk -v epoch="$EPOCH" '
        { print }
        /echo "\$MKUBIFS_TOOL -x / && !post {
            print "			# SS_UBIFS_NORMALISE: pin the random uuid and stat() times"
            print "			# mkfs.ubifs bakes into the image (see ss-fs-normalise.sh ubifs)."
            print "			echo \"/build/ss-fs-normalise.sh ubifs $temp_image " epoch "\" >> $UBI_IMAGE_FAKEROOT"
            post = 1
        }
    ' "$UBI_TOOL" > "$UBI_TOOL.tmp" && mv "$UBI_TOOL.tmp" "$UBI_TOOL"
    chmod +x "$UBI_TOOL"

    if ! grep -q 'SS_UBIFS_NORMALISE' "$UBI_TOOL"; then
        echo "patch-fs-determinism: failed to patch the mkfs.ubifs call inside $UBI_TOOL" >&2
        exit 1
    fi
    echo "  mkfs_ubi.sh: ubifs uuid + inode times pinned to $EPOCH (CRCs repaired)"
fi

echo "patch-fs-determinism: done (SOURCE_DATE_EPOCH=$EPOCH)"
