#!/usr/bin/env python3
"""Tests for opt/luckfox/secure-boot/minisign.py.

  * Ed25519   - RFC 8032 known-answer vectors. The curve arithmetic is
    hand-rolled, so it is checked against the standard before anything else.

  * Synthetic - keygen/sign/verify/tamper, all from entropy. Runs in CI.

  * Artifact  - if a signed build is present under opt/luckfox/build-output/,
    verify the real .minisig the vendored minisign binary produced, and
    reproduce it byte-for-byte with the committed dev key. Skipped otherwise.

Run:  python3 tests/test_minisign.py
"""
import os, sys, glob, shutil, hashlib, tempfile, unittest, importlib.util

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SB = os.path.join(REPO, "opt", "luckfox", "secure-boot")
ROOTFS_KEYS = os.path.join(SB, "dev-keys-rootfs")
DEV_SEC = os.path.join(ROOTFS_KEYS, "dev.key")
DEV_PUB = os.path.join(ROOTFS_KEYS, "dev.pubkey")
DEV_PASSPHRASE = "seedsigner-dev"          # public, documented in the key's README

_spec = importlib.util.spec_from_file_location("minisign", os.path.join(SB, "minisign.py"))
ms = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ms)


class Ed25519Vectors(unittest.TestCase):
    """RFC 8032 section 7.1."""

    VECTORS = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
         "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
         "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
         "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
         "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
         "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
         "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]

    def test_public_key_derivation(self):
        for sk, pk, _, _ in self.VECTORS:
            self.assertEqual(ms.ed25519_public(bytes.fromhex(sk)).hex(), pk)

    def test_sign(self):
        for sk, _, msg, sig in self.VECTORS:
            self.assertEqual(
                ms.ed25519_sign(bytes.fromhex(sk), bytes.fromhex(msg)).hex(), sig)

    def test_verify(self):
        for _, pk, msg, sig in self.VECTORS:
            self.assertTrue(ms.ed25519_verify(bytes.fromhex(pk), bytes.fromhex(msg),
                                              bytes.fromhex(sig)))

    def test_verify_rejects_tampering(self):
        _, pk, msg, sig = self.VECTORS[1]
        bad = bytearray(bytes.fromhex(sig))
        bad[0] ^= 0x01
        self.assertFalse(ms.ed25519_verify(bytes.fromhex(pk), bytes.fromhex(msg), bytes(bad)))
        self.assertFalse(ms.ed25519_verify(bytes.fromhex(pk), b"\x73", bytes.fromhex(sig)))


