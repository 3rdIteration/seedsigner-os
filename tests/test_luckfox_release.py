#!/usr/bin/env python3
"""Tests for opt/luckfox/secure-boot/luckfox_release.py (and fitsign.replace_payload).

  * Synthetic - builds a release folder from scratch: a signed boot.img FIT with a
    kernel DTB and a verifier initramfs, a UBI or squashfs rootfs signed the way
    the build signs it, and an sd_update.txt. Runs in CI.

  * Artifact  - if a signed NAND bundle is present under opt/luckfox/build-output/,
    its rootfs is read out of the UBI image and checked against the signature
    boot.img carries, and its MicroSD script is repaired on a copy. Skipped
    otherwise (build-output/ is gitignored).

Run:  python3 tests/test_luckfox_release.py
"""
import glob, gzip, hashlib, os, shutil, struct, sys, tempfile, unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SB = os.path.join(REPO, "opt", "luckfox", "secure-boot")
DEV_KEY = os.path.join(SB, "dev-keys", "dev.key")
DEV_PUB = os.path.join(SB, "dev-keys", "dev.pubkey")
DEV_ROOTFS_PUB = os.path.join(SB, "dev-keys-rootfs", "dev.pubkey")

sys.path.insert(0, SB)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luckfox_release as lr     # noqa: E402
import fitsign as fs             # noqa: E402
import minisign as ms            # noqa: E402
import rkloader as rk            # noqa: E402
from test_fitsign import Fdt     # noqa: E402

N, _E, D = rk.load_privkey(DEV_KEY)
ROOTFS_SEED = bytes([7]) * 32           # stands in for the build's rootfs key
NEW_SEED = bytes([9]) * 32              # stands in for a BIP85-derived one

INIT_TEMPLATE = (b"#!/bin/sh\nROOTFS_SIGNED_SIZE=%d\nFIT_KEY_CLASS=dev\nROOTFS_KEY_CLASS=dev\n"
                 b"%s\nexec switch_root /mnt /sbin/init\n")


def _align(n, a=0x200):
    return (n + a - 1) & ~(a - 1)


# --- builders -------------------------------------------------------------------

