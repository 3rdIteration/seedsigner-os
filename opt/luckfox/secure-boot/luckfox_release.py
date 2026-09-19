#!/usr/bin/env python3
"""luckfox_release.py - inspect, check and repair a whole Luckfox release folder.

rkloader.py, fitsign.py and minisign.py each handle one signature format. This
module works on a release as a unit: it knows where the rootfs signature lives,
how to read the signed rootfs out of a NAND bundle, what hardware an image is for,
and whether the MicroSD auto-flash script will actually work.

WHERE THE ROOTFS SIGNATURE LIVES. Not next to the rootfs - inside boot.img. The
FIT's `ramdisk` payload is the verifier initramfs (a gzipped newc cpio) holding:

    /rootfs.sig   the minisign signature over the rootfs
    /pubkey       the Ed25519 key it trusts
    /init         the verifier, with ROOTFS_SIGNED_SIZE baked in

rootfs.img carries no signature. So re-signing the rootfs leaves rootfs.img
byte-identical and rewrites boot.img instead - which then needs the RSA key to
re-seal it. That is also why a NAND bundle needs no `.size` sidecar: the size is
in /init.

WHAT GETS SIGNED ON NAND is the logical UBI volume, not the UBI image in the
bundle (UBI rewrites erase counters, so the raw image is not stable). ubi_volume()
reassembles volume 0 from the image; the first ROOTFS_SIGNED_SIZE bytes of it are
exactly what the device streams from /dev/ubi0_0, which was confirmed by
verifying a real bundle's embedded signature against them.

Pure stdlib, like the three signers it builds on.

  identify   <folder>              hardware, boot medium, serial console, DDR blob
  check      <folder>              every signature, key and known pitfall
  sd-update  <folder> [--fix]      check (and repair) the MicroSD auto-flash script

Exit codes: 0 ok, 1 usage/IO, 2 check failed, 3 parse error.
"""
import argparse, base64, gzip, hashlib, io, os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rkloader as rk            # noqa: E402
import fitsign as fs             # noqa: E402
import minisign as ms            # noqa: E402

# The committed PUBLIC dev keys. Hard-coded rather than read from dev-keys/,
# because on a device only these modules are installed, not the key files.
# tests/test_luckfox_release.py checks they still match the committed keys.
DEV_RSA_MODULUS_SHA256 = "07c0c507c9223a035b3e1b3b0d557fb50b6d0a857f61de3118363afa5348ddd8"
DEV_ROOTFS_KEY_ID = "FB935B80871B6C36"

# Present in /init when the verifier knows about forced verification.
FORCE_MARKER = "force-rootfs-verify"

# The loaders and FITs a release folder is made of.
BOOT_CHAIN = ("idblock.img", "download.bin", "uboot.img", "boot.img")
SECTOR = 0x200

# U-Boot stages each whole image in DRAM before writing it (sd_update.txt), so an
# image must end below the loader's own reserved region at the top of RAM.
# Mini: measured ("Relocation fdt: 02dfa098" -> region from ~0x02DF0000, less a
# 1 MiB margin). The others assume the same reservation below their ram_top;
# Pro and Max share a build profile, so the Pro's 128 MiB is used. The estimates
# are flagged in reports until confirmed from a UART log on each board.
STAGE_BASE = 0x00100000
# What ${ramdisk_addr_r} means in scripts the build did not restage (older
# releases): U-Boot's compiled-in default, not set in env.img.
SDK_STAGE_DEFAULT = 0x00E00000
_RESERVED_BELOW_TOP = 0x04000000 - 0x02DF0000 + 0x00100000
BOARDS = {
    "mini": dict(model="Luckfox Pico Mini", dram=64 << 20, ceiling=0x02D00000, measured=True),
    "max":  dict(model="Luckfox Pico Pro Max", dram=128 << 20,
                 ceiling=(128 << 20) - _RESERVED_BELOW_TOP, measured=False),
    "pi":   dict(model="Luckfox Pico Pi", dram=256 << 20,
                 ceiling=(256 << 20) - _RESERVED_BELOW_TOP, measured=False),
}


