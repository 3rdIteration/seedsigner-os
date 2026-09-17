#!/usr/bin/env python3
"""Tests for opt/luckfox/secure-boot/fitsign.py.

  * Synthetic - builds a small but structurally real FIT (flattened device tree
    with hashed-nodes / hashed-strings / a signature node) and exercises
    sign/verify/splice/canonicalise plus the negative cases. Runs in CI.

  * Artifact   - if a signed build is present under opt/luckfox/build-output/,
    every uboot.img / boot.img in it is verified against the committed dev
    pubkey. Skipped otherwise (build-output/ is gitignored).

Run:  python3 tests/test_fitsign.py
"""
import os, sys, glob, struct, hashlib, shutil, tempfile, unittest, importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SB = os.path.join(REPO, "opt", "luckfox", "secure-boot")
DEV_KEY = os.path.join(SB, "dev-keys", "dev.key")
DEV_PUB = os.path.join(SB, "dev-keys", "dev.pubkey")

sys.path.insert(0, SB)
_spec = importlib.util.spec_from_file_location("fitsign", os.path.join(SB, "fitsign.py"))
fs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fs)


# --- a minimal FIT builder --------------------------------------------------

class Fdt:
    """Just enough FDT writer to produce a FIT that fitsign.py must accept."""

    def __init__(self):
        self.strings = bytearray()
        self.struct = bytearray()

    def _soff(self, name):
        b = name.encode() + b"\x00"
        at = bytes(self.strings).find(b)
        if at >= 0:
            return at
        at = len(self.strings)
        self.strings += b
        return at

    def begin(self, name):
        self.struct += struct.pack(">I", 1) + name.encode() + b"\x00"
        while len(self.struct) % 4:
            self.struct += b"\x00"

    def end(self):
        self.struct += struct.pack(">I", 2)

    def prop(self, name, value):
        self.struct += struct.pack(">III", 3, len(value), self._soff(name)) + value
        while len(self.struct) % 4:
            self.struct += b"\x00"

    def finish(self):
        self.struct += struct.pack(">I", 9)
        off_memrsv = 40
        off_struct = off_memrsv + 16               # one empty reserve entry
        off_strings = off_struct + len(self.struct)
        total = off_strings + len(self.strings)
        hdr = struct.pack(">10I", 0xd00dfeed, total, off_struct, off_strings,
                          off_memrsv, 17, 16, 0, len(self.strings), len(self.struct))
        return bytearray(hdr + b"\x00" * 16 + bytes(self.struct) + bytes(self.strings))


def build_fit(payload=b"KERNELPAYLOAD" * 8):
    """A FIT with one image, whose signature node is ready to be filled in."""
    f = Fdt()
    f.begin("")
    f.prop("timestamp", struct.pack(">I", 0))
    f.prop("description", b"test FIT\x00")
    f.begin("images")
    f.begin("kernel")
    f.prop("type", b"kernel\x00")
    f.prop("data-size", struct.pack(">I", len(payload)))
    f.prop("data-position", struct.pack(">I", 0))          # patched below
    f.begin("hash")
    f.prop("algo", b"sha256\x00")
    f.prop("value", hashlib.sha256(payload).digest())
    f.end()
    f.end()
    f.end()
    f.begin("configurations")
    f.prop("default", b"conf\x00")
    f.begin("conf")
    f.prop("kernel", b"kernel\x00")
    # every name used so far belongs to a hashed node; the prefix ends here
    hashed_prefix = len(f.strings)
    f.begin("signature")
    f.prop("algo", b"sha256,rsa2048\x00")
    f.prop("padding", b"pss\x00")
    f.prop("key-name-hint", b"dev\x00")
    f.prop("hashed-nodes", b"\x00".join([b"/", b"/configurations", b"/configurations/conf",
                                         b"/images/kernel", b"/images/kernel/hash"]) + b"\x00")
    f.prop("hashed-strings", struct.pack(">II", 0, hashed_prefix))
    f.prop("timestamp", struct.pack(">I", 0x5f5e100))
    f.prop("value", b"\x00" * 256)
    f.end()
    f.end()
    f.end()
    f.end()
    return f.finish() + bytearray(payload)