class Synthetic(unittest.TestCase):
    ENTROPY = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="minisign-test-")
        cls.pub = os.path.join(cls.tmp, "k.pub")
        cls.sec = os.path.join(cls.tmp, "k.key")
        ms.main(["keygen", "--entropy", cls.ENTROPY, "-p", cls.pub, "-s", cls.sec])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def payload(self, name="img.bin", size=200000, pad=4096):
        """An image plus padding, like a real padded volume/partition."""
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(bytes((i * 7) & 0xff for i in range(size)))
            f.write(b"\xff" * pad)
        with open(p + ".size", "w") as f:
            f.write(str(size))
        return p

    def test_keygen_is_deterministic(self):
        """The whole point of BIP85: same entropy, same key, every time."""
        p2 = os.path.join(self.tmp, "again.pub")
        ms.main(["keygen", "--entropy", self.ENTROPY, "-p", p2])
        with open(self.pub) as a, open(p2) as b:
            self.assertEqual(a.read(), b.read())

    def test_keygen_rejects_wrong_entropy_length(self):
        p = os.path.join(self.tmp, "bad.pub")
        self.assertEqual(ms.main(["keygen", "--entropy", "00ff", "-p", p]), 3)

    def test_secret_key_roundtrips(self):
        k = ms.load_seckey(self.sec)
        self.assertEqual(k["pk"], ms.load_pubkey(self.pub)["pk"])
        self.assertEqual(k["key_id"], ms.load_pubkey(self.pub)["key_id"])
        self.assertEqual(ms.ed25519_public(k["seed"]), k["pk"])

    def test_sign_verify_roundtrip(self):
        p = self.payload()
        self.assertEqual(ms.main(["sign", p, "--seckey", self.sec]), 0)
        self.assertEqual(ms.main(["verify", p, "--pubkey", self.pub]), 0)

    def test_signature_is_deterministic(self):
        """Ed25519 plus a fixed trusted comment: builds stay reproducible."""
        p = self.payload("det.bin")
        a = os.path.join(self.tmp, "a.minisig")
        b = os.path.join(self.tmp, "b.minisig")
        ms.main(["sign", p, "--seckey", self.sec, "-o", a])
        ms.main(["sign", p, "--seckey", self.sec, "-o", b])
        with open(a) as fa, open(b) as fb:
            self.assertEqual(fa.read(), fb.read())

    def test_only_the_declared_size_is_signed(self):
        """Padding past <file>.size must not affect the signature."""
        p = self.payload("pad.bin")
        ms.main(["sign", p, "--seckey", self.sec])
        with open(p, "r+b") as f:            # scribble in the padding
            f.seek(200000 + 100)
            f.write(b"XXXX")
        self.assertEqual(ms.main(["verify", p, "--pubkey", self.pub]), 0)

    def test_tampering_inside_the_signed_prefix_fails(self):
        p = self.payload("tamper.bin")
        ms.main(["sign", p, "--seckey", self.sec])
        with open(p, "r+b") as f:
            f.seek(1234)
            f.write(b"\x00")
        self.assertEqual(ms.main(["verify", p, "--pubkey", self.pub]), 2)

    def test_wrong_key_fails(self):
        p = self.payload("wrong.bin")
        ms.main(["sign", p, "--seckey", self.sec])
        other = os.path.join(self.tmp, "other.pub")
        ms.main(["keygen", "--entropy", "ff" * 32, "-p", other])
        self.assertEqual(ms.main(["verify", p, "--pubkey", other]), 2)

    def test_tampering_the_trusted_comment_fails(self):
        p = self.payload("tc.bin")
        ms.main(["sign", p, "--seckey", self.sec])
        sig = p + ".minisig"
        with open(sig) as f:
            lines = f.read().splitlines()
        lines[2] = "trusted comment: something-else"
        with open(sig, "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        self.assertEqual(ms.main(["verify", p, "--pubkey", self.pub]), 2)

    def test_digest_then_sign_digest_airgap_flow(self):
        """Build host hashes; the signer only ever sees 64 bytes."""
        p = self.payload("airgap.bin")
        dpath = os.path.join(self.tmp, "d.bin")
        self.assertEqual(ms.main(["digest", p, "-o", dpath]), 0)
        with open(dpath, "rb") as f:
            self.assertEqual(len(f.read()), 64)
        sig = os.path.join(self.tmp, "airgap.minisig")
        self.assertEqual(ms.main(["sign-digest", "--digest", dpath, "--seckey", self.sec,
                                  "-o", sig]), 0)
        self.assertEqual(ms.main(["verify", p, "--pubkey", self.pub, "--sig", sig]), 0)

    def test_sign_digest_rejects_a_wrong_length_digest(self):
        dpath = os.path.join(self.tmp, "short.bin")
        with open(dpath, "wb") as f:
            f.write(b"\x00" * 32)
        self.assertEqual(ms.main(["sign-digest", "--digest", dpath, "--seckey", self.sec,
                                  "-o", os.path.join(self.tmp, "x.minisig")]), 3)


class Artifacts(unittest.TestCase):
    def _pairs(self):
        out = []
        for d in glob.glob(os.path.join(REPO, "opt", "luckfox", "build-output", "*")):
            for sig in glob.glob(os.path.join(d, "*.minisig")):
                img = sig[:-len(".minisig")]
                if os.path.isfile(img) and os.path.isfile(img + ".size"):
                    out.append(img)
        return out

    def test_real_signatures_verify(self):
        pairs = self._pairs()
        if not pairs:
            self.skipTest("no signed rootfs under opt/luckfox/build-output/ (gitignored)")
        for img in pairs:
            with self.subTest(image=os.path.relpath(img, REPO)):
                self.assertEqual(ms.main(["verify", img, "--pubkey", DEV_PUB]), 0)

    def test_reproduces_the_vendor_binary_signature(self):
        """Our signer must be byte-compatible with minisign-host, not merely valid."""
        pairs = self._pairs()
        if not pairs:
            self.skipTest("no signed rootfs under opt/luckfox/build-output/ (gitignored)")
        img = pairs[0]
        try:
            ms.load_seckey(DEV_SEC, DEV_PASSPHRASE)
        except ms.MsError as e:
            self.skipTest("cannot decrypt the dev key here (scrypt needs ~1 GiB): %s" % e)
        tmp = tempfile.mkdtemp(prefix="minisign-repro-")
        try:
            out = os.path.join(tmp, "out.minisig")
            self.assertEqual(ms.main(["sign", img, "--seckey", DEV_SEC,
                                      "--passphrase", DEV_PASSPHRASE, "-o", out]), 0)
            with open(out, "rb") as a, open(img + ".minisig", "rb") as b:
                self.assertEqual(a.read(), b.read())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