class ReleaseError(Exception):
    pass


def fingerprint(n):
    """sha256 of the RSA modulus, big-endian - what rkloader.py inspect prints."""
    return hashlib.sha256(n.to_bytes(256, "big")).hexdigest()


# --- UBI ------------------------------------------------------------------------

def _ubi_layout(f):
    """(peb_size, vid_off, data_off) for an open UBI image."""
    f.seek(0)
    head = f.read(1 << 20)
    if head[:4] != b"UBI#":
        raise ReleaseError("not a UBI image")
    vid_off, data_off = struct.unpack(">II", head[16:24])
    peb = head.find(b"UBI#", 64)
    if peb <= 0:
        raise ReleaseError("cannot find a second erase block - is the image truncated?")
    return peb, vid_off, data_off


def ubi_lebs(path, vol_id=0):
    """[(file_offset, length)] of the volume's logical blocks, in order.

    Static volumes record how many bytes each block really holds (data_size);
    dynamic ones use the whole block. Nothing is read beyond the headers, so this
    is cheap even for a ~90 MiB image.
    """
    size = os.path.getsize(path)
    lebs = {}
    with open(path, "rb") as f:
        peb, vid_off, data_off = _ubi_layout(f)
        for p in range(0, size, peb):
            f.seek(p + vid_off)
            v = f.read(64)
            if v[:4] != b"UBI!":
                continue                                  # empty / erased block
            vol_type = v[5]
            vid, lnum = struct.unpack(">II", v[8:16])
            if vid != vol_id:
                continue
            data_size = struct.unpack(">I", v[20:24])[0]
            length = data_size if vol_type == 2 else peb - data_off
            lebs[lnum] = (p + data_off, length)
    if not lebs:
        raise ReleaseError("UBI volume %d not found" % vol_id)
    return [lebs[i] for i in sorted(lebs)]


def ubi_volume(path, vol_id=0, limit=None):
    """The volume's bytes (optionally only the first `limit`). Loads them all."""
    out = bytearray()
    with open(path, "rb") as f:
        for off, length in ubi_lebs(path, vol_id):
            f.seek(off)
            out += f.read(length)
            if limit is not None and len(out) >= limit:
                return bytes(out[:limit])
    return bytes(out)


# --- the verifier initramfs -----------------------------------------------------

def _cpio_parse(data):
    """newc cpio -> ([entry dict], trailer_offset). Entries keep their metadata."""
    entries, off = [], 0
    while off + 110 <= len(data):
        h = data[off:off + 110]
        if h[:6] != b"070701":
            raise ReleaseError("initramfs is not a newc cpio (bad magic at 0x%x)" % off)
        fields = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        namesize, filesize = fields[11], fields[6]
        name = data[off + 110:off + 110 + namesize - 1].decode("latin1")
        doff = (off + 110 + namesize + 3) & ~3
        entries.append(dict(name=name, fields=fields, data=bytes(data[doff:doff + filesize])))
        if name == "TRAILER!!!":
            return entries, (doff + filesize + 3) & ~3
        off = (doff + filesize + 3) & ~3
    raise ReleaseError("initramfs cpio has no TRAILER!!!")


def _cpio_build(entries, block=512):
    """Serialise entries back to newc, padded to `block` like GNU cpio."""
    out = bytearray()
    for e in entries:
        fields = list(e["fields"])
        name = e["name"].encode("latin1") + b"\x00"
        fields[6], fields[11] = len(e["data"]), len(name)
        out += b"070701" + b"".join(b"%08X" % v for v in fields) + name
        out += b"\x00" * ((4 - len(out) % 4) % 4)
        out += e["data"]
        out += b"\x00" * ((4 - len(out) % 4) % 4)
    out += b"\x00" * ((block - len(out) % block) % block)
    return bytes(out)