def cpio(members):
    """{name: bytes} -> newc cpio, sorted, like the build's `find | sort | cpio`."""
    entries = []
    for ino, name in enumerate(sorted(members), 1):
        mode = 0o100755 if name == "init" else 0o100644
        fields = [ino, mode, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        entries.append(dict(name=name, fields=fields, data=members[name]))
    entries.append(dict(name="TRAILER!!!", fields=[0] * 13, data=b""))
    return lr._cpio_build(entries)


def kernel_dtb(model=b"Luckfox Pico Pro Max",
               bootargs=b"console=ttyFIQ0 ubi.mtd=4 root=ubi0:rootfs rootfstype=ubifs"):
    f = Fdt()
    f.begin("")
    f.prop("model", model + b"\x00")
    f.begin("chosen")
    f.prop("bootargs", bootargs + b"\x00")
    f.end()
    f.end()
    return bytes(f.finish())


def build_boot(payloads):
    """A signed boot.img shaped like the build's: external, 0x200-aligned payloads
    with /totalsize, one hash node each, one signed configuration."""
    names = list(payloads)
    f = Fdt()
    f.begin("")
    f.prop("totalsize", struct.pack(">I", 0))
    f.prop("timestamp", struct.pack(">I", 0))
    f.begin("images")
    for name in names:
        f.begin(name)
        f.prop("data-size", struct.pack(">I", len(payloads[name])))
        f.prop("data-position", struct.pack(">I", 0))
        f.begin("hash")
        f.prop("algo", b"sha256\x00")
        f.prop("value", hashlib.sha256(payloads[name]).digest())
        f.end()
        f.end()
    f.end()
    f.begin("configurations")
    f.prop("default", b"conf\x00")
    f.begin("conf")
    for name in names:
        f.prop(name, name.encode() + b"\x00")
    hashed_prefix = len(f.strings)
    f.begin("signature")
    f.prop("algo", b"sha256,rsa2048\x00")
    f.prop("padding", b"pss\x00")
    f.prop("key-name-hint", b"dev\x00")
    nodes = [b"/", b"/configurations", b"/configurations/conf"]
    for name in names:
        nodes += [b"/images/" + name.encode(), b"/images/" + name.encode() + b"/hash"]
    f.prop("hashed-nodes", b"\x00".join(nodes) + b"\x00")
    f.prop("hashed-strings", struct.pack(">II", 0, hashed_prefix))
    f.prop("value", b"\x00" * 256)
    f.end()
    f.end()
    f.end()
    f.end()
    buf = f.finish()
    props = fs.fdt_props(buf)
    out = bytearray(buf)
    for name in names:
        out += b"\x00" * (_align(len(out)) - len(out))
        struct.pack_into(">I", out, props["/images/" + name]["data-position"][1], len(out))
        out += payloads[name]
    total = _align(len(out)) + 0xC00
    struct.pack_into(">I", out, props["/"]["totalsize"][1], total)
    out += b"\x00" * (total - len(out))
    fs.sign_buf(out, N, D)
    return out


def build_ubi(volume, peb=0x2000, vid_off=0x800, data_off=0x1000, vol_type=1):
    """A UBI image holding `volume` as volume 0, blocks deliberately out of order,
    with a layout-volume block and an erased (header-only) block mixed in."""
    leb = peb - data_off
    chunks = [volume[i:i + leb] for i in range(0, len(volume), leb)]

    def block(vid=None, lnum=0, data=b""):
        b = bytearray(b"\xff" * peb)
        b[0:4] = b"UBI#"
        struct.pack_into(">II", b, 16, vid_off, data_off)
        if vid is not None:
            v = bytearray(64)
            v[0:4] = b"UBI!"
            v[5] = vol_type
            struct.pack_into(">II", v, 8, vid, lnum)
            struct.pack_into(">I", v, 20, len(data))
            b[vid_off:vid_off + 64] = v
            b[data_off:data_off + len(data)] = data
        return bytes(b)

    blocks = [block(0x7fffefff, 0, b"layout")] + \
             [block(0, i, c) for i, c in enumerate(chunks)] + [block()]
    order = [0] + list(range(len(blocks) - 2, 0, -1)) + [len(blocks) - 1]
    return b"".join(blocks[i] for i in order)


def sign_rootfs(data, seed):
    key = lr.ed25519_key(seed)
    sig = ms.ed25519_sign(seed, hashlib.blake2b(data, digest_size=64).digest())
    gsig = ms.ed25519_sign(seed, sig + ms.TRUSTED_COMMENT.encode())
    return (ms.format_pubkey(key["key_id"], key["pk"]),
            ms.format_sig(ms.ALG_PREHASHED, key["key_id"], sig, ms.TRUSTED_COMMENT, gsig))


SD_UPDATE = (
    "#boot.img 0x800:0x100000 0x2000:0x400000 0x8:0x1000\n"
    "mw.b 0x00100000 0xff 0x1000; fatload mmc 1 0x00100000 boot.img; "
    "mtd erase spi-nand0 0x100000 0x400000; mtd write spi-nand0 0x00100000 0x100000 0x1000;\n"
    "\n"
    "#rootfs.img 0x11800:0x2300000 0x6C800:0xD900000 0x18000:0x3000000\n"
    "mw.b 0x00100000 0xff 0x3000000; fatload mmc 1 0x00100000 rootfs.img; "
    "mtd erase spi-nand0 0x2300000 0xD900000; mtd write spi-nand0 0x00100000 0x2300000 0x3000000;\n"
    "\n"
    "% <- this is end of file symbol\n")


def make_release(folder, kind="ubi", force_aware=True, marker=False):
    """A NAND-style release: boot.img (signed, dev RSA key) + rootfs.img + sd_update.txt."""
    volume = bytes((i * 31 + 7) & 0xff for i in range(0x5000)) + b"\x00" * 0x1800
    signed = 0x5000                       # the partition is padded past the signed bytes
    pub, sig = sign_rootfs(volume[:signed], ROOTFS_SEED)
    init = INIT_TEMPLATE % (signed, b"[ -e /force-rootfs-verify ]" if force_aware else b"")
    members = {"init": init, "pubkey": pub, "rootfs.sig": sig, "bin/busybox": b"\x7fELF" * 64}
    if marker:
        members[lr.FORCE_MARKER] = b""
    boot = build_boot({
        "fdt": kernel_dtb(),
        "kernel": b"KERNEL" * 300,
        "ramdisk": gzip.compress(cpio(members), compresslevel=9, mtime=0),
        "resource": b"RESOURCE" * 50,
    })
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "boot.img"), "wb") as f:
        f.write(boot)
    with open(os.path.join(folder, "rootfs.img"), "wb") as f:
        f.write(build_ubi(volume) if kind == "ubi" else b"hsqs" + volume[4:])
    if kind != "ubi":                     # a squashfs is signed as-is, magic included
        pub, sig = sign_rootfs((b"hsqs" + volume[4:])[:signed], ROOTFS_SEED)
        boot = lr.initramfs_replace(boot, {"pubkey": pub, "rootfs.sig": sig})
        fs.sign_buf(boot, N, D)
        with open(os.path.join(folder, "boot.img"), "wb") as f:
            f.write(boot)
    with open(os.path.join(folder, "sd_update.txt"), "w", newline="") as f:
        f.write(SD_UPDATE)
    return volume


