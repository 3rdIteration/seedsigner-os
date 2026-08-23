#!/usr/bin/env python3
"""Explain why two SeedSigner OS images are not byte-identical.

Reproducible-build triage: given two .img files that should have been
identical, this narrows the difference from "the SHA-256 doesn't match" down to
individual files inside the image -- and, for ELF binaries, down to the
individual embedded string that differs.

No rebuild and no `--debug-rootfs` rootfs tarball are needed. Everything that
ships on a lafrite device is reachable from the .img alone, because the lafrite
profile sets BR2_TARGET_ROOTFS_INITRAMFS=y + BR2_TARGET_ROOTFS_CPIO_GZIP=y:
there is no separate rootfs filesystem, the whole userland is a gzipped newc
cpio linked into the arm64 kernel `Image`. The image layout is

    MBR (fixed disk-id 0xba5eba11)
    Amlogic bootloader blob at sector 1        (aml-s805x-ac, pinned SHA-256)
    one FAT partition:
        Image                                  kernel + initramfs
        meson-gxl-s805x-libretech-ac.dtb
        diy-tools.squashfs
        extlinux/extlinux.conf
        javacard-cap/

so this script walks the FAT itself, pulls the initramfs back out of the
kernel, and compares every rootfs entry.

The MBR / partition / FAT / squashfs / ELF stages are generic, so it still says
something useful about non-lafrite images -- but only lafrite carries its rootfs
inside the kernel, so the initramfs stage is skipped elsewhere.

Stdlib only; no mtools, binwalk or loopback mount required, and it runs fine on
Windows.

    usage: tools/imgdiff.py A.img B.img

Exit status: 0 if the images are byte-identical, 1 if they differ.

See docs/agents.md ("Verifying reproducibility") for worked examples.
"""

import argparse
import hashlib
import re
import struct
import sys
import zlib
from collections import Counter

# ---------------------------------------------------------------- helpers


def sha(data):
    return hashlib.sha256(data).hexdigest()


def diff_ranges(a, b, limit=None):
    """Coalesce differing byte offsets into (offset, length) runs."""
    out = []
    n = min(len(a), len(b))
    i = 0
    while i < n:
        if a[i] != b[i]:
            j = i
            while j < n and a[j] != b[j]:
                j += 1
            out.append((i, j - i))
            if limit is not None and len(out) >= limit:
                break
            i = j
        else:
            i += 1
    return out


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n if len(a) != len(b) else None


def ascii_preview(data):
    return "".join(chr(c) if 32 <= c < 127 else "." for c in data)


# ---------------------------------------------------------------- MBR / FAT


def parse_mbr(data):
    parts = []
    for k in range(4):
        entry = data[446 + 16 * k:446 + 16 * (k + 1)]
        if entry == b"\0" * 16:
            continue
        lba, sectors = struct.unpack_from("<II", entry, 8)
        parts.append({"idx": k, "boot": entry[0], "type": entry[4],
                      "lba": lba, "sectors": sectors})
    return struct.unpack_from("<I", data, 440)[0], parts