def _ramdisk(boot_buf):
    payloads = fs._image_payloads(boot_buf)
    if "ramdisk" not in payloads:
        raise ReleaseError("boot.img has no ramdisk - it was not built with rootfs verification")
    pos, size, _ = payloads["ramdisk"]
    return bytes(boot_buf[pos:pos + size])


def initramfs_members(boot_buf):
    """{path: bytes} of the verifier initramfs inside boot.img (paths without '/')."""
    entries, _ = _cpio_parse(gzip.decompress(_ramdisk(boot_buf)))
    return {e["name"]: e["data"] for e in entries if e["name"] != "TRAILER!!!"}


def initramfs_replace(boot_buf, changes):
    """Return a new boot.img with initramfs members replaced/added/removed.

    `changes` maps a member path to new bytes, or to None to remove it. A new
    member copies its metadata (owner, mtime) from /init and gets a fresh inode,
    and entries stay name-sorted, which is how the build creates the archive.
    Recompressed deterministically (no name, mtime 0, level 9). The returned
    image has a stale signature: sign it.
    """
    entries, _ = _cpio_parse(gzip.decompress(_ramdisk(boot_buf)))
    trailer = [e for e in entries if e["name"] == "TRAILER!!!"]
    body = {e["name"]: e for e in entries if e["name"] != "TRAILER!!!"}
    template = body.get("init")
    if template is None:
        raise ReleaseError("initramfs has no /init")
    next_ino = max(e["fields"][0] for e in entries) + 1

    for name, data in changes.items():
        if data is None:
            body.pop(name, None)
        elif name in body:
            body[name] = dict(body[name], data=bytes(data))
        else:
            fields = list(template["fields"])
            fields[0] = next_ino
            fields[1] = 0o100644                      # regular file, rw-r--r--
            fields[4] = 1                             # nlink
            next_ino += 1
            body[name] = dict(name=name, fields=fields, data=bytes(data))

    ordered = [body[k] for k in sorted(body)] + trailer
    cpio = _cpio_build(ordered)
    return fs.replace_payload(boot_buf, "ramdisk", gzip.compress(cpio, compresslevel=9, mtime=0))


def signed_size(members):
    m = re.search(rb"ROOTFS_SIGNED_SIZE=(\d+)", members.get("init", b""))
    if not m:
        raise ReleaseError("/init has no ROOTFS_SIGNED_SIZE")
    return int(m.group(1))


def supports_force_marker(members):
    return FORCE_MARKER.encode() in members.get("init", b"")


# --- the rootfs -----------------------------------------------------------------

def rootfs_kind(folder):
    path = os.path.join(folder, "rootfs.img")
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        magic = f.read(4)
    return {b"UBI#": "ubi", b"hsqs": "squashfs"}.get(magic, "unknown")


def rootfs_prehash(folder, size):
    """BLAKE2b-512 of the first `size` signed bytes, streamed (minisign -H).

    UBI images are read logical-block by logical-block, so peak memory stays at
    one block regardless of the rootfs size.
    """
    path = os.path.join(folder, "rootfs.img")
    kind = rootfs_kind(folder)
    h = hashlib.blake2b(digest_size=64)
    remaining = size
    with open(path, "rb") as f:
        if kind == "ubi":
            for off, length in ubi_lebs(path):
                f.seek(off)
                while length and remaining:
                    chunk = f.read(min(ms.CHUNK, length, remaining))
                    if not chunk:
                        break
                    h.update(chunk)
                    length -= len(chunk)
                    remaining -= len(chunk)
                if not remaining:
                    break
        elif kind == "squashfs":
            while remaining:
                chunk = f.read(min(ms.CHUNK, remaining))
                if not chunk:
                    break
                h.update(chunk)
                remaining -= len(chunk)
        else:
            raise ReleaseError("rootfs.img is neither a UBI image nor a squashfs")
    if remaining:
        raise ReleaseError("rootfs is %d bytes shorter than the signed size" % remaining)
    return h.digest()