# --- tests ----------------------------------------------------------------------

class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="luckfox-release-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def boot(self):
        return rk.read(os.path.join(self.tmp, "boot.img"))


class DevKeys(unittest.TestCase):
    """The hard-coded dev-key identities must match the committed keys."""

    def test_rsa_fingerprint(self):
        self.assertEqual(lr.fingerprint(rk.load_pubkey(DEV_PUB)[0]), lr.DEV_RSA_MODULUS_SHA256)

    def test_rootfs_key_id(self):
        key = ms.load_pubkey(DEV_ROOTFS_PUB)
        self.assertEqual(ms.format_key_id(key["key_id"]), lr.DEV_ROOTFS_KEY_ID)
        self.assertEqual(lr.rootfs_key_class(key["key_id"]), "dev")

    def test_documented_hashes(self):
        doc = open(os.path.join(REPO, "docs", "luckfox", "verifying-a-release.md"),
                   encoding="utf-8").read()
        self.assertIn(lr.DEV_RSA_MODULUS_SHA256, doc)
        self.assertIn(lr.DEV_ROOTFS_KEY_ID, doc)
        with open(DEV_ROOTFS_PUB, "rb") as f:
            self.assertIn(hashlib.sha256(f.read()).hexdigest(), doc)


class Ubi(Base):
    def test_volume_reassembled_in_logical_order(self):
        volume = bytes(range(256)) * 40
        path = os.path.join(self.tmp, "r.img")
        with open(path, "wb") as f:
            f.write(build_ubi(volume))
        # dynamic volume: the last block is padded to a whole LEB
        self.assertEqual(lr.ubi_volume(path)[:len(volume)], volume)
        self.assertEqual(lr.ubi_volume(path, limit=1000), volume[:1000])

    def test_static_volume_honours_data_size(self):
        volume = b"S" * 0x1800
        path = os.path.join(self.tmp, "s.img")
        with open(path, "wb") as f:
            f.write(build_ubi(volume, vol_type=2))
        self.assertEqual(lr.ubi_volume(path), volume)

    def test_not_ubi(self):
        path = os.path.join(self.tmp, "x.img")
        with open(path, "wb") as f:
            f.write(b"hsqs" + b"\x00" * 100)
        with self.assertRaises(lr.ReleaseError):
            lr.ubi_lebs(path)


class ReplacePayload(Base):
    def test_identity_is_byte_identical(self):
        make_release(self.tmp)
        boot = self.boot()
        for name, (pos, size, _h) in fs._image_payloads(boot).items():
            self.assertEqual(bytes(fs.replace_payload(boot, name, boot[pos:pos + size])),
                             bytes(boot), name)

    def test_grow_and_shrink_keep_the_rest_intact(self):
        make_release(self.tmp)
        boot = self.boot()
        before = {k: bytes(boot[p:p + s]) for k, (p, s, _h) in fs._image_payloads(boot).items()}
        for new in (b"R" * 5000, b"r"):
            out = fs.replace_payload(boot, "ramdisk", new)
            after = fs._image_payloads(out)
            for name, (pos, size, _h) in after.items():
                self.assertEqual(pos % 0x200, 0, name)
                self.assertEqual(bytes(out[pos:pos + size]),
                                 new if name == "ramdisk" else before[name], name)
            total = struct.unpack(">I", fs.fdt_props(out)["/"]["totalsize"][0])[0]
            self.assertEqual(total, _align(max(p + s for p, s, _h in after.values())) + 0xC00)
            self.assertFalse(fs.verify_buf(out, N), "a changed payload must need re-signing")
            fs.sign_buf(out, N, D)
            self.assertTrue(fs.verify_buf(out, N))


