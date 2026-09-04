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
# Hard links: the first name of each group (in sorted order) carries the data
# via 'write'; later names become real links with debugfs 'ln' -- duplicating
# them instead would multiply their blocks: git alone ships ~143 hard-linked
# binaries in a dev oem and would overflow the slot. Two quirks of this
# debugfs (e2fsprogs 1.46.x) need handling:
#   * 'ln' cannot extend a directory ("No free space in the directory"), so
#     every directory that will receive links is pre-sized first: write enough
#     throwaway entries to grow it to its final size, then remove them (ext4
#     never shrinks directories on unlink). The freed slots are reused by the
#     real entries; allocation order stays deterministic.
#   * 'ln' does not bump i_links_count on the linked inode, so the final pass
#     sets each group's primary to its true link count (e2fsck would otherwise
#     reject the image: "ref count is N, should be M"). Inode numbers are
#     resolved with debugfs itself (path -> "Inode: N"), independent of any
#     assumption about allocation order.
#   * 'rm' does not clear i_mode on a freed inode, so leftover pre-size slots
#     look like deleted files and e2fsck -f rejects them ("Deleted inode N has
#     zero dtime"). The final pass restores every such slot (mode != 0 but
#     links == 0) to the all-zero state mke2fs gives free inodes.
#
# Verified byte-identical across repeated builds (4K-block trees, 1K-block
# trees with 128-byte inodes, empty source dirs, and hard-link groups), with
# e2fsck clean.

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
dummyfile="$(mktemp)" || err "mktemp failed"
printf 'x' > "$dummyfile"
trap 'rm -f "$cmds" "$cmds.raw" "$dummyfile"' EXIT

( cd "$src" && find . -mindepth 1 -printf '%y %n %p\n' | LC_ALL=C sort -k3 ) > "$cmds.raw" \
    || err "find failed in $src"

# Pass 1: census. Per-directory entry counts and max name length (needed to
# pre-size link-receiving directories), plus the hard-link groups themselves
# (dev:ino -> first path, size). Every name is validated here so pass 2 can
# assume well-formed input.
declare -A dir_total=() dir_maxlen=() dir_ln=() hl_first=() hl_size=() hl_key_of=()
hl_order=()
while read -r type links path; do
    [ -n "$path" ] || continue
    case "$type" in d|f|l) : ;; *) err "malformed find record (bad type): $path" ;; esac
    case "$links" in (*[!0-9]*|'') err "malformed find record (bad nlink): $path" ;; esac
    case "$type$path" in (*[[:space:]]*) err "unsupported filename (whitespace): $path" ;; esac
    p="${path#./}"
    parent="$(dirname -- "$p")"
    name="${p##*/}"
    dir_total[$parent]=$(( ${dir_total[$parent]:-0} + 1 ))
    if [ "${#name}" -gt "${dir_maxlen[$parent]:-0}" ]; then dir_maxlen[$parent]="${#name}"; fi
    case "$type" in
        f)
            if [ "${links:-1}" -gt 1 ]; then
                key="$(stat -c '%d:%i' "$src/$p")" || err "stat failed for $path"
                hl_key_of[$p]="$key"
                if [ -n "${hl_first[$key]:-}" ]; then
                    hl_size[$key]=$(( ${hl_size[$key]} + 1 ))
                    dir_ln[$parent]=$(( ${dir_ln[$parent]:-0} + 1 ))
                else
                    hl_first[$key]="$p"; hl_size[$key]=1; hl_order+=("$key")
                fi
            fi ;;
        *) : ;;
    esac
done < "$cmds.raw"