def parse_pubkey_bytes(data):
    lines = data.decode("latin1").splitlines()
    body = base64.b64decode(lines[1])
    return {"key_id": body[2:10], "pk": body[10:]}


def parse_sig_bytes(data):
    lines = data.decode("latin1").splitlines()
    body = base64.b64decode(lines[1])
    return {"alg": body[:2], "key_id": body[2:10], "sig": body[10:],
            "trusted_comment": lines[2][len("trusted comment: "):],
            "global_sig": base64.b64decode(lines[3])}


def verify_rootfs(folder, members):
    """(ok, detail) - the rootfs against the key and signature boot.img holds."""
    pub = parse_pubkey_bytes(members["pubkey"])
    sig = parse_sig_bytes(members["rootfs.sig"])
    if sig["key_id"] != pub["key_id"]:
        return False, "signature key id does not match the embedded public key"
    digest = rootfs_prehash(folder, signed_size(members))
    if not ms.ed25519_verify(pub["pk"], digest, sig["sig"]):
        return False, "rootfs does not match its signature"
    if not ms.ed25519_verify(pub["pk"], sig["sig"] + sig["trusted_comment"].encode(),
                             sig["global_sig"]):
        return False, "trusted comment is not authentic"
    return True, "minisign Ed25519 over %d bytes" % signed_size(members)


# --- rewriting what boot.img's initramfs holds ----------------------------------

# /init bakes in whether each key is the published dev key; it only picks the
# colour of the PASSED screen (yellow = dev), but a re-signed release that still
# says "dev" shows the wrong one, so these follow the keys actually used.
_KEY_CLASS = re.compile(rb"^(FIT|ROOTFS)_KEY_CLASS=(\w+)$", re.M)


def key_classes(members):
    """{"FIT": "dev"|"prod", "ROOTFS": ...} as baked into /init."""
    return {m.group(1).decode(): m.group(2).decode()
            for m in _KEY_CLASS.finditer(members.get("init", b""))}


def rsa_key_class(n):
    return "dev" if fingerprint(n) == DEV_RSA_MODULUS_SHA256 else "prod"


def rootfs_key_class(key_id):
    return "dev" if ms.format_key_id(key_id) == DEV_ROOTFS_KEY_ID else "prod"


def _set_key_classes(init, fit=None, rootfs=None):
    want = {b"FIT": fit, b"ROOTFS": rootfs}

    def sub(m):
        new = want[m.group(1)]
        return m.group(0) if new is None else m.group(1) + b"_KEY_CLASS=" + new.encode()
    return _KEY_CLASS.sub(sub, init)


def ed25519_key(seed):
    """{seed, pk, key_id} for a 32-byte Ed25519 seed (e.g. BIP85-derived)."""
    pk = ms.ed25519_public(seed)
    return dict(seed=bytes(seed), pk=pk, key_id=ms.key_id_for(pk))