class Initramfs(Base):
    def test_rebuild_is_byte_identical(self):
        make_release(self.tmp)
        boot = self.boot()
        entries, _ = lr._cpio_parse(gzip.decompress(lr._ramdisk(boot)))
        self.assertEqual(lr._cpio_build(entries), gzip.decompress(lr._ramdisk(boot)))

    def test_add_and_remove_a_member(self):
        make_release(self.tmp)
        boot = self.boot()
        before = lr.initramfs_members(boot)
        added = lr.initramfs_members(lr.initramfs_replace(boot, {"new": b"x"}))
        self.assertEqual(added.pop("new"), b"x")
        self.assertEqual(added, before)
        removed = lr.initramfs_members(lr.initramfs_replace(boot, {"bin/busybox": None}))
        self.assertNotIn("bin/busybox", removed)

    def test_signed_size_and_marker_support(self):
        make_release(self.tmp)
        m = lr.initramfs_members(self.boot())
        self.assertEqual(lr.signed_size(m), 0x5000)
        self.assertTrue(lr.supports_force_marker(m))
        self.assertEqual(lr.key_classes(m), {"FIT": "dev", "ROOTFS": "dev"})

    def test_real_init_mentions_the_marker(self):
        """supports_force_marker() looks for this string; /init must contain it."""
        with open(os.path.join(SB, "initramfs", "init"), "rb") as f:
            init = f.read()
        self.assertIn(b"/" + lr.FORCE_MARKER.encode(), init)
        self.assertIn(b"FIT_KEY_CLASS=__FIT_KEY_CLASS__", init)
        self.assertIn(b"ROOTFS_KEY_CLASS=__ROOTFS_KEY_CLASS__", init)


class Rootfs(Base):
    def test_ubi_rootfs_verifies(self):
        make_release(self.tmp, "ubi")
        self.assertEqual(lr.rootfs_kind(self.tmp), "ubi")
        ok, detail = lr.verify_rootfs(self.tmp, lr.initramfs_members(self.boot()))
        self.assertTrue(ok, detail)

    def test_squashfs_rootfs_verifies(self):
        make_release(self.tmp, "squashfs")
        self.assertEqual(lr.rootfs_kind(self.tmp), "squashfs")
        ok, detail = lr.verify_rootfs(self.tmp, lr.initramfs_members(self.boot()))
        self.assertTrue(ok, detail)

    def test_tampered_rootfs_fails(self):
        make_release(self.tmp, "squashfs")
        with open(os.path.join(self.tmp, "rootfs.img"), "r+b") as f:
            f.seek(0x100)
            f.write(b"\x00\x01")
        ok, _ = lr.verify_rootfs(self.tmp, lr.initramfs_members(self.boot()))
        self.assertFalse(ok)

    def test_bytes_past_the_signed_size_are_ignored(self):
        make_release(self.tmp, "squashfs")
        with open(os.path.join(self.tmp, "rootfs.img"), "r+b") as f:
            f.seek(0x5800)
            f.write(b"padding changes")
        ok, _ = lr.verify_rootfs(self.tmp, lr.initramfs_members(self.boot()))
        self.assertTrue(ok)