def fat_timestamp(date, time_, tenth=0):
    if date == 0:
        return None
    return "%04d-%02d-%02d %02d:%02d:%02d" % (
        1980 + ((date >> 9) & 0x7F), (date >> 5) & 0xF, date & 0x1F,
        (time_ >> 11) & 0x1F, (time_ >> 5) & 0x3F,
        (time_ & 0x1F) * 2 + tenth // 100)


class Fat:
    """Minimal read-only FAT12/16/32 reader over a byte string."""

    def __init__(self, data, offset):
        self.d = data
        self.off = offset
        bpb = data[offset:offset + 512]
        self.bytes_per_sec = struct.unpack_from("<H", bpb, 11)[0]
        self.sec_per_clus = bpb[13]
        self.rsvd = struct.unpack_from("<H", bpb, 14)[0]
        self.num_fats = bpb[16]
        self.root_ents = struct.unpack_from("<H", bpb, 17)[0]
        fatsz16 = struct.unpack_from("<H", bpb, 22)[0]
        self.fatsz = fatsz16 or struct.unpack_from("<I", bpb, 36)[0]
        self.total_sec = (struct.unpack_from("<H", bpb, 19)[0]
                          or struct.unpack_from("<I", bpb, 32)[0])
        self.root_clus = 0 if fatsz16 else struct.unpack_from("<I", bpb, 44)[0]

        if not self.bytes_per_sec or not self.sec_per_clus:
            raise ValueError("not a FAT filesystem at offset %#x" % offset)

        self.root_dir_sectors = ((self.root_ents * 32 + self.bytes_per_sec - 1)
                                 // self.bytes_per_sec)
        self.first_data_sec = (self.rsvd + self.num_fats * self.fatsz
                               + self.root_dir_sectors)
        clusters = (self.total_sec - self.first_data_sec) // self.sec_per_clus
        self.type = 12 if clusters < 4085 else (16 if clusters < 65525 else 32)

        # volume serial and label are classic reproducibility leaks
        base = 67 if self.type == 32 else 39
        self.vol_id = struct.unpack_from("<I", bpb, base)[0]
        self.vol_label = bpb[base + 4:base + 15]

    def _sectors(self, n, count=1):
        start = self.off + n * self.bytes_per_sec
        return self.d[start:start + count * self.bytes_per_sec]

    def _fat_entry(self, clus):
        base = self.off + self.rsvd * self.bytes_per_sec
        if self.type == 16:
            return struct.unpack_from("<H", self.d, base + clus * 2)[0]
        if self.type == 32:
            return struct.unpack_from("<I", self.d, base + clus * 4)[0] & 0x0FFFFFFF
        raw = struct.unpack_from("<H", self.d, base + clus + clus // 2)[0]
        return (raw >> 4) if (clus & 1) else (raw & 0xFFF)

    def _chain(self, clus):
        end = {12: 0xFF8, 16: 0xFFF8, 32: 0x0FFFFFF8}[self.type]
        out, seen = [], set()
        while clus >= 2 and clus < end and clus not in seen:
            seen.add(clus)
            out.append(clus)
            clus = self._fat_entry(clus)
        return out

    def read(self, clus, size=0):
        buf = b"".join(
            self._sectors(self.first_data_sec + (c - 2) * self.sec_per_clus,
                          self.sec_per_clus)
            for c in self._chain(clus))
        return buf[:size] if size else buf

    def _root(self):
        if self.type == 32:
            return self.read(self.root_clus)
        return self._sectors(self.rsvd + self.num_fats * self.fatsz,
                             self.root_dir_sectors)

    def walk(self, raw=None, path="", out=None, depth=0):
        """Return {"/path": {...metadata, sha, _data}} for the whole tree."""
        if out is None:
            out = {}
        if raw is None:
            raw = self._root()
        lfn = []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if len(e) < 32 or e[0] == 0x00:
                break
            if e[0] == 0xE5:                     # deleted
                lfn = []
                continue
            attr = e[11]
            if attr == 0x0F:                     # long-filename fragment
                lfn.append((e[0] & 0x3F,
                            (e[1:11] + e[14:26] + e[28:32])
                            .decode("utf-16-le", "replace")))
                continue
            if attr & 0x08:                      # volume label
                lfn = []
                continue
            short = (e[0:8].decode("ascii", "replace").rstrip() + "."
                     + e[8:11].decode("ascii", "replace").rstrip()).rstrip(".")
            name = ("".join(s for _, s in sorted(lfn)).split("\x00")[0]
                    if lfn else short)
            lfn = []
            if name in (".", ".."):
                continue
            clus = ((struct.unpack_from("<H", e, 20)[0] << 16)
                    | struct.unpack_from("<H", e, 26)[0])
            rec = {
                "dir": bool(attr & 0x10),
                "attr": attr,
                "short": short,
                "size": struct.unpack_from("<I", e, 28)[0],
                "mtime": fat_timestamp(struct.unpack_from("<H", e, 24)[0],
                                       struct.unpack_from("<H", e, 22)[0]),
                "ctime": fat_timestamp(struct.unpack_from("<H", e, 16)[0],
                                       struct.unpack_from("<H", e, 14)[0], e[13]),
                "atime": fat_timestamp(struct.unpack_from("<H", e, 18)[0], 0),
                "order": len(out),
            }
            full = path + "/" + name
            out[full] = rec
            if rec["dir"]:
                if depth < 8 and clus >= 2:
                    self.walk(self.read(clus), full, out, depth + 1)
            else:
                blob = self.read(clus, rec["size"]) if clus >= 2 and rec["size"] else b""
                rec["sha"] = sha(blob)
                rec["_data"] = blob
        return out


# ---------------------------------------------------------------- initramfs


def extract_initramfs(image):
    """Find the gzipped newc cpio linked into an uncompressed arm64 Image.

    Returns (offset, decompressed_cpio, gzip_header, compressed_length) or None.
    Scans for gzip magic and keeps the largest stream that inflates to a cpio.
    """
    best = None
    pos = 0
    while True:
        pos = image.find(b"\x1f\x8b\x08", pos)
        if pos < 0:
            break
        try:
            dec = zlib.decompressobj(31)
            out = dec.decompress(image[pos:])
        except zlib.error:
            pos += 1
            continue
        if out.startswith(b"070701") and (best is None or len(out) > len(best[1])):
            clen = len(image) - pos - len(dec.unused_data)
            best = (pos, out, image[pos:pos + 10], clen)
        pos += 1
    return best


def parse_cpio(buf):
    """Parse a newc cpio archive into {name: metadata}."""
    entries = {}
    view = memoryview(buf)      # slice without copying; the archive is ~180 MB
    i = 0
    while i + 110 <= len(buf):
        if buf[i:i + 6] != b"070701":
            break
        f = [int(buf[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
        (ino, mode, uid, gid, nlink, mtime, size,
         dmaj, dmin, rmaj, rmin, namesize, _chk) = f
        name = buf[i + 110:i + 110 + namesize - 1].decode("utf-8", "replace")
        data_off = (i + 110 + namesize + 3) & ~3
        data = view[data_off:data_off + size]
        i = (data_off + size + 3) & ~3
        if name == "TRAILER!!!":
            break
        entries[name] = {"mode": mode, "uid": uid, "gid": gid, "nlink": nlink,
                         "mtime": mtime, "size": size, "dev": (dmaj, dmin),
                         "rdev": (rmaj, rmin), "sha": sha(data),
                         "order": len(entries), "_data": data}
    return entries


# ---------------------------------------------------------------- reporting


def compare_maps(a, b, label, fields, check_order=True):
    """Diff two {name: metadata} maps. Returns the list of changed names."""
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    common = sorted(set(a) & set(b))
    changed = [(k, {f: (a[k].get(f), b[k].get(f)) for f in fields
                    if a[k].get(f) != b[k].get(f)})
               for k in common]
    changed = [(k, d) for k, d in changed if d]
    reordered = ([(k, a[k]["order"], b[k]["order"]) for k in common
                  if a[k].get("order") != b[k].get("order")]
                 if check_order else [])

    print("\n### %s" % label)
    print("  entries: A=%d B=%d, identical=%d"
          % (len(a), len(b), len(common) - len(changed)))
    for k in only_a:
        print("  ONLY IN A   %s" % k)
    for k in only_b:
        print("  ONLY IN B   %s" % k)
    for k, d in changed:
        print("  DIFFERS     %s" % k)
        for f, (x, y) in d.items():
            print("                %s: %r -> %r" % (f, x, y))
    if reordered:
        print("  archive-order changes: %d" % len(reordered))
        for k, x, y in reordered[:15]:
            print("                %s: #%d -> #%d" % (k, x, y))
    if not (only_a or only_b or changed or reordered):
        print("  -> identical")
    return [k for k, _ in changed]


def report_string_diff(a, b, indent="  "):
    """Diff the printable strings embedded in two binaries.

    This is what usually names the culprit outright: a build path, a hostname,
    a timestamp, a uname. Offsets shift wholesale when one string changes
    length, so comparing the string *multiset* cuts through the noise.
    """
    pattern = rb"[\x20-\x7e]{5,}"
    sa = Counter(re.findall(pattern, a))
    sb = Counter(re.findall(pattern, b))
    only_a, only_b = sa - sb, sb - sa
    if not only_a and not only_b:
        print("%sembedded strings are identical (%d distinct) -- the difference"
              % (indent, len(sa)))
        print("%sis in code, data or layout, not in an embedded string." % indent)
        return
    print("%sembedded strings differ (A=%d distinct, B=%d):"
          % (indent, len(sa), len(sb)))
    for label, counter in (("only in A", only_a), ("only in B", only_b)):
        for s, count in sorted(counter.items())[:40]:
            print("%s  %-9s x%d  %r" % (indent, label, count, s[:200]))


def report_binary_diff(a, b, indent="  ", limit=8):
    for off, ln in diff_ranges(a, b, limit):
        print("%sdiffers at %#x for %d bytes: %s -> %s" % (
            indent, off, ln, a[off:off + min(ln, 16)].hex(),
            b[off:off + min(ln, 16)].hex()))


def drill_into_file(name, da, db):
    """Explain a single differing file as specifically as possible."""
    da, db = bytes(da), bytes(db)   # may arrive as memoryviews from parse_cpio
    print("\n=== %s (%d vs %d bytes) ===" % (name, len(da), len(db)))

    if da[:4] == b"hsqs" and db[:4] == b"hsqs":
        ta = struct.unpack_from("<I", da, 8)[0]
        tb = struct.unpack_from("<I", db, 8)[0]
        note = "" if ta == tb else "   <-- timestamp leak"
        print("  squashfs mkfs_time: %d vs %d%s" % (ta, tb, note))
        report_binary_diff(da, db)
        return

    if name.lstrip("/") == "Image":
        drill_into_kernel(da, db)
        return

    if da[:4] == b"\x7fELF" and db[:4] == b"\x7fELF":
        report_string_diff(da, db)
        return

    report_binary_diff(da, db)


def drill_into_kernel(da, db):
    """Compare an arm64 Image: the kernel itself and the initramfs inside it."""
    ra, rb = extract_initramfs(da), extract_initramfs(db)
    if not ra or not rb:
        print("  no embedded cpio.gz found (not an initramfs kernel?)")
        report_binary_diff(da, db)
        return

    (oa, ca, ga, la), (ob, cb, gb, lb) = ra, rb
    print("  initramfs gzip stream at %#x (A) / %#x (B)" % (oa, ob))
    if ga != gb:
        print("  gzip header differs: %s -> %s   <-- mtime/XFL/OS byte"
              % (ga.hex(), gb.hex()))
    print("  compressed: %d vs %d bytes (delta %+d)" % (la, lb, lb - la))
    print("  decompressed: %d vs %d bytes" % (len(ca), len(cb)))

    ka, kb = da[:oa], db[:ob]
    if ka == kb:
        print("  kernel bytes before the initramfs: identical")
    else:
        runs = diff_ranges(ka, kb)
        total = sum(ln for _, ln in runs)
        print("  kernel bytes before the initramfs: %d runs, %d bytes of %d"
              % (len(runs), total, len(ka)))
        print("  (a changed initramfs size shifts the kernel's post-initramfs")
        print("   layout, which perturbs kallsyms ordering, some load")
        print("   immediates and the GNU build-id -- check the initramfs first)")
        report_string_diff(ka, kb, indent="  ")

    if ca == cb:
        print("  initramfs payload is identical -- the difference is in the kernel")
        return

    ea, eb = parse_cpio(ca), parse_cpio(cb)
    changed = compare_maps(ea, eb, "initramfs (rootfs) contents",
                           ["mode", "uid", "gid", "nlink", "mtime", "size",
                            "sha", "dev", "rdev"])
    for name in changed:
        if ea[name]["sha"] != eb[name]["sha"]:
            drill_into_file(name, ea[name]["_data"], eb[name]["_data"])


# ---------------------------------------------------------------- main


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", metavar="A.img", help="first image (e.g. local build)")
    ap.add_argument("b", metavar="B.img", help="second image (e.g. CI build)")
    args = ap.parse_args(argv)

    with open(args.a, "rb") as fh:
        A = fh.read()
    with open(args.b, "rb") as fh:
        B = fh.read()

    print("A = %s\n    %d bytes, sha256 %s" % (args.a, len(A), sha(A)))
    print("B = %s\n    %d bytes, sha256 %s" % (args.b, len(B), sha(B)))
    if A == B:
        print("\nImages are byte-identical.")
        return 0
    print("\nfirst differing byte offset: %#x" % first_diff(A, B))

    id_a, parts_a = parse_mbr(A)
    id_b, parts_b = parse_mbr(B)
    print("\n### partition table")
    print("  disk-id: %#x vs %#x%s"
          % (id_a, id_b, "" if id_a == id_b else "   <-- DIFFERS"))
    if not parts_a or not parts_b:
        print("  no MBR partitions found; falling back to a raw byte diff")
        report_binary_diff(A, B)
        return 1
    for pa, pb in zip(parts_a, parts_b):
        print("  part%d: type=%#x lba=%d sectors=%d boot=%#x%s"
              % (pa["idx"], pa["type"], pa["lba"], pa["sectors"], pa["boot"],
                 "" if pa == pb else "   <-- DIFFERS (B: %r)" % (pb,)))

    start = parts_a[0]["lba"] * 512
    print("\n### pre-partition region (MBR + bootloader blob)")
    if A[:start] == B[:start]:
        print("  -> identical")
    else:
        report_binary_diff(A[:start], B[:start])

    try:
        fa, fb = Fat(A, start), Fat(B, start)
    except ValueError as exc:
        print("\n### partition: %s -- falling back to a raw byte diff" % exc)
        report_binary_diff(A[start:], B[start:])
        return 1

    print("\n### filesystem geometry")
    for field in ("type", "bytes_per_sec", "sec_per_clus", "rsvd", "num_fats",
                  "fatsz", "total_sec", "root_ents", "vol_id", "vol_label"):
        x, y = getattr(fa, field), getattr(fb, field)
        print("  %-14s A=%-12r B=%-12r%s"
              % (field, x, y, "" if x == y else "   <-- DIFFERS"))

    tree_a, tree_b = fa.walk(), fb.walk()
    changed = compare_maps(
        tree_a, tree_b, "boot partition contents",
        ["dir", "attr", "short", "size", "mtime", "ctime", "atime", "sha"])
    for name in changed:
        if not tree_a[name].get("dir") and tree_a[name].get("sha") != tree_b[name].get("sha"):
            drill_into_file(name, tree_a[name]["_data"], tree_b[name]["_data"])
    return 1


if __name__ == "__main__":
    sys.exit(main())