def rework_initramfs(boot_buf, folder=None, rootfs_seed=None, rsa_n=None, force=None):
    """Return (new boot.img, [what changed]) with the verifier initramfs updated.

    rootfs_seed  re-sign the rootfs with this Ed25519 seed: new /pubkey and
                 /rootfs.sig. The rootfs in `folder` is first verified against the
                 key boot.img trusts NOW, and anything that does not verify is
                 refused - a re-sign must never launder a modified rootfs.
    rsa_n        the RSA key boot.img is about to be signed with (sets FIT_KEY_CLASS).
    force        True / False sets / clears /force-rootfs-verify; None leaves it.

    The returned image is UNSIGNED whenever anything changed: FIT-sign it next.
    """
    members = initramfs_members(boot_buf)
    changes, done = {}, []
    init = members.get("init", b"")
    fit_class = rootfs_class = None

    if rootfs_seed is not None:
        if folder is None or not rootfs_kind(folder):
            raise ReleaseError("no rootfs.img to re-sign")
        ok, detail = verify_rootfs(folder, members)
        if not ok:
            raise ReleaseError("the rootfs does not verify against the key boot.img "
                               "trusts now (%s) - refusing to re-sign it" % detail)
        key = ed25519_key(rootfs_seed)
        digest = rootfs_prehash(folder, signed_size(members))
        sig = ms.ed25519_sign(key["seed"], digest)
        gsig = ms.ed25519_sign(key["seed"], sig + ms.TRUSTED_COMMENT.encode())
        changes["pubkey"] = ms.format_pubkey(key["key_id"], key["pk"])
        changes["rootfs.sig"] = ms.format_sig(ms.ALG_PREHASHED, key["key_id"], sig,
                                              ms.TRUSTED_COMMENT, gsig)
        rootfs_class = rootfs_key_class(key["key_id"])
        done.append("rootfs re-signed (key %s)" % ms.format_key_id(key["key_id"]))
    if rsa_n is not None:
        fit_class = rsa_key_class(rsa_n)
    new_init = _set_key_classes(init, fit_class, rootfs_class)
    if new_init != init:
        changes["init"] = new_init
        done.append("pass-screen key classes: %s" % key_classes({"init": new_init}))

    if force is not None and force != (FORCE_MARKER in members):
        if force and not supports_force_marker(members):
            raise ReleaseError("this release's verifier predates forced rootfs checks")
        changes[FORCE_MARKER] = b"" if force else None
        done.append("forced rootfs check %s" % ("on" if force else "off"))

    changes = {k: v for k, v in changes.items() if v != members.get(k)}
    if not changes:
        return boot_buf, []
    return initramfs_replace(boot_buf, changes), done


# --- identity -------------------------------------------------------------------

def _kernel_dtb_props(boot_buf):
    pos, size, _ = fs._image_payloads(boot_buf)["fdt"]
    return fs.fdt_props(bytearray(bytes(boot_buf[pos:pos + size])))


def _ddr_version(folder):
    for name in ("idblock.img", "download.bin"):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                m = re.search(rb"ddr-v(\d+\.\d+)", f.read())
            if m:
                return m.group(1).decode()
    return None


def identify(folder):
    info = dict(model=None, profile=None, medium=None, rootfs=None,
                serial_console=None, ddr=_ddr_version(folder))
    boot = os.path.join(folder, "boot.img")
    boot_buf = rk.read(boot) if os.path.isfile(boot) else None
    if boot_buf is not None and "fdt" in fs._image_payloads(boot_buf):
        props = _kernel_dtb_props(boot_buf)
        model = props.get("/", {}).get("model", (b"", 0))[0].rstrip(b"\0").decode("latin1")
        info["model"] = model or None
        for key, board in BOARDS.items():
            if model == board["model"]:
                info["profile"] = key
        args = props.get("/chosen", {}).get("bootargs", (b"", 0))[0].rstrip(b"\0").decode("latin1")
        info["serial_console"] = "console=ttyFIQ0" in args
        if "ubi.mtd=" in args:
            info["medium"] = "nand"
            info["rootfs"] = "squashfs (read-only)" if "ubiblock" in args else "ubifs (writable)"
        elif "mmcblk0" in args:
            info["medium"] = "emmc"
        elif "mmcblk1" in args:
            info["medium"] = "sd"
    if info["medium"] is None:
        # Unsigned builds do not bake root= into the DTB; fall back to the script.
        sd = os.path.join(folder, "sd_update.txt")
        if os.path.isfile(sd) and "spi-nand" in open(sd, errors="replace").read():
            info["medium"] = "nand"
    return info


# --- the MicroSD auto-flash script ----------------------------------------------

_STEP = re.compile(
    r"mw\.b (\S+) 0xff (0x[0-9A-Fa-f]+); (?:fatload mmc \d+|tftp) \S+ (\S+);"
    r".*?mtd erase \S+ (0x[0-9A-Fa-f]+) (0x[0-9A-Fa-f]+);"
    r".*?mtd write \S+ \S+ (0x[0-9A-Fa-f]+) (0x[0-9A-Fa-f]+);")