class Rework(Base):
    def test_resign_rootfs_and_key_classes(self):
        make_release(self.tmp)
        boot = self.boot()
        other_n = rk.load_pubkey(DEV_PUB)[0] + 2        # any non-dev modulus
        new, done = lr.rework_initramfs(boot, self.tmp, rootfs_seed=NEW_SEED, rsa_n=other_n)
        self.assertTrue(done)
        m = lr.initramfs_members(new)
        ok, detail = lr.verify_rootfs(self.tmp, m)
        self.assertTrue(ok, detail)
        self.assertEqual(lr.parse_pubkey_bytes(m["pubkey"])["key_id"],
                         lr.ed25519_key(NEW_SEED)["key_id"])
        self.assertEqual(lr.key_classes(m), {"FIT": "prod", "ROOTFS": "prod"})
        old = lr.initramfs_members(boot)
        self.assertEqual(m["bin/busybox"], old["bin/busybox"])
        # the kernel etc. are untouched, and one FIT signature seals it again
        for name in ("fdt", "kernel", "resource"):
            p0, s0, _ = fs._image_payloads(boot)[name]
            p1, s1, _ = fs._image_payloads(new)[name]
            self.assertEqual(bytes(boot[p0:p0 + s0]), bytes(new[p1:p1 + s1]))
        fs.sign_buf(new, N, D)
        self.assertTrue(fs.verify_buf(new, N))

    def test_dev_rsa_key_keeps_fit_class_dev(self):
        make_release(self.tmp)
        new, _ = lr.rework_initramfs(self.boot(), self.tmp, rootfs_seed=NEW_SEED, rsa_n=N)
        self.assertEqual(lr.key_classes(lr.initramfs_members(new)),
                         {"FIT": "dev", "ROOTFS": "prod"})

    def test_third_party_key_id_travels_with_the_signature(self):
        """A minisign -G key carries a random id that is not derivable from the
        seed; re-signing with it must tag /pubkey and /rootfs.sig with THAT id,
        or host-side verification against the original public key fails."""
        make_release(self.tmp)
        foreign = b"\x01" * 8
        self.assertNotEqual(foreign, lr.ed25519_key(NEW_SEED)["key_id"])
        new, done = lr.rework_initramfs(self.boot(), self.tmp, rootfs_seed=NEW_SEED,
                                        rsa_n=N, rootfs_key_id=foreign)
        m = lr.initramfs_members(new)
        ok, detail = lr.verify_rootfs(self.tmp, m)
        self.assertTrue(ok, detail)
        self.assertEqual(lr.parse_pubkey_bytes(m["pubkey"])["key_id"], foreign)
        self.assertEqual(lr.parse_sig_bytes(m["rootfs.sig"])["key_id"], foreign)
        # an unknown id is a prod key, whatever the seed would derive
        self.assertEqual(lr.rootfs_key_class(foreign), "prod")

    def test_ed25519_key_defaults_to_the_derived_id(self):
        k = lr.ed25519_key(NEW_SEED)
        self.assertEqual(k["key_id"], ms.key_id_for(ms.ed25519_public(NEW_SEED)))
        explicit = b"\x02" * 8
        self.assertEqual(lr.ed25519_key(NEW_SEED, explicit)["key_id"], explicit)

    def test_refuses_to_resign_a_rootfs_that_does_not_verify(self):
        make_release(self.tmp, "squashfs")
        with open(os.path.join(self.tmp, "rootfs.img"), "r+b") as f:
            f.seek(0x10)
            f.write(b"EVIL")
        with self.assertRaises(lr.ReleaseError):
            lr.rework_initramfs(self.boot(), self.tmp, rootfs_seed=NEW_SEED)

    def test_force_marker_on_and_off(self):
        make_release(self.tmp)
        boot = self.boot()
        on, done = lr.rework_initramfs(boot, force=True)
        self.assertEqual(done, ["forced rootfs check on"])
        m_on = lr.initramfs_members(on)
        self.assertIn(lr.FORCE_MARKER, m_on)
        off, _ = lr.rework_initramfs(on, force=False)
        self.assertEqual(lr.initramfs_members(off), lr.initramfs_members(boot))
        self.assertEqual(bytes(lr._ramdisk(off)), bytes(lr._ramdisk(boot)))

    def test_no_change_returns_the_same_image(self):
        make_release(self.tmp)
        boot = self.boot()
        same, done = lr.rework_initramfs(boot, force=False, rsa_n=N)
        self.assertIs(same, boot)
        self.assertEqual(done, [])

    def test_force_refused_on_an_old_verifier(self):
        make_release(self.tmp, force_aware=False)
        with self.assertRaises(lr.ReleaseError):
            lr.rework_initramfs(self.boot(), force=True)


class Identify(Base):
    def test_model_medium_console(self):
        make_release(self.tmp)
        info = lr.identify(self.tmp)
        self.assertEqual(info["model"], "Luckfox Pico Pro Max")
        self.assertEqual(info["profile"], "max")
        self.assertEqual(info["medium"], "nand")
        self.assertEqual(info["rootfs"], "ubifs (writable)")
        self.assertTrue(info["serial_console"])


