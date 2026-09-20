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
    f.prop("data-position", struct.pack(">I", 0))          # patched in build_fit
    f.begin("hash")
    f.prop("algo", b"sha256\x00")
    f.prop("value", hashlib.sha256(payload).digest())
    f.end()
    # Rockchip's sibling node: same algo, but it holds the hash of the
    # DECOMPRESSED payload, so `rehash` must leave it alone.
    f.begin("digest")
    f.prop("algo", b"sha256\x00")
    f.prop("value", bytes(range(32)))
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
    blob = f.finish()
    # The payload is stored externally, right after the FDT (mkimage -E), so
    # data-position is only knowable once the FDT is built. Patch it in place.
    buf = blob + bytearray(payload)
    _, off = fs.fdt_props(buf)["/images/kernel"]["data-position"]
    struct.pack_into(">I", buf, off, len(blob))
    return buf


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

    def test_sign_touches_only_value_and_timestamp(self):
        p = self.fit()
        before = bytes(fs.read(p))
        fs.main(["sign", p, "--key", DEV_KEY])
        after = bytes(fs.read(p))
        sig = fs.signature_node(fs.read(p))
        _, voff = sig["value"]
        _, toff = sig["timestamp"]
        differing = [i for i in range(len(before)) if before[i] != after[i]]
        # the 256 signature bytes, plus the wall-clock timestamp zeroed for
        # reproducibility - both outside the signed region
        self.assertTrue(all((voff <= i < voff + 256) or (toff <= i < toff + 4)
                            for i in differing), differing[:8])

    def test_sign_zeroes_a_wall_clock_timestamp(self):
        """build_fit() plants 0x5f5e100 where mkimage would stamp time(NULL)."""
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        buf = fs.read(p)
        raw, off = fs.signature_node(buf)["timestamp"]
        self.assertEqual(raw, b"\x00" * 4, "the wall-clock timestamp must be zeroed")
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_signing_is_byte_reproducible(self):
        """Same FIT + same key => byte-identical output (digest-derived salt)."""
        a, b = self.fit("ra.img"), self.fit("rb.img")
        fs.main(["sign", a, "--key", DEV_KEY])
        fs.main(["sign", b, "--key", DEV_KEY])
        self.assertEqual(bytes(fs.read(a)), bytes(fs.read(b)))

    def _garbage_pad(self, path, seed):
        """Plant uninitialised-heap-style garbage in the FDT pad after the
        signature node's hashed-nodes value - what mkimage leaves behind when
        libfdt grows the structure block into a fresh malloc()."""
        buf = fs.read(path)
        raw, off = fs.fdt_props(buf)["/configurations/conf/signature"]["hashed-nodes"]
        end = (off + len(raw) + 3) & ~3          # pad up to the next token
        self.assertGreater(end - (off + len(raw)), 0, "test FIT needs a padded prop")
        buf[off + len(raw):end] = bytes([seed, seed + 1, seed + 2][: end - off - len(raw)])
        fs.write_out(buf, path, None)

    def test_sign_zeroes_uninitialised_fdt_padding(self):
        p = self.fit()
        self._garbage_pad(p, 0xd9)
        self.assertEqual(fs.main(["sign", p, "--key", DEV_KEY]), 0)
        buf = fs.read(p)
        raw, off = fs.fdt_props(buf)["/configurations/conf/signature"]["hashed-nodes"]
        end = (off + len(raw) + 3) & ~3
        self.assertEqual(bytes(buf[off + len(raw):end]), b"\x00" * (end - off - len(raw)))
        self.assertEqual(fs.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_signing_is_byte_reproducible_despite_garbage_pads(self):
        """Two builds of the same FIT differ only in mkimage's heap garbage;
        signing must canonicalise them to identical bytes."""
        a, b = self.fit("pg-a.img"), self.fit("pg-b.img")
        self._garbage_pad(a, 0xd9)
        self._garbage_pad(b, 0x94)
        fs.main(["sign", a, "--key", DEV_KEY])
        fs.main(["sign", b, "--key", DEV_KEY])
        self.assertEqual(bytes(fs.read(a)), bytes(fs.read(b)))

    def test_canonicalise_zeroes_fdt_padding(self):
        """A vendor-signed image carries the heap garbage; canonicalise must
        clear it so two builds compare equal."""
        p = self.fit()
        fs.main(["sign", p, "--key", DEV_KEY])
        self._garbage_pad(p, 0x7b)              # re-plant it post-signing
        self.assertEqual(fs.main(["canonicalise", p]), 0)
        buf = bytes(fs.read(p))
        raw, off = fs.fdt_props(buf)["/configurations/conf/signature"]["hashed-nodes"]
        end = (off + len(raw) + 3) & ~3
        self.assertEqual(bytes(buf[off + len(raw):end]), b"\x00" * (end - off - len(raw)))

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
        # signing is now deterministic (digest-derived salt + zeroed timestamp),
        # so the raw images already agree; canonicalise must still hold
        self.assertEqual(bytes(fs.read(a)), bytes(fs.read(b)))
        fs.main(["canonicalise", a])
        fs.main(["canonicalise", b])
        self.assertEqual(bytes(fs.read(a)), bytes(fs.read(b)))


class Rehash(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="fitsign-rehash-")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def fit(self, name="r.img"):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as fh:
            fh.write(build_fit())
        return p

    def test_rehash_leaves_a_correct_hash_alone(self):
        p = self.fit()
        before = bytes(fs.read(p))
        self.assertEqual(fs.main(["rehash", p]), 0)
        self.assertEqual(before, bytes(fs.read(p)))

    def test_rehash_fixes_a_stale_hash(self):
        p = self.fit()
        buf = fs.read(p)
        _, off = fs.fdt_props(buf)["/images/kernel/hash"]["value"]
        buf[off] ^= 0xff
        fs.write_out(buf, p, None)
        self.assertEqual(fs.main(["rehash", p]), 0)
        buf = fs.read(p)
        pos, size, _ = fs._image_payloads(buf)["kernel"]
        want = hashlib.sha256(bytes(buf[pos:pos + size])).digest()
        self.assertEqual(fs.fdt_props(buf)["/images/kernel/hash"]["value"][0], want)

    def test_rehash_never_touches_the_rockchip_digest_node(self):
        """It holds the DECOMPRESSED payload hash; rewriting it would brick boot."""
        p = self.fit()
        buf = fs.read(p)
        _, off = fs.fdt_props(buf)["/images/kernel/hash"]["value"]
        buf[off] ^= 0xff                      # force rehash to do some work
        fs.write_out(buf, p, None)
        self.assertEqual(fs.main(["rehash", p]), 0)
        self.assertEqual(fs.fdt_props(fs.read(p))["/images/kernel/digest"]["value"][0],
                         bytes(range(32)))


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