def _image_end(path):
    """Bytes that must reach flash: a FIT's real extent, else the file size."""
    size = os.path.getsize(path)
    try:
        buf = rk.read(path)
        root = fs.fdt_props(buf).get("/", {})
        if "totalsize" in root:
            return struct.unpack(">I", root["totalsize"][0])[0]
        payloads = fs._image_payloads(buf)
        if payloads:
            return max(p + s for p, s, _ in payloads.values())
    except Exception:
        pass
    return size


def sd_update_check(folder, profile=None, fix=False, script="sd_update.txt"):
    """Check sd_update.txt; with fix=True, correct short write lengths in place.

    `script` may also be tftp_update.txt, which has the same steps over TFTP.

    Returns {"supported", "problems", "fixable", "fixed", "notes"}. A problem is
    fatal (missing image, image bigger than its partition, staging past the
    board's DRAM ceiling); "fixable" are write lengths shorter than the image,
    which silently truncate it - the signed boot.img is the known case.
    """
    res = dict(supported=True, problems=[], fixable=[], fixed=[], notes=[])
    script_name, script = script, os.path.join(folder, script)
    if not os.path.isfile(script):
        res["supported"] = False
        res["notes"].append("no %s: this bundle cannot be auto-flashed that way "
                            "(eMMC bundles never have one)" % script_name)
        return res
    board = BOARDS.get(profile)
    if board and not board["measured"]:
        res["notes"].append("staging ceiling for %s is an estimate (%d MiB DRAM assumed)"
                            % (profile, board["dram"] >> 20))
    lines = open(script, newline="").read().split("\n")
    changed = False
    for i, line in enumerate(lines):
        m = _STEP.search(line)
        if not m:
            continue
        stage_addr, stage_len, name, part_off, part_len, write_off, write_len = m.groups()
        stage_len, part_len, write_len = int(stage_len, 16), int(part_len, 16), int(write_len, 16)
        path = os.path.join(folder, name)
        if not os.path.isfile(path):
            res["problems"].append("%s is listed but missing" % name)
            continue
        need = (_image_end(path) + SECTOR - 1) & ~(SECTOR - 1)
        if need > part_len:
            res["problems"].append("%s needs 0x%X bytes but its partition is 0x%X"
                                   % (name, need, part_len))
            continue
        length = write_len
        if need > write_len:
            res["fixable"].append("%s: the script writes 0x%X of 0x%X bytes - the image "
                                  "would be truncated on flash" % (name, write_len, need))
            if fix:
                new = "0x%X" % need
                line = line.replace("0xff %s;" % m.group(2), "0xff %s;" % new, 1)
                line = re.sub(r"(mtd write \S+ \S+ %s )%s;" % (re.escape(write_off),
                              re.escape(m.group(7))), r"\g<1>%s;" % new, line, count=1)
                lines[i] = line
                if i > 0 and lines[i - 1].startswith("#" + name + " "):
                    parts = lines[i - 1].split(" ")
                    parts[-1] = "0x%X:0x%X" % (need // SECTOR, need)
                    lines[i - 1] = " ".join(parts)
                res["fixed"].append(name)
                changed = True
                length = need
        base = SDK_STAGE_DEFAULT if stage_addr == "${ramdisk_addr_r}" else int(stage_addr, 16)
        if board and base + max(length, stage_len) > board["ceiling"]:
            end = base + max(length, stage_len)
            res["problems"].append(
                "%s: staged at %s it ends at 0x%08X, past the %s ceiling 0x%08X - U-Boot "
                "would overwrite itself and die mid-flash with no output"
                % (name, stage_addr, end, profile, board["ceiling"]))
    if changed:
        with open(script, "w", newline="") as f:
            f.write("\n".join(lines))
    return res


# --- the whole-release check ----------------------------------------------------

class Report:
    """What check_release() found. `ok` means every signature and cross-check held."""

    def __init__(self, folder):
        self.folder = folder
        self.identity = {}
        self.items = []            # (name, ok, detail)
        self.warnings = []
        self.boot_key = None       # dict(fingerprint, dev, n)
        self.rootfs_key = None     # dict(key_id, dev)
        self.armed = None
        self.force_rootfs = None   # True / False / None = unsupported by this /init
        self.sd_update = None

    def add(self, name, ok, detail):
        self.items.append((name, ok, detail))

    @property
    def ok(self):
        return bool(self.items) and all(ok for _n, ok, _d in self.items)


def check_release(folder, profile=None):
    rep = Report(folder)
    rep.identity = identify(folder)
    profile = profile or rep.identity.get("profile")

    # boot chain: every piece must carry and verify under one key
    n = None
    for name in ("idblock.img", "download.bin"):
        path = os.path.join(folder, name)
        if not os.path.isfile(path):
            rep.add(name, False, "missing")
            continue
        buf = rk.read(path)
        lay = rk.layout(buf)
        key = rk.read_modulus(buf, lay)
        if n is None:
            n = key
        sig = rk.rsa_verify_digest(rk.msg_digest(buf, lay), rk.read_sig(buf, lay), key)
        comp = rk.components_ok(buf, lay)
        detail = "signature %s, components %s" % ("ok" if sig else "BAD", "ok" if comp else "STALE")
        if key != n:
            rep.add(name, False, "embeds a DIFFERENT key from idblock.img")
        else:
            rep.add(name, sig and comp, detail)
        if name == "idblock.img":
            rep.armed = rk.is_burn_armed(buf)
    if n:
        rep.boot_key = dict(fingerprint=fingerprint(n), n=n,
                            dev=fingerprint(n) == DEV_RSA_MODULUS_SHA256)
    for name in ("uboot.img", "boot.img"):
        path = os.path.join(folder, name)
        if not os.path.isfile(path):
            rep.add(name, False, "missing")
            continue
        buf = rk.read(path)
        ok = bool(n) and fs.verify_buf(buf, n)
        rep.add(name, ok, "FIT signature %s under the loader's key" % ("ok" if ok else "BAD"))
    uboot = os.path.join(folder, "uboot.img")
    if n and os.path.isfile(uboot):
        embeds = rk.read(uboot).find(n.to_bytes(256, "big")) >= 0
        rep.add("uboot.img key", embeds,
                "embeds the loader's key" if embeds else
                "does NOT embed the loader's key - U-Boot would reject boot.img")

    # rootfs, via what boot.img's initramfs trusts
    boot = os.path.join(folder, "boot.img")
    if os.path.isfile(boot) and rootfs_kind(folder):
        try:
            members = initramfs_members(rk.read(boot))
            pub = parse_pubkey_bytes(members["pubkey"])
            key_id = pub["key_id"][::-1].hex().upper()
            rep.rootfs_key = dict(key_id=key_id, dev=key_id == DEV_ROOTFS_KEY_ID)
            ok, detail = verify_rootfs(folder, members)
            rep.add("rootfs.img", ok, detail)
            rep.force_rootfs = (FORCE_MARKER in members) if supports_force_marker(members) else None
            baked = key_classes(members)
            actual = {"ROOTFS": rootfs_key_class(pub["key_id"])}
            if n:
                actual["FIT"] = rsa_key_class(n)
            wrong = sorted(k for k, v in actual.items() if baked.get(k, v) != v)
            if wrong:
                rep.warnings.append(
                    "the boot screen will call the %s key(s) %s, but they are %s - "
                    "re-sign with Resign Release to correct it"
                    % ("/".join(wrong), "/".join(baked[k] for k in wrong),
                       "/".join(actual[k] for k in wrong)))
        except (ReleaseError, KeyError) as e:
            rep.add("rootfs.img", False, "cannot verify: %s" % e)
    elif os.path.isfile(boot):
        rep.warnings.append("no rootfs.img in this folder - the rootfs was not checked")

    if rep.boot_key and rep.boot_key["dev"]:
        rep.warnings.append("boot chain is signed with the PUBLISHED dev key - no protection")
    if rep.rootfs_key and rep.rootfs_key["dev"]:
        rep.warnings.append("rootfs is signed with the PUBLISHED dev key - no protection")
    if rep.armed:
        rep.warnings.append("idblock.img is ARMED: booting it burns the secure-boot fuse")
    if os.path.isfile(os.path.join(folder, "update.img")):
        rep.warnings.append("update.img is present; if this release was re-signed it still "
                            "carries the old chain")

    rep.sd_update = sd_update_check(folder, profile)
    for p in rep.sd_update["problems"] + rep.sd_update["fixable"]:
        rep.warnings.append("MicroSD auto-flash: " + p)
    return rep


def format_report(rep):
    i = rep.identity
    out = ["Release: %s" % rep.folder,
           "Hardware: %s (%s)" % (i.get("model") or "unknown", i.get("profile") or "?"),
           "Boot medium: %s   rootfs: %s" % (i.get("medium") or "?", i.get("rootfs") or "?"),
           "Serial console: %s   DDR blob: %s" % (
               {True: "on", False: "off"}.get(i.get("serial_console"), "?"), i.get("ddr") or "?")]
    if rep.boot_key:
        out.append("Boot key: %s%s" % (rep.boot_key["fingerprint"],
                                       "  (PUBLISHED DEV KEY)" if rep.boot_key["dev"] else ""))
    if rep.rootfs_key:
        out.append("Rootfs key: %s%s" % (rep.rootfs_key["key_id"],
                                         "  (PUBLISHED DEV KEY)" if rep.rootfs_key["dev"] else ""))
    out.append("Forced rootfs check: %s" % {True: "on", False: "off",
                                            None: "not supported by this verifier"}[rep.force_rootfs])
    out.append("")
    for name, ok, detail in rep.items:
        out.append("  %-14s %-5s %s" % (name, "OK" if ok else "FAIL", detail))
    for w in rep.warnings:
        out.append("  ! " + w)
    for n in (rep.sd_update or {}).get("notes", []):
        out.append("  - " + n)
    out.append("")
    out.append("RESULT: %s" % ("VALID" if rep.ok else "INVALID"))
    return "\n".join(out)


def main(argv=None):
    p = argparse.ArgumentParser(prog="luckfox_release.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("identify", "check"):
        s = sub.add_parser(name)
        s.add_argument("folder")
    s = sub.add_parser("sd-update")
    s.add_argument("folder")
    s.add_argument("--profile", choices=sorted(BOARDS))
    s.add_argument("--fix", action="store_true", help="correct short write lengths in place")
    s.add_argument("--script", default="sd_update.txt", help="or tftp_update.txt")
    s.add_argument("--lengths-only", action="store_true",
                   help="skip the DRAM staging check (the build does its own)")
    a = p.parse_args(argv)
    try:
        if a.cmd == "identify":
            for k, v in identify(a.folder).items():
                print("%-15s %s" % (k, v))
            return 0
        if a.cmd == "check":
            rep = check_release(a.folder)
            print(format_report(rep))
            return 0 if rep.ok else 2
        profile = None if a.lengths_only else (a.profile or identify(a.folder).get("profile"))
        res = sd_update_check(a.folder, profile, a.fix, a.script)
        for key, label in (("problems", "problem"), ("fixable", "fixable"), ("notes", "note")):
            for line in res[key]:
                print("%-9s %s" % (label, line))
        if res["fixed"]:
            print("fixed:    %s" % ", ".join(res["fixed"]))
        return 2 if res["problems"] or (res["fixable"] and not a.fix) else 0
    except ReleaseError as e:
        print("luckfox_release: %s" % e, file=sys.stderr)
        return 3
    except OSError as e:
        print("luckfox_release: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