class SdUpdate(Base):
    def test_truncation_detected_and_fixed(self):
        make_release(self.tmp)
        res = lr.sd_update_check(self.tmp, "max")
        self.assertEqual(len(res["fixable"]), 1)
        self.assertIn("boot.img", res["fixable"][0])
        res = lr.sd_update_check(self.tmp, "max", fix=True)
        self.assertEqual(res["fixed"], ["boot.img"])
        self.assertFalse(lr.sd_update_check(self.tmp, "max")["fixable"])
        text = open(os.path.join(self.tmp, "sd_update.txt"), newline="").read()
        need = _align(lr._image_end(os.path.join(self.tmp, "boot.img")))
        self.assertIn("mw.b 0x00100000 0xff 0x%X;" % need, text)
        self.assertIn("mtd write spi-nand0 0x00100000 0x100000 0x%X;" % need, text)
        self.assertIn("#boot.img 0x800:0x100000 0x2000:0x400000 0x%X:0x%X\n"
                      % (need // 0x200, need), text)
        self.assertTrue(text.endswith("% <- this is end of file symbol\n"))

    def test_staging_overrun_is_per_board(self):
        make_release(self.tmp)
        self.assertTrue(any("rootfs.img" in p and "ceiling" in p
                            for p in lr.sd_update_check(self.tmp, "mini")["problems"]))
        self.assertFalse(lr.sd_update_check(self.tmp, "max")["problems"])
        self.assertFalse(lr.sd_update_check(self.tmp, None)["problems"])

    def test_image_bigger_than_partition(self):
        make_release(self.tmp)
        text = SD_UPDATE.replace("mtd erase spi-nand0 0x100000 0x400000",
                                 "mtd erase spi-nand0 0x100000 0x200")
        with open(os.path.join(self.tmp, "sd_update.txt"), "w", newline="") as f:
            f.write(text)
        res = lr.sd_update_check(self.tmp, "max", fix=True)
        self.assertTrue(any("partition" in p for p in res["problems"]))
        self.assertEqual(res["fixed"], [])

    def test_tftp_script(self):
        make_release(self.tmp)
        with open(os.path.join(self.tmp, "tftp_update.txt"), "w", newline="") as f:
            f.write(SD_UPDATE.replace("fatload mmc 1 0x00100000", "tftp 0x00100000"))
        res = lr.sd_update_check(self.tmp, None, fix=True, script="tftp_update.txt")
        self.assertEqual(res["fixed"], ["boot.img"])

    def test_no_script(self):
        make_release(self.tmp)
        os.remove(os.path.join(self.tmp, "sd_update.txt"))
        self.assertFalse(lr.sd_update_check(self.tmp, "max")["supported"])


class ImageEnd(Base):
    """_image_end must not read whole files: sd_update_check calls it for every image
    in the script - including the ~90 MiB rootfs - and a full-file read OOM-killed the
    app on-device (64-128 MB DRAM boards) during Check Release and re-signing."""

    def test_fit_extent_unchanged(self):
        make_release(self.tmp)
        path = os.path.join(self.tmp, "boot.img")
        buf = rk.read(path)
        root = fs.fdt_props(buf).get("/", {})
        if "totalsize" in root:
            want = struct.unpack(">I", root["totalsize"][0])[0]
        else:
            payloads = fs._image_payloads(buf)
            want = max(p + s for p, s, _ in payloads.values())
        self.assertEqual(lr._image_end(path), want)

    def test_non_fit_is_the_file_size(self):
        make_release(self.tmp)
        path = os.path.join(self.tmp, "rootfs.img")
        self.assertEqual(lr._image_end(path), os.path.getsize(path))

    def test_large_non_fit_does_not_enter_ram(self):
        import tracemalloc
        big = os.path.join(self.tmp, "big.img")
        with open(big, "wb") as f:
            f.seek(128 << 20)
            f.write(b"\x00")                      # sparse: 128 MiB on disk, nothing to read
        tracemalloc.start()
        self.assertEqual(lr._image_end(big), os.path.getsize(big))
        _cur, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        self.assertLess(peak, 1 << 20)

    def test_corrupt_fit_header_falls_back_to_size(self):
        bad = os.path.join(self.tmp, "bad.img")
        with open(bad, "wb") as f:
            # valid FDT magic, but the strings block is claimed to be past EOF
            f.write(struct.pack(">10I", fs.FDT_MAGIC, 0, 0x100, 0x200, 0,
                                2, 1, 0, 0xFFFFFFFF, 0))
            f.write(b"\x00" * 0x300)
        self.assertEqual(lr._image_end(bad), os.path.getsize(bad))


class CheckRelease(Base):
    def test_report_on_a_boot_only_folder(self):
        """No loaders here, so the chain is reported missing - but the rootfs and the
        dev-key flags are still worked out through boot.img."""
        make_release(self.tmp)
        rep = lr.check_release(self.tmp)
        items = {name: ok for name, ok, _d in rep.items}
        self.assertFalse(items["idblock.img"])
        self.assertTrue(items["rootfs.img"])
        self.assertFalse(rep.ok)
        self.assertEqual(rep.rootfs_key["key_id"],
                         ms.format_key_id(lr.ed25519_key(ROOTFS_SEED)["key_id"]))
        self.assertFalse(rep.force_rootfs)
        self.assertIn("RESULT: INVALID", lr.format_report(rep))

    def _add_ldr_download(self, stale_trailer=False):
        """A signed LDR download.bin (dev key), optionally with a stale trailer -
        the state a re-sign used to leave it in."""
        off = 0x1bc
        buf = bytearray(b"\xa5" * (off + rk.HDR_LEN + rk.SIG_LEN + 0x40))
        buf[0:4] = rk.LDR_TAG
        buf[off:off + 4] = rk.MAGIC_UNSIGNED
        struct.pack_into("<I", buf, off + 0x0c, 0x01)
        buf[off + rk.MOD_OFF:off + rk.MOD_OFF + rk.SIG_LEN] = N.to_bytes(rk.SIG_LEN, "little")
        lay = rk.layout(buf)
        rk.sign_buf(buf, lay, N, D)
        if stale_trailer:
            buf[0x10] ^= 0xff                     # mutate outside the header, no refresh
        with open(os.path.join(self.tmp, "download.bin"), "wb") as f:
            f.write(bytes(buf))

    def test_ldr_download_with_a_valid_trailer_passes(self):
        make_release(self.tmp)
        self._add_ldr_download()
        rep = lr.check_release(self.tmp)
        items = {name: (ok, detail) for name, ok, detail in rep.items}
        self.assertTrue(items["download.bin"][0], items["download.bin"][1])

    def test_stale_ldr_trailer_fails_the_check(self):
        """Regression: a re-signed download.bin whose trailer CRC no longer covers
        its bytes is rejected by SoCtoolkit on load; Check Release must say so."""
        make_release(self.tmp)
        self._add_ldr_download(stale_trailer=True)
        rep = lr.check_release(self.tmp)
        items = {name: (ok, detail) for name, ok, detail in rep.items}
        ok, detail = items["download.bin"]
        self.assertFalse(ok)
        self.assertIn("trailer", detail)


# --- artifacts ------------------------------------------------------------------

def _nand_bundles():
    pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*nand-files*signed-devkey*")
    return [d for d in glob.glob(pat)
            if os.path.isfile(os.path.join(d, "boot.img"))
            and lr.rootfs_kind(d) == "ubi"]


class Artifacts(unittest.TestCase):
    def setUp(self):
        self.bundles = _nand_bundles()
        if not self.bundles:
            self.skipTest("no signed NAND bundle under opt/luckfox/build-output/ (gitignored)")

    def test_ubi_rootfs_verifies_against_the_embedded_signature(self):
        for d in self.bundles:
            with self.subTest(d=os.path.basename(d)):
                members = lr.initramfs_members(rk.read(os.path.join(d, "boot.img")))
                ok, detail = lr.verify_rootfs(d, members)
                self.assertTrue(ok, detail)

    def test_check_release_is_valid_with_dev_keys(self):
        for d in self.bundles:
            with self.subTest(d=os.path.basename(d)):
                rep = lr.check_release(d)
                self.assertTrue(rep.ok, lr.format_report(rep))
                self.assertTrue(rep.boot_key["dev"])
                self.assertTrue(rep.rootfs_key["dev"])

    def test_sd_update_repair_on_a_copy(self):
        for d in self.bundles:
            if not os.path.isfile(os.path.join(d, "sd_update.txt")):
                continue
            with self.subTest(d=os.path.basename(d)), tempfile.TemporaryDirectory() as tmp:
                for name in os.listdir(d):
                    if name != "update.img" and os.path.isfile(os.path.join(d, name)):
                        shutil.copy(os.path.join(d, name), tmp)
                lr.sd_update_check(tmp, None, fix=True)
                self.assertFalse(lr.sd_update_check(tmp, None)["fixable"])


if __name__ == "__main__":
    unittest.main()
