#!/usr/bin/env python3
"""Tests for opt/luckfox/secure-boot/rkloader.py.

Two layers:

  * Synthetic - builds a container in memory from the committed public dev key
    and exercises sign/verify/splice/setkey plus the negative cases. Runs
    anywhere, including CI, and needs nothing but the repo.

  * Artifact   - if a signed build happens to be present under
    opt/luckfox/build-output/, every download.bin / idblock.img in it is
    verified against the committed dev pubkey. Skipped when absent, because
    build-output/ is gitignored.

Run:  python3 tests/test_rkloader.py
"""
import os, sys, glob, struct, hashlib, shutil, tempfile, unittest, importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SB = os.path.join(REPO, "opt", "luckfox", "secure-boot")
DEV_KEY = os.path.join(SB, "dev-keys", "dev.key")
DEV_PUB = os.path.join(SB, "dev-keys", "dev.pubkey")

_spec = importlib.util.spec_from_file_location("rkloader", os.path.join(SB, "rkloader.py"))
rk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rk)


def make_container(modulus, hdr_off=0x0, filler=b"\xa5"):
    """A minimal RKNS container with `modulus` embedded where the real one sits."""
    buf = bytearray(filler * (hdr_off + rk.HDR_LEN + rk.SIG_LEN + 0x40))
    buf[hdr_off:hdr_off + 4] = rk.MAGIC_UNSIGNED
    struct.pack_into("<I", buf, hdr_off + 0x0c, 0x01)
    buf[hdr_off + rk.MOD_OFF:hdr_off + rk.MOD_OFF + rk.SIG_LEN] = modulus.to_bytes(rk.SIG_LEN, "little")
    buf[hdr_off + rk.HDR_LEN:hdr_off + rk.HDR_LEN + rk.SIG_LEN] = b"\x00" * rk.SIG_LEN
    return buf