# pre_size DIR: grow DIR to its final entry count with throwaway files, then
# remove them. ext4 never shrinks a directory on unlink, so the freed slots
# (sized for the longest real name) absorb every later 'write'/'ln' without
# any block allocation -- which is exactly what debugfs 'ln' cannot do itself.
pre_size() {
    local dir="$1" key F M L i w name
    [ -n "$dir" ] && key="$dir" || key="."     # root directory is keyed as "." in the census
    F="${dir_total[$key]}"; M="${dir_maxlen[$key]}"
    w=$(( ${#F} )); [ "$w" -lt 4 ] && w=4
    for i in $(seq 1 "$F"); do
        name="ssd$(printf "%0${w}d" "$i")"
        L=${#name}; [ "$M" -gt "$L" ] && L=$M
        while [ ${#name} -lt "$L" ]; do name="${name}x"; done
        if [ -n "$dir" ]; then echo "write $dummyfile /$dir/$name" >> "$cmds"
        else                    echo "write $dummyfile /$name"     >> "$cmds"; fi
    done
    for i in $(seq 1 "$F"); do
        name="ssd$(printf "%0${w}d" "$i")"
        L=${#name}; [ "$M" -gt "$L" ] && L=$M
        while [ ${#name} -lt "$L" ]; do name="${name}x"; done
        if [ -n "$dir" ]; then echo "rm /$dir/$name" >> "$cmds"
        else                    echo "rm /$name"     >> "$cmds"; fi
    done
}

# Pass 2: emit the debugfs commands in sorted order. A directory that will
# receive hard links is pre-sized immediately after its mkdir (the root
# directory, which has no mkdir of its own, at the very start).
: > "$cmds"
[ "${dir_ln["."]:-0}" -gt 0 ] && pre_size ""
while read -r type links path; do
    [ -n "$path" ] || continue
    p="${path#./}"
    case "$type" in
        d)
            echo "mkdir /$p" >> "$cmds"
            if [ "${dir_ln[$p]:-0}" -gt 0 ]; then pre_size "$p"; fi ;;
        f)
            key="${hl_key_of[$p]:-}"
            if [ -n "$key" ] && [ "${hl_first[$key]}" != "$p" ]; then
                # Hard link: first name of the group carries the data, later
                # names become real links to it (same inode, no extra blocks).
                echo "ln /${hl_first[$key]} /$p" >> "$cmds"
            else
                echo "write $src/$p /$p" >> "$cmds"
            fi ;;
        l) tgt="$(readlink "$src/$p")"; echo "symlink /$p $tgt" >> "$cmds" ;;
        *) err "unsupported entry type '$type' at $path (special files are not handled)" ;;
    esac
done < "$cmds.raw"

if [ -s "$cmds" ]; then
    # 'ln' only exists in newer debugfs; fail loudly (not silently drop link
    # names) if this one lacks it and the tree actually needs links.
    if grep -q '^ln ' "$cmds"; then
        debugfs -R "help" "$dst" 2>/dev/null | grep -qw ln \
            || err "debugfs has no 'ln' command -- cannot recreate hard links deterministically"
    fi
    debugfs -w -f "$cmds" "$dst" >/dev/null 2>&1 || err "debugfs populate failed for $dst"

    # Verify the populated image against the source manifest: every entry must
    # exist with the right name, and regular files with the right size. This is
    # mandatory, not belt-and-braces: debugfs -f swallows per-command failures
    # (a space-starved 'write' allocates nothing, prints no error, and the
    # session still exits 0), so without this check a build that ran out of
    # blocks would ship an image silently missing files. One read-only session
    # lists every directory; '.'/'..' and mke2fs's own lost+found are ignored.
    vfile="$(mktemp)" || err "mktemp failed"
    { echo "ls -l /"
      while read -r type links path; do
          [ -n "$path" ] || continue
          if [ "$type" = d ]; then p="${path#./}"; [ -n "$p" ] && echo "ls -l /$p"; fi
      done < "$cmds.raw"
    } > "$vfile"
    vout="$(mktemp)" || err "mktemp failed"
    debugfs -f "$vfile" "$dst" > "$vout" 2>/dev/null || true   # exit code is useless; the output is parsed below
    python3 - "$src" "$cmds.raw" "$vout" <<'PYEOF' || err "populate verification failed: image does not match source tree (ran out of space?)"
import sys, os
src, raw_path, vout_path = sys.argv[1], sys.argv[2], sys.argv[3]

# expected: dirpath ("/usr/bin", root is "/") -> {name: (type, size-or-None)}
expected = {}
with open(raw_path) as f:
    for line in f:
        parts = line.rstrip('\n').split(' ', 2)
        if len(parts) < 3: continue
        t, _links, path = parts
        p = path[2:] if path.startswith('./') else path
        if t == 'd':                             # register the dir itself (catches failed mkdir of empty dirs)
            expected.setdefault('/' + p, {})
        parent, name = os.path.split(p)          # 'git001' -> ('', 'git001'): top level lives in '/'
        key = '/' + parent if parent else '/'
        size = None
        if t in ('f', 'l'):                      # regular files and symlinks have a comparable size
            try: size = os.lstat(os.path.join(src, p)).st_size
            except OSError as e: sys.exit(f"cannot stat source entry {p}: {e}")
        expected.setdefault(key, {})[name] = (t, size)

# actual: each listing section starts with debugfs's own "debugfs: ls -l <dir>"
# echo line, so sections are self-describing and order-independent.
actual = {}
cur_dir = None
with open(vout_path) as f:
    for line in f:
        s = line.rstrip('\n')
        if s.startswith('debugfs: '):
            cur_dir = s[len('debugfs: ls -l '):].strip() if s.startswith('debugfs: ls -l ') else None
            continue
        parts = s.split()
        # "INO MODE (LINKS) UID GID SIZE DATE TIME NAME..."
        if cur_dir is not None and len(parts) >= 9 and parts[0].isdigit() and parts[2].startswith('('):
            actual.setdefault(cur_dir, {})[' '.join(parts[8:])] = (parts[1], int(parts[5]))

for key in sorted(expected):
    if key not in actual:                        # dir never listed -> its mkdir failed
        sys.exit(f"directory {key} missing from image listing")
    got = {n: v for n, v in actual[key].items()
           if n not in ('.', '..') and not (key == '/' and n == 'lost+found')}   # mke2fs artifact
    exp = expected[key]
    missing = sorted(set(exp) - set(got))
    extra   = sorted(set(got) - set(exp))
    badsize = [f"{n} (src={exp[n][1]} img={got[n][1]})" for n in sorted(set(exp) & set(got))
               if exp[n][0] in ('f', 'l') and got[n][1] != exp[n][1]]
    if missing or extra or badsize:
        msg = f"directory {key}: "
        if missing: msg += f"missing {missing[:5]}{'...' if len(missing) > 5 else ''} "
        if extra:   msg += f"unexpected {extra[:5]} "
        if badsize: msg += f"wrong size {badsize[:5]}"
        sys.exit(msg)
print(f"  verified {sum(len(v) for v in expected.values())} entries across {len(expected)} directories")
PYEOF
fi

# 3b. Resolve each hard-link group's primary to an inode number (debugfs does
#     the path resolution; no assumption about allocation order). The pairs
#     file feeds the final pinning pass, which sets i_links_count -- debugfs
#     'ln' adds the directory entries but never bumps it.
pairs=""
if [ "${#hl_order[@]}" -gt 0 ]; then
    statcmds="$(mktemp)" || err "mktemp failed"
    for key in "${hl_order[@]}"; do echo "stat /${hl_first[$key]}" >> "$statcmds"; done
    statout="$(debugfs -f "$statcmds" "$dst" 2>/dev/null | awk '/^Inode:/ {print $2}')" \
        || err "debugfs stat failed for hard-link primaries"
    rm -f "$statcmds"
    pairs="$(mktemp)" || err "mktemp failed"
    trap 'rm -f "$cmds" "$cmds.raw" "$dummyfile" "$pairs"' EXIT
    idx=0
    while read -r ino; do
        [ -n "$ino" ] || { rm -f "$pairs"; err "debugfs stat returned no inode for group ${hl_order[$idx]}"; }
        printf '%s\t%s\n' "$ino" "${hl_size[${hl_order[$idx]}]}" >> "$pairs"
        idx=$((idx + 1))
    done <<< "$statout"
    [ "$idx" -eq "${#hl_order[@]}" ] || { rm -f "$pairs"; err "expected ${#hl_order[@]} inode numbers, got $idx"; }
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
#    checks. If hard links were created, i_links_count (inode offset +0x1A) on
#    each group's primary is set to the group's true size here as well --
#    debugfs 'ln' never bumps it, and e2fsck rejects a mismatched refcount.
python3 - "$dst" "$EPOCH" "${pairs:-}" <<'PYEOF' || err "timestamp pinning failed"
import sys, struct
path, epoch = sys.argv[1], int(sys.argv[2])
pairs_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
d = bytearray(open(path, 'rb').read())
n = len(d); i = 0; sbcnt = 0; ino_done = False; table = None
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
            table = (ict, ino_size)
            offs = (0x08, 0x0C, 0x10, 0x14) + ((0x90,) if ino_size > 0x93 else ())
            for slot in range(inodes):
                base = ict*bs + slot*ino_size
                if base + ino_size > n: break
                mode  = struct.unpack_from('<H', d, base)[0]
                links = struct.unpack_from('<H', d, base+0x1A)[0]
                if mode != 0 and links == 0:   # leftover from debugfs 'rm': restore pristine free state
                    d[base:base+ino_size] = b'\x00' * ino_size
                    continue
                for off in offs:             # atime, ctime, mtime, dtime (+ extra-region time)
                    v = struct.unpack_from('<I', d, base+off)[0]
                    if v != epoch: struct.pack_into('<I', d, base+off, epoch)
            ino_done = True
if sbcnt == 0: sys.exit("no superblocks found")
if pairs_path is not None:
    if table is None: sys.exit("cannot fix hard-link refcounts: inode table not located")
    ict, ino_size = table
    fixed = 0
    for line in open(pairs_path):
        line = line.strip()
        if not line: continue
        ino, count = line.split('\t')
        base = ict*bs + (int(ino)-1)*ino_size
        if not (0 < int(ino) and base + 0x1C <= n): sys.exit(f"hard-link inode {ino} out of range")
        struct.pack_into('<H', d, base+0x1A, int(count))   # i_links_count
        fixed += 1
    print(f"  set i_links_count on {fixed} hard-link group(s)")
open(path, 'wb').write(bytes(d))
print(f"  pinned timestamps to {epoch} in {sbcnt} superblock instance(s)")
PYEOF

# 6. Verify the result before accepting it (checksums, structure). -n = no
#    changes. If a future mke2fs re-enables metadata_csum despite ^metadata_csum,
#    or any pin above desyncs a checksum, this fails the build loudly instead
#    of shipping an image that only breaks on-device.
e2fsck -fn "$dst" >/dev/null 2>&1 || err "e2fsck rejected $dst after determinism pins"

echo "mkfs-ext4-deterministic: $dst done ($(stat -c%s "$dst") bytes)"