class Synthetic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="fitsign-test-")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def fit(self, name="t.img"):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as fh:
            fh.write(build_fit())
        return p

    def test_regions_cover_structure_and_hashed_props_only(self):
        buf = fs.read(self.fit())
        regions = fs.signed_regions(buf)
        self.assertTrue(regions)
        covered = set()
        for a, b in regions:
            covered.update(range(a, b))
        sig = fs.signature_node(buf)
        # the signature's own value must NOT be covered
        raw, off = sig["value"]
        self.assertFalse(covered & set(range(off, off + len(raw))))
        raw, off = sig["timestamp"]
        self.assertFalse(covered & set(range(off, off + len(raw))))

    def test_sign_verify_roundtrip(self):
        p = self.fit()
        self.assertEqual(fs.main(["sign", p, "--key", DEV_KEY]), 0)
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_sign_touches_only_the_value(self):
        p = self.fit()
        before = bytes(fs.read(p))
        fs.main(["sign", p, "--key", DEV_KEY])
        after = bytes(fs.read(p))
        sig = fs.signature_node(fs.read(p))
        _, off = sig["value"]
        differing = [i for i in range(len(before)) if before[i] != after[i]]
        self.assertTrue(all(off <= i < off + 256 for i in differing))

    def test_uses_max_salt_length_like_mkimage(self):
        from rkloader import load_pubkey, _mgf1
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        buf = fs.read(p)
        n = load_pubkey(DEV_PUB)[0]
        em = pow(int.from_bytes(fs.signature_node(buf)["value"][0], "big"),
                 65537, n).to_bytes(256, "big")
        db = bytes(a ^ b for a, b in zip(em[:223], _mgf1(em[223:255], 223)))
        db = bytes([db[0] & 0x7f]) + db[1:]
        i = 0
        while db[i] == 0:
            i += 1
        self.assertEqual(db[i], 0x01)
        self.assertEqual(len(db) - i - 1, fs.max_salt_len(n))

    def test_timestamp_is_outside_the_signed_region(self):
        """The reproducibility claim: normalising it must not break the signature."""
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        buf = fs.read(p)
        raw, off = fs.signature_node(buf)["timestamp"]
        buf[off:off + len(raw)] = b"\x00" * len(raw)
        fs.write_out(buf, p, None)
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_tampering_a_hashed_property_breaks_it(self):
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        buf = fs.read(p)
        raw, off = fs.fdt_props(buf)["/images/kernel/hash"]["value"]
        buf[off] ^= 0xff                       # flip a bit of the payload hash
        fs.write_out(buf, p, None)
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 2)

    def test_tampering_the_config_breaks_it(self):
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        buf = fs.read(p)
        raw, off = fs.fdt_props(buf)["/configurations/conf"]["kernel"]
        buf[off] = ord("K")
        fs.write_out(buf, p, None)
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 2)

    def test_renaming_a_node_breaks_it(self):
        """Node tokens are covered, so the tree structure is bound in."""
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        buf = fs.read(p)
        at = bytes(buf).index(b"kernel\x00")
        buf[at] = ord("K")
        fs.write_out(buf, p, None)
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 2)

    def test_digest_splice_airgap_flow(self):
        from rkloader import load_privkey
        p = self.fit()
        dpath = os.path.join(self.tmp, "d.bin")
        self.assertEqual(fs.main(["digest", p, "-o", dpath]), 0)
        digest = bytes(fs.read(dpath))
        self.assertEqual(len(digest), 32)

        n, e, d = load_privkey(DEV_KEY)
        em = fs.pss_encode(digest, n.bit_length() - 1, os.urandom(fs.max_salt_len(n)))
        spath = os.path.join(self.tmp, "s.bin")
        fs.write_out(pow(int.from_bytes(em, "big"), d, n).to_bytes(256, "big"), spath, None)
        self.assertEqual(fs.main(["splice", p, "--sig", spath, "--pubkey", DEV_PUB]), 0)
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_splice_rejects_a_bad_signature(self):
        p = self.fit()
        spath = os.path.join(self.tmp, "bad.bin")
        fs.write_out(b"\x02" * 256, spath, None)
        self.assertEqual(fs.main(["splice", p, "--sig", spath, "--pubkey", DEV_PUB]), 3)

    def test_canonical_form_is_key_and_time_independent(self):
        """Two signings of the same FIT must canonicalise to the same bytes."""
        a, b = self.fit("a.img"), self.fit("b.img")
        fs.main(["sign", a, "--key", DEV_KEY])
        fs.main(["sign", b, "--key", DEV_KEY])
        self.assertNotEqual(bytes(fs.read(a)), bytes(fs.read(b)),
                            "PSS is randomised; the raw images should differ")
        fs.main(["canonicalise", a])
        fs.main(["canonicalise", b])
        self.assertEqual(bytes(fs.read(a)), bytes(fs.read(b)))


class Artifacts(unittest.TestCase):
    def test_signed_fits_verify(self):
        images = []
        for pat in ("*signed-devkey*", "fit-sign-tree-*"):
            for d in glob.glob(os.path.join(REPO, "opt", "luckfox", "build-output", pat)):
                for name in ("uboot.img", "boot.img"):
                    p = os.path.join(d, name)
                    if os.path.isfile(p):
                        images.append(p)
        if not images:
            self.skipTest("no signed build under opt/luckfox/build-output/ (gitignored)")
        for p in images:
            with self.subTest(image=os.path.relpath(p, REPO)):
                self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