class Synthetic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.n, cls.e, cls.d = rk.load_privkey(DEV_KEY)
        cls.tmp = tempfile.mkdtemp(prefix="rkloader-test-")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def path(self, name, hdr_off=0x0):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(make_container(self.n, hdr_off))
        return p

    def test_pubkey_matches_privkey(self):
        self.assertEqual(rk.load_pubkey(DEV_PUB)[0], self.n,
                         "committed dev.key and dev.pubkey disagree")

    def test_layout_idblock_and_loader(self):
        for name, off, sig_at in (("idblock.img", 0x0, 0x600), ("download.bin", 0x1bc, 0x7bc)):
            buf = bytearray(open(self.path(name, off), "rb").read())
            lay = rk.layout(buf)
            self.assertEqual(lay["hdr"], off)
            self.assertEqual(lay["sig"][0], sig_at)
            self.assertFalse(lay["signed"])

    def test_sign_verify_roundtrip(self):
        for off in (0x0, 0x1bc):
            p = self.path("rt.bin", off)
            self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
            self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)
            buf = rk.read(p)
            self.assertTrue(rk.layout(buf)["signed"], "magic was not flipped to RKSS")

    def test_sign_touches_only_the_signature(self):
        p = self.path("only-sig.bin")
        before = bytes(rk.read(p))
        rk.main(["sign", p, "--key", DEV_KEY])
        after = bytes(rk.read(p))
        self.assertEqual(len(before), len(after))
        differing = [i for i in range(len(before)) if before[i] != after[i]]
        # the 256 signature bytes, plus the magic and the flag word in the header
        self.assertTrue(all(i >= rk.HDR_LEN or i < 0x10 for i in differing), differing[:8])

    def test_signature_is_stored_little_endian(self):
        p = self.path("endian.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        buf = rk.read(p)
        lay = rk.layout(buf)
        raw = bytes(buf[lay["sig"][0]:lay["sig"][0] + rk.SIG_LEN])
        mhash = rk.msg_digest(buf, lay)
        self.assertTrue(rk.rsa_verify_digest(mhash, int.from_bytes(raw, "little"), self.n))
        self.assertFalse(rk.rsa_verify_digest(mhash, int.from_bytes(raw, "big"), self.n))

    def test_salt_length_is_32(self):
        mhash = hashlib.sha256(b"x").digest()
        em = pow(int.from_bytes(rk.rsa_sign_digest(mhash, self.n, self.d), "little"),
                 self.e, self.n).to_bytes(rk.SIG_LEN, "big")
        masked, h = em[:223], em[223:255]
        db = bytes(a ^ b for a, b in zip(masked, rk._mgf1(h, 223)))
        db = bytes([db[0] & 0x7f]) + db[1:]
        i = 0
        while db[i] == 0:
            i += 1
        self.assertEqual(db[i], 0x01)
        self.assertEqual(len(db) - i - 1, rk.SALT_LEN)

    def test_tampered_header_fails(self):
        p = self.path("tamper.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        buf = rk.read(p)
        buf[0x100] ^= 0xff                      # one bit inside the signed header
        rk.write_out(buf, p, None)
        self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 2)

    def test_byte_outside_header_does_not_break_signature(self):
        """Only [hdr, hdr+0x600) is covered - prove the boundary is where we claim."""
        p = self.path("outside.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        buf = rk.read(p)
        buf[rk.HDR_LEN + rk.SIG_LEN + 0x10] ^= 0xff
        rk.write_out(buf, p, None)
        self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_wrong_key_fails(self):
        p = self.path("wrongkey.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        buf = rk.read(p)
        lay = rk.layout(buf)
        other = self.n ^ (1 << 300)             # a modulus that is not ours
        buf[lay["mod"][0]:lay["mod"][0] + rk.SIG_LEN] = other.to_bytes(rk.SIG_LEN, "little")
        rk.write_out(buf, p, None)
        self.assertEqual(rk.main(["verify", p]), 2)

    def test_digest_splice_airgap_flow(self):
        """The real air-gapped path: digest out, sign elsewhere, splice back."""
        p = self.path("airgap.bin")
        dpath = os.path.join(self.tmp, "d.bin")
        self.assertEqual(rk.main(["digest", p, "-o", dpath]), 0)
        digest = bytes(rk.read(dpath))
        self.assertEqual(len(digest), 32)
        buf = rk.read(p)
        self.assertEqual(digest, rk.signing_digest(buf, rk.layout(buf)),
                         "digest must cover the header in its marked (RKSS) form")

        spath = os.path.join(self.tmp, "s.bin")          # "elsewhere"
        rk.write_out(rk.rsa_sign_digest(digest, self.n, self.d), spath, None)
        self.assertEqual(rk.main(["splice", p, "--sig", spath]), 0)
        self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_splice_rejects_a_bad_signature(self):
        p = self.path("badsplice.bin")
        spath = os.path.join(self.tmp, "bad.bin")
        open(spath, "wb").write(b"\x01" * rk.SIG_LEN)
        self.assertEqual(rk.main(["splice", p, "--sig", spath]), 3)

    def test_setkey_then_sign(self):
        p = self.path("setkey.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        self.assertEqual(rk.main(["setkey", p, "--pubkey", DEV_PUB]), 0)
        buf = rk.read(p)
        self.assertEqual(rk.read_modulus(buf, rk.layout(buf)), self.n)
        self.assertEqual(rk.read_sig(buf, rk.layout(buf)), 0, "old signature not cleared")
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)


class Artifacts(unittest.TestCase):
    """Verify real signed build output, when a build happens to be present."""

    def test_signed_artifacts_verify(self):
        pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*signed-devkey*")
        images = []
        for d in glob.glob(pat):
            for name in ("download.bin", "idblock.img"):
                p = os.path.join(d, name)
                if os.path.isfile(p):
                    images.append(p)
        if not images:
            self.skipTest("no signed build under opt/luckfox/build-output/ (gitignored)")
        for p in images:
            with self.subTest(image=os.path.relpath(p, REPO)):
                self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
