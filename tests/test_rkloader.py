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

# fitsign imports rkloader by name from its own directory; loading it here gives
# the tests a second (independent) instance, which is fine for fdt_props.
_fspec = importlib.util.spec_from_file_location("fitsign", os.path.join(SB, "fitsign.py"))
fs = importlib.util.module_from_spec(_fspec)
sys.modules["rkloader"] = rk                      # let fitsign reuse THIS instance
_fspec.loader.exec_module(fs)


def make_container(modulus, hdr_off=0x0, filler=b"\xa5", ldr=False):
    """A minimal RKNS container with `modulus` embedded where the real one sits.

    With ldr=True it is shaped like download.bin: an 'LDR ' tag at 0x0 and a
    valid trailer CRC over everything before its last 4 bytes.
    """
    buf = bytearray(filler * (hdr_off + rk.HDR_LEN + rk.SIG_LEN + 0x40))
    if ldr:
        buf[0:4] = rk.LDR_TAG
    buf[hdr_off:hdr_off + 4] = rk.MAGIC_UNSIGNED
    struct.pack_into("<I", buf, hdr_off + 0x0c, 0x01)
    # the whole key block (N, E, C) as the vendor tools write it, not just N
    if modulus:
        rk.write_key_block(buf, hdr_off, modulus)
    buf[hdr_off + rk.HDR_LEN:hdr_off + rk.HDR_LEN + rk.SIG_LEN] = b"\x00" * rk.SIG_LEN
    if ldr:
        rk.refresh_ldr_trailer(buf)
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


class DeterministicSalt(unittest.TestCase):
    """The PSS salt is derived from the digest, not drawn at random.

    RFC 8017 accepts any salt and verification recovers it from the block, so
    this changes nothing on-device - but two signings of the same message with
    the same key are now byte-identical, which is what makes a signed build (and
    an on-device re-sign) reproducible. The vendor tools do neither: their FIT
    signing stamps wall-clock time and draws random salts.
    """

    @classmethod
    def setUpClass(cls):
        cls.n, cls.e, cls.d = rk.load_privkey(DEV_KEY)
        cls.tmp = tempfile.mkdtemp(prefix="rkloader-det-")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_salt_is_the_documented_derivation(self):
        mhash = hashlib.sha256(b"reproducible").digest()
        self.assertEqual(rk.deterministic_salt(mhash, rk.SALT_LEN),
                         hashlib.shake_256(b"seedsigner-pss-v1\0" + mhash).digest(rk.SALT_LEN))

    def test_signing_is_byte_reproducible(self):
        p = os.path.join(self.tmp, "det.bin")
        with open(p, "wb") as f:
            f.write(make_container(self.n))
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        first = bytes(rk.read(p))
        # re-sign in place (idempotent), then from a fresh copy of the input
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        self.assertEqual(bytes(rk.read(p)), first, "re-signing must be byte-identical")
        with open(p, "wb") as f:
            f.write(make_container(self.n))
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        self.assertEqual(bytes(rk.read(p)), first, "fresh input + sign must match the first")

    def test_pinned_signature_vector_for_the_dev_key(self):
        """Any change to the salt derivation (or key handling) shifts these bytes."""
        mhash = hashlib.sha256(b"seedsigner-os-rootfs").digest()
        self.assertEqual(rk.deterministic_salt(mhash, rk.SALT_LEN).hex(),
                         "5fa88d7779d06b9feb20642fe2c1f60739d011f53692d4fe61f36a1cf4145b50")
        sig = rk.rsa_sign_digest(mhash, self.n, self.d)
        self.assertEqual(sig.hex(),
                         "a0009d0ea5c4ea89b22f98a7da9b657d6ba9de61d7d3924cfe0f04f0e65df01"
                         "1652712d23d749c25ae07eefbcfc80fe6f824382646a88a1d9710d9626b0df"
                         "1d514c253faf74fba4621ef7ebbe459883568431080f0f53c68b76e502d8258"
                         "669f5596e8edd7d96d1478756d3b60d6da6416e3acccab4e93147c2a9ed595c"
                         "b1f5fed9910c615b0732b674e41b5c1bc484af2fcb277c8e97311ef63967ad0"
                         "ac17622129999a1a7d20d52dbd0b6d23439a1b35791ad2e7f40d5fa5bd3036c"
                         "6ea40b78778fd76ad0ec65e0c0a15eafcd6eb367380aebe1f21a78e03c5c97e"
                         "446a12276c1841c3f2a3a03502d789ba7f320ce6de36321e109736f738eecb2"
                         "5adb2c612")
        self.assertTrue(rk.rsa_verify_digest(mhash, int.from_bytes(sig, "little"), self.n))

    def test_explicit_salt_still_overrides(self):
        mhash = hashlib.sha256(b"x").digest()
        em1 = rk.pss_encode(mhash, 2047, b"\x00" * rk.SALT_LEN)
        em2 = rk.pss_encode(mhash, 2047, b"\x00" * rk.SALT_LEN)
        self.assertEqual(em1, em2)
        self.assertNotEqual(em1, rk.pss_encode(mhash, 2047))


def make_key_dtb(n):
    """A minimal Rockchip-style FDT whose /signature/key-dev carries rsa,np and a
    hash@np subnode for modulus n - shaped like the SPL DTB's key node, so
    swap_pka_constants can be exercised without a real image."""
    np_be = rk.pka_barrett_np(n).to_bytes(rk.SIG_LEN, "big")
    hval = rk.burn_key_hash(n.to_bytes(rk.SIG_LEN, "big"))

    strings = bytearray(b"\x00")                    # index 0: the empty root name
    def s(name):
        off = len(strings)
        strings.extend(name.encode() + b"\x00")
        return off
    np_off, value_off, algo_off = s("rsa,np"), s("value"), s("sha256")

    sb = bytearray()
    def begin(name):                                 # FDT_BEGIN_NODE: inline name
        sb.extend(struct.pack(">I", 1) + name.encode() + b"\x00")
        while len(sb) & 3:
            sb.append(0)
    def end():                                       # FDT_END_NODE
        sb.extend(struct.pack(">I", 2))
    def prop(off, data):                             # FDT_PROP: token, len, nameoff
        sb.extend(struct.pack(">III", 3, len(data), off) + data)
        while len(sb) & 3:
            sb.append(0)

    begin("")
    begin("signature")
    begin("key-dev")
    prop(np_off, np_be)
    begin("hash@np")
    prop(value_off, hval)
    prop(algo_off, b"sha256\x00")
    end()                                            # hash@np
    end()                                            # key-dev
    end()                                            # signature
    end()                                            # root
    sb.extend(struct.pack(">I", 9))                  # FDT_END

    off_struct = 48                                  # after the 40-byte header + memrsv terminator
    off_strings = (off_struct + len(sb) + 7) & ~7
    out = bytearray(b"\x00" * off_strings)
    out[off_struct:off_struct + len(sb)] = bytes(sb)
    out[off_strings:off_strings + len(strings)] = bytes(strings)
    totalsize = (off_strings + len(strings) + 7) & ~7
    out += b"\x00" * (totalsize - len(out))
    struct.pack_into(">10I", out, 0, 0xd00dfeed, totalsize, off_struct, off_strings,
                     40, 17, 2, 0, len(strings), len(sb))
    return bytes(out)


class PkaConstants(unittest.TestCase):
    """The SKE engine's Barrett constant (rsa,np) and the OTP burn pin (hash@np).

    Both derive from the modulus; a re-key that misses them boots nothing on an
    HW-crypto build. The vectors below are the values Rockchip's mkimage wrote
    for the committed dev key, read out of a real signed bundle.
    """

    @classmethod
    def setUpClass(cls):
        cls.n, cls.e, cls.d = rk.load_privkey(DEV_KEY)

    def test_pka_barrett_np_dev_vector(self):
        self.assertEqual(rk.pka_barrett_np(self.n), 0x16b191f2eef44b9feb56150865d210487b)

    def test_burn_key_hash_dev_vector(self):
        self.assertEqual(
            rk.burn_key_hash(self.n.to_bytes(rk.SIG_LEN, "big")).hex(),
            "64e4b04fb827d85edc5dee2c6510f104af65e4be5fdab257b3ecc43968449b3c")

    def test_swap_pka_constants_roundtrip(self):
        other_n = self.n ^ (1 << 500)                # a different "key"
        buf = bytearray(make_key_dtb(self.n))
        hits = rk.swap_pka_constants(buf, self.n, other_n)
        self.assertEqual(hits, 2, "np and hash@np must both be rewritten")

        props = fs.fdt_props(bytearray(buf))
        k = props["/signature/key-dev"]
        self.assertEqual(k["rsa,np"][0], rk.pka_barrett_np(other_n).to_bytes(rk.SIG_LEN, "big"))
        self.assertEqual(props["/signature/key-dev/hash@np"]["value"][0],
                         rk.burn_key_hash(other_n.to_bytes(rk.SIG_LEN, "big")))

    def test_swap_pka_constants_is_a_noop_without_the_fields(self):
        buf = bytearray(b"\xa5" * 1024)
        self.assertEqual(rk.swap_pka_constants(buf, self.n, self.n ^ (1 << 500)), 0)


class LdrTrailer(unittest.TestCase):
    """download.bin's trailer CRC: boot_merger writes it, the flashing tools check it."""

    @classmethod
    def setUpClass(cls):
        cls.n, cls.e, cls.d = rk.load_privkey(DEV_KEY)
        cls.tmp = tempfile.mkdtemp(prefix="rkloader-ldr-")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def path(self, name, ldr=True):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(make_container(self.n, hdr_off=0x1bc, ldr=ldr))
        return p

    def test_crc_matches_boot_merger_on_a_real_image(self):
        """The polynomial is 0x04C10DB7, not the standard one - prove it against a
        shipped download.bin, whose trailer boot_merger itself wrote."""
        real = None
        for d in glob.glob(os.path.join(REPO, "opt", "luckfox", "build-output", "*")):
            p = os.path.join(d, "download.bin")
            if os.path.isfile(p):
                real = p
                break
        if not real:
            self.skipTest("no signed build under opt/luckfox/build-output/")
        buf = rk.read(real)
        self.assertTrue(rk.is_ldr(buf))
        stored = struct.unpack_from("<I", bytes(buf), len(buf) - 4)[0]
        self.assertEqual(stored, rk.ldr_crc32(bytes(buf[:-4])))
        import zlib
        self.assertNotEqual(stored, zlib.crc32(bytes(buf[:-4])) & 0xFFFFFFFF,
                            "standard CRC-32 must NOT match - wrong polynomial")

    def test_sign_refreshes_the_trailer(self):
        p = self.path("sign.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        buf = rk.read(p)
        self.assertTrue(rk.ldr_trailer_ok(buf))

    def test_setkey_and_splice_refresh_the_trailer(self):
        p = self.path("splice.bin")
        dpath = os.path.join(self.tmp, "d.bin")
        spath = os.path.join(self.tmp, "s.bin")
        rk.main(["digest", p, "-o", dpath])
        rk.write_out(rk.rsa_sign_digest(bytes(rk.read(dpath)), self.n, self.d), spath, None)
        rk.main(["splice", p, "--sig", spath])
        self.assertTrue(rk.ldr_trailer_ok(rk.read(p)))

    def test_tampered_body_is_detected(self):
        p = self.path("tamper.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        buf = rk.read(p)
        buf[0x10] ^= 0xff                       # inside the LDR wrapper, outside the header
        self.assertFalse(rk.ldr_trailer_ok(buf))

    def test_non_ldr_images_have_no_trailer(self):
        p = self.path("raw.bin", ldr=False)
        buf = rk.read(p)
        before = bytes(buf)
        self.assertIsNone(rk.ldr_trailer_ok(buf))
        self.assertFalse(rk.refresh_ldr_trailer(buf), "must not touch a non-LDR image")
        self.assertEqual(bytes(buf), before)


def make_flashhead_container(modulus, inner_size=0x800):
    """A download.bin-shaped buffer: LDR tag, outer RKNS header at 0x1bc whose
    second component entry ends where the RC4-obfuscated region begins, and an
    encrypted inner image (RKSS header + zeroed signature) in that region.

    The inner image has empty component entries, so components_ok() passes on
    it without needing real SPL/DTB content. inner_size must be a multiple of
    the 512-byte RC4 chunk size or flashhead_region() refuses to find it.
    """
    hdr = 0x1bc
    # outer comp2 entry: sectors 4..(4+inner_size//512) -> region starts at
    # hdr + (4 + inner_size//512)*512
    start_s, count_s = 4, inner_size // rk.FLASHHEAD_CHUNK
    region_start = hdr + (start_s + count_s) * rk.SECTOR
    total = region_start + inner_size + 4
    buf = bytearray(b"\xa5" * total)
    buf[0:4] = rk.LDR_TAG
    buf[hdr:hdr + 4] = rk.MAGIC_UNSIGNED
    struct.pack_into("<I", buf, hdr + 0x0c, 0x01)
    struct.pack_into("<HH", buf, hdr + 0x0d0, start_s, count_s)
    rk.write_key_block(buf, hdr, modulus)

    inner = bytearray(b"\xa5" * inner_size)
    inner[0:4] = rk.MAGIC_SIGNED
    struct.pack_into("<I", inner, 0x0c, 0x11)
    rk.write_key_block(inner, 0, modulus)
    buf[region_start:region_start + inner_size] = rk._flashhead_xor(bytes(inner))
    rk.refresh_ldr_trailer(buf)
    return buf


class Flashhead(unittest.TestCase):
    """The RC4-obfuscated embedded loader image inside download.bin.

    rk_sign_tool signs its inner header with a random PSS salt on every build;
    resign_flashhead() re-signs it with the digest-derived salt so two builds
    of the same commit are byte-identical end to end.
    """

    @classmethod
    def setUpClass(cls):
        cls.n, cls.e, cls.d = rk.load_privkey(DEV_KEY)
        cls.tmp = tempfile.mkdtemp(prefix="rkloader-fh-")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def path(self, name, buf=None):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(buf if buf is not None else make_flashhead_container(self.n))
        return p

    def test_rc4_keystream_pinned_vector(self):
        """Any change to the key or the per-chunk scheme shifts these bytes."""
        ks = rk.rc4_keystream(rk.FLASHHEAD_KEY, 512)
        self.assertEqual(ks[:32].hex(),
                         "6e262cf3be9f9d51ea3034ce20511f98"
                         "ff0cf2360550c8bb3fecddbd0685fab7")
        self.assertEqual(ks[-16:].hex(), "4458d1d5ea04c36b918d6f931c282745")

    def test_xor_roundtrip_and_chunk_reinit(self):
        data = bytes(range(256)) * 4                      # 1 KiB, two chunks
        self.assertEqual(rk._flashhead_xor(rk._flashhead_xor(data)), data)
        ks = rk.rc4_keystream(rk.FLASHHEAD_KEY, rk.FLASHHEAD_CHUNK)
        pt = bytes(c ^ k for c, k in zip(data[:16], ks))
        self.assertEqual(rk._flashhead_xor(pt + b"\x00" * 512)[:16], data[:16])

    def test_region_is_derived_from_the_component_table(self):
        buf = make_flashhead_container(self.n)
        reg = rk.flashhead_region(buf)
        self.assertIsNotNone(reg)
        start, size = reg
        lay = rk.layout(buf)
        s, c = struct.unpack_from("<HH", bytes(buf), lay["hdr"] + 0x0d0)
        self.assertEqual(start, lay["hdr"] + (s + c) * rk.SECTOR)
        self.assertEqual(size, len(buf) - 4 - start)

    def test_no_flashhead_in_plain_idblock(self):
        buf = make_container(self.n)                      # no LDR tag, no comp2
        self.assertIsNone(rk.flashhead_region(bytearray(buf)))
        self.assertFalse(rk.resign_flashhead(bytearray(buf), self.n, self.d))

    def test_sign_resigns_the_inner_header_deterministically(self):
        p = self.path("fh-det.bin")
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        first = bytes(rk.read(p))
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        self.assertEqual(bytes(rk.read(p)), first, "re-signing must be byte-identical")

    def test_verify_checks_the_inner_signature(self):
        p = self.path("fh-verify.bin")
        self.assertEqual(rk.main(["sign", p, "--key", DEV_KEY]), 0)
        self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)
        buf = rk.read(p)
        reg = rk.flashhead_region(buf)
        pt = bytearray(rk._flashhead_xor(bytes(buf[reg[0]:reg[0] + reg[1]])))
        pt[0x100] ^= 0xff                                 # inside the inner signed header
        buf[reg[0]:reg[0] + reg[1]] = rk._flashhead_xor(bytes(pt))
        rk.refresh_ldr_trailer(buf)                       # isolate: only the inner sig may fail
        rk.write_out(buf, p, None)
        self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 2)

    def test_setkey_updates_the_inner_modulus(self):
        """Regression: the inner header embeds its own copy of the modulus,
        RC4-obfuscated beyond the byte searches - a re-key that misses it
        verifies here and fails on device."""
        p = self.path("fh-setkey.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        other_n = self.n ^ (1 << 500)
        buf = rk.read(p)
        lay = rk.layout(buf)
        rk.set_pubkey(buf, lay, other_n)
        reg = rk.flashhead_region(buf)
        pt = bytearray(rk._flashhead_xor(bytes(buf[reg[0]:reg[0] + reg[1]])))
        self.assertEqual(int.from_bytes(pt[rk.MOD_OFF:rk.MOD_OFF + rk.SIG_LEN], "little"), other_n,
                         "inner modulus was not re-keyed")

    def test_canonicalise_zeroes_the_inner_key_fields(self):
        p = self.path("fh-canon.bin")
        rk.main(["sign", p, "--key", DEV_KEY])
        self.assertEqual(rk.main(["canonicalise", p]), 0)
        buf = rk.read(p)
        reg = rk.flashhead_region(buf)
        pt = bytearray(rk._flashhead_xor(bytes(buf[reg[0]:reg[0] + reg[1]])))
        self.assertEqual(pt[rk.HDR_LEN:rk.HDR_LEN + rk.SIG_LEN], b"\x00" * rk.SIG_LEN)
        self.assertEqual(pt[rk.MOD_OFF:rk.MOD_OFF + rk.SIG_LEN], b"\x00" * rk.SIG_LEN)


class Components(unittest.TestCase):
    """The component table: sha256s inside the header covering the rest.

These need a real image, because the header's component entries point at the
SPL and its DTB. A synthetic container has an empty table.
"""

    def setUp(self):
        self.src = None
        for d in glob.glob(os.path.join(REPO, "opt", "luckfox", "build-output",
                                        "*signed-devkey*")):
            p = os.path.join(d, "idblock.img")
            if os.path.isfile(p):
                self.src = p
                break
        if not self.src:
            self.skipTest("no signed build under opt/luckfox/build-output/")
        self.tmp = tempfile.mkdtemp(prefix="rkloader-comp-")
        self.img = os.path.join(self.tmp, "idblock.img")
        shutil.copyfile(self.src, self.img)

    def tearDown(self):
        shutil.rmtree(getattr(self, "tmp", ""), ignore_errors=True)

    def test_shipped_image_has_valid_components(self):
        buf = rk.read(self.img)
        table = rk.component_table(buf, rk.layout(buf))
        self.assertEqual(len(table), 2)
        self.assertTrue(rk.components_ok(buf, rk.layout(buf)))

    def test_tampering_a_component_is_caught(self):
        buf = rk.read(self.img)
        a, _b, _h, _s, _act = rk.component_table(buf, rk.layout(buf))[1]
        buf[a + 16] ^= 0xff
        rk.write_out(buf, self.img, None)
        self.assertEqual(rk.main(["verify", self.img, "--pubkey", DEV_PUB]), 2)

    def test_setkey_then_sign_leaves_components_valid(self):
        """Regression: set_pubkey rewrites the modulus INSIDE a hashed component.

        Re-signing the header alone produced an image whose signature verified
        and whose components did not - valid to every check here, rejected by
        the SPL at boot.
        """
        n, e, d = rk.load_privkey(DEV_KEY)
        other_n = n ^ (1 << 500)                    # a different "key"
        buf = rk.read(self.img)
        lay = rk.layout(buf)
        rk.set_pubkey(buf, lay, other_n)
        self.assertFalse(rk.components_ok(buf, lay),
                         "set_pubkey should have invalidated a component hash")
        rk.sign_buf(buf, lay, n, d)                 # must refresh them
        self.assertTrue(rk.components_ok(buf, lay))

    def test_setburn_arms_and_keeps_everything_valid(self):
        buf = rk.read(self.img)
        self.assertFalse(rk.is_burn_armed(buf))
        self.assertEqual(rk.main(["setburn", self.img]), 1, "must refuse without --confirm")

        self.assertEqual(rk.main(["setburn", self.img, "--confirm", rk.CONFIRM_TOKEN]), 0)
        armed = rk.read(self.img)
        self.assertTrue(rk.is_burn_armed(armed))
        self.assertEqual(len(armed), os.path.getsize(self.src),
                         "the file length must not change")
        self.assertEqual(rk.main(["sign", self.img, "--key", DEV_KEY]), 0)
        self.assertEqual(rk.main(["verify", self.img, "--pubkey", DEV_PUB]), 0)

    def test_setburn_matches_a_real_burnable_build(self):
        """The armed DTB must be byte-identical to what the SDK emits."""
        ref = None
        for d in glob.glob(os.path.join(REPO, "opt", "luckfox", "build-output",
                                        "*burnable*")):
            p = os.path.join(d, "idblock.img")
            if os.path.isfile(p):
                ref = p
                break
        if not ref:
            self.skipTest("no SEEDSIGNER_FIT_BURN_KEY_HASH=1 build to compare against")
        rk.main(["setburn", self.img, "--confirm", rk.CONFIRM_TOKEN])
        mine, sdk = rk.read(self.img), rk.read(ref)
        mo, msz = rk.find_spl_dtb(mine)
        so, ssz = rk.find_spl_dtb(sdk)
        self.assertEqual(bytes(mine[mo:mo + msz]), bytes(sdk[so:so + ssz]))

    def test_shipped_spl_dtb_carries_matching_pka_constants(self):
        """The SPL DTB's rsa,np / hash@np must match the embedded modulus.

        This pins pka_barrett_np() and burn_key_hash() against what Rockchip's
        mkimage actually writes: if either formula drifts, re-keyed loaders will
        fail on-device with "invalid pss padding (0xbc is missing)" or refuse to
        burn the key hash.
        """
        buf = rk.read(self.img)
        loc = rk.find_spl_dtb(buf)
        self.assertIsNotNone(loc, "no SPL DTB in the shipped idblock")
        off, size = loc
        props = fs.fdt_props(bytearray(bytes(buf[off:off + size])))
        keys = [p for p in props if p.startswith("/signature/key-")]
        self.assertTrue(keys)
        k = props[keys[0]]
        n_be = k["rsa,modulus"][0]
        n = int.from_bytes(n_be, "big")
        self.assertEqual(k["rsa,np"][0], rk.pka_barrett_np(n).to_bytes(rk.SIG_LEN, "big"),
                         "rsa,np does not match pka_barrett_np(modulus)")
        hash_nodes = [p for p in props if p.startswith(keys[0] + "/hash@")]
        if hash_nodes:
            self.assertEqual(props[hash_nodes[0]]["value"][0],
                             rk.burn_key_hash(n_be), "hash@np does not match burn_key_hash()")


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
                buf = rk.read(p)
                if rk.ldr_release_time_ok(buf) is False:
                    # Built before ss-fs-normalise floored releaseTime at 2025:
                    # verify must now fail it (a fused board refuses 1970-dated
                    # loaders), and that must be the ONLY fused-board problem.
                    self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 2)
                    problems = rk.fused_boot_problems(buf)
                    self.assertEqual(len(problems), 1, problems)
                    self.assertIn("releaseTime", problems[0])
                    rk.pin_ldr_release_time(buf)
                    rk.refresh_ldr_trailer(buf)
                    self.assertEqual(rk.fused_boot_problems(buf), [])
                else:
                    self.assertEqual(rk.main(["verify", p, "--pubkey", DEV_PUB]), 0)

    def test_ldr_trailers_are_valid_as_shipped(self):
        pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*signed-devkey*")
        images = [os.path.join(d, "download.bin") for d in glob.glob(pat)]
        images = [p for p in images if os.path.isfile(p)]
        if not images:
            self.skipTest("no signed build under opt/luckfox/build-output/ (gitignored)")
        for p in images:
            with self.subTest(image=os.path.relpath(p, REPO)):
                buf = rk.read(p)
                self.assertTrue(rk.is_ldr(buf))
                self.assertTrue(rk.ldr_trailer_ok(buf), "stale trailer as shipped")

    def test_full_key_swap_keeps_the_ldr_trailer_valid(self):
        """Regression: re-keying + signing a download.bin used to leave its LDR
        trailer CRC stale - cryptographically valid, rejected by SoCtoolkit on
        load. A full key swap must end with a file the flashing tools accept."""
        try:
            from Cryptodome.PublicKey import RSA
        except ImportError:
            self.skipTest("Cryptodome not available (needed for a second test key)")
        pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*signed-devkey*")
        images = [os.path.join(d, "download.bin") for d in glob.glob(pat)]
        images = [p for p in images if os.path.isfile(p)]
        if not images:
            self.skipTest("no signed build under opt/luckfox/build-output/ (gitignored)")
        n0, _e, d0 = rk.load_privkey(DEV_KEY)
        other = RSA.generate(2048)
        n1, d1 = int(other.n), int(other.d)
        for p in images:
            with self.subTest(image=os.path.relpath(p, REPO)), \
                    tempfile.TemporaryDirectory(prefix="rkloader-resign-") as tmp:
                dst = os.path.join(tmp, "download.bin")
                shutil.copyfile(p, dst)
                buf = rk.read(dst)
                lay = rk.layout(buf)
                rk.set_pubkey(buf, lay, n1)
                rk.sign_buf(buf, lay, n1, d1)
                self.assertTrue(rk.ldr_trailer_ok(buf), "stale trailer after re-sign")
                self.assertEqual(rk.read_modulus(buf, lay), n1)
                self.assertTrue(rk.rsa_verify_digest(
                    rk.msg_digest(buf, lay), rk.read_sig(buf, lay), n1))

    def _signed_download_bins(self):
        pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*signed-devkey*")
        images = [os.path.join(d, "download.bin") for d in glob.glob(pat)]
        return [p for p in images if os.path.isfile(p)]

    def test_flashhead_inner_signature_verifies(self):
        """Every shipped download.bin embeds an RC4-obfuscated loader image whose
        inner header signature must verify against the embedded key - whether it
        was signed by rk_sign_tool (random salt) or by us (digest-derived)."""
        images = self._signed_download_bins()
        if not images:
            self.skipTest("no signed build under opt/luckfox/build-output/ (gitignored)")
        n, _e, _d = rk.load_privkey(DEV_KEY)
        for p in images:
            with self.subTest(image=os.path.relpath(p, REPO)):
                buf = rk.read(p)
                reg = rk.flashhead_region(buf)
                self.assertIsNotNone(reg, "no flashhead region found")
                start, size = reg
                self.assertEqual(size % rk.FLASHHEAD_CHUNK, 0)
                pt = bytearray(rk._flashhead_xor(bytes(buf[start:start + size])))
                self.assertIn(bytes(pt[:4]), (rk.MAGIC_SIGNED, rk.MAGIC_UNSIGNED))
                self.assertTrue(rk.flashhead_sig_ok(buf, n), "inner signature invalid")

    def test_resign_is_idempotent_on_real_images(self):
        images = self._signed_download_bins()
        if not images:
            self.skipTest("no signed build under opt/luckfox/build-output/ (gitignored)")
        for p in images:
            with self.subTest(image=os.path.relpath(p, REPO)), \
                    tempfile.TemporaryDirectory(prefix="rkloader-fh-") as tmp:
                dst = os.path.join(tmp, "download.bin")
                shutil.copyfile(p, dst)
                self.assertEqual(rk.main(["sign", dst, "--key", DEV_KEY]), 0)
                first = bytes(rk.read(dst))
                self.assertEqual(rk.main(["sign", dst, "--key", DEV_KEY]), 0)
                self.assertEqual(bytes(rk.read(dst)), first, "re-signing must be byte-identical")
                self.assertTrue(rk.ldr_trailer_ok(first), "stale trailer after re-sign")

    def test_flashhead_matches_standalone_idblock(self):
        """The decrypted flashhead is a copy of the loader image: its header and
        body must equal idblock.img's, and both signatures must verify. Pins the
        RC4 key, chunking and region derivation against real vendor output.

        The signature bytes themselves may still differ when idblock.img was
        signed by rk_sign_tool (random salt) rather than by us (digest-derived);
        once both carry our signatures they are byte-identical end to end."""
        pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*signed-devkey*")
        pairs = []
        for d in glob.glob(pat):
            dl, ib = os.path.join(d, "download.bin"), os.path.join(d, "idblock.img")
            if os.path.isfile(dl) and os.path.isfile(ib):
                pairs.append((dl, ib))
        if not pairs:
            self.skipTest("no signed build with both images (gitignored)")
        n, _e, _d = rk.load_privkey(DEV_KEY)
        for dl, ib in pairs:
            with self.subTest(image=os.path.relpath(dl, REPO)), \
                    tempfile.TemporaryDirectory(prefix="rkloader-fh-") as tmp:
                dst = os.path.join(tmp, "download.bin")
                shutil.copyfile(dl, dst)
                self.assertEqual(rk.main(["sign", dst, "--key", DEV_KEY]), 0)
                buf = rk.read(dst)
                start, size = rk.flashhead_region(buf)
                pt = bytes(rk._flashhead_xor(bytes(buf[start:start + size])))
                ref = open(ib, "rb").read()
                self.assertEqual(len(pt), len(ref))
                self.assertEqual(pt[:rk.HDR_LEN], ref[:rk.HDR_LEN],
                                 "embedded image header differs from idblock.img")
                self.assertEqual(pt[rk.HDR_LEN + rk.SIG_LEN:],
                                 ref[rk.HDR_LEN + rk.SIG_LEN:],
                                 "embedded image body differs from idblock.img")
                inner = {"hdr": 0, "msg": (0, rk.HDR_LEN), "sig": (rk.HDR_LEN, rk.SIG_LEN)}
                self.assertTrue(rk.rsa_verify_digest(
                    rk.msg_digest(bytearray(pt), inner),
                    int.from_bytes(pt[rk.HDR_LEN:rk.HDR_LEN + rk.SIG_LEN], "little"), n))


class FusedBoard(unittest.TestCase):
    """What a FUSED board checks beyond the signature.

    Regression for 2026-09-21. A Mini was re-signed to a new key, armed and
    burned, and then dropped straight to maskrom. Nothing flashed afterwards
    was accepted:
      * set_pubkey rewrote the header modulus but left C (hdr+0x410, the PKA
        Barrett constant) holding the dev key's value, so the header's OTP
        hash differed from the one the SPL burned;
      * every download.bin carried a 1970-01-01 releaseTime, which a fused
        board refuses at Download Boot;
      * the flashhead's own SPL DTB was never re-keyed.
    Every software verifier passed all three.
    """

    @classmethod
    def setUpClass(cls):
        cls.n, cls.e, cls.d = rk.load_privkey(DEV_KEY)
        # flip a HIGH bit: a low-bit flip leaves floor(2^2180/n) - and so C -
        # unchanged, which would make every stale-C assertion vacuous
        cls.other = cls.n ^ (1 << 2040)

    def _otp_ok(self, buf, base, n):
        return rk.key_block_hash(buf, base) == rk.burn_key_hash(n.to_bytes(rk.SIG_LEN, "big"))

    def test_key_block_hash_is_the_burn_hash(self):
        """The header key block and rsa_burn_key_hash()'s buffer are the same
        bytes - that identity is what makes the burned OTP match the ROM."""
        buf = make_container(self.n)
        self.assertTrue(self._otp_ok(buf, 0, self.n))

    def test_set_pubkey_rewrites_the_c_field(self):
        buf = make_container(self.n)
        rk.set_pubkey(buf, rk.layout(buf), self.other)
        self.assertEqual(bytes(buf[rk.PKA_C_OFF:rk.PKA_C_OFF + rk.PKA_C_LEN]),
                         rk.pka_c_field(self.other))
        self.assertTrue(self._otp_ok(buf, 0, self.other),
                        "re-keyed header does not hash to the new key's OTP value")

    def test_stale_c_is_a_fused_board_problem(self):
        """Exactly the bricking image: the new modulus with the old key's C."""
        buf = make_container(self.n)
        buf[rk.MOD_OFF:rk.MOD_OFF + rk.SIG_LEN] = self.other.to_bytes(rk.SIG_LEN, "little")
        problems = rk.fused_boot_problems(buf)
        self.assertTrue(any("stale PKA constant C" in p for p in problems), problems)

    def test_set_pubkey_rekeys_the_flashhead_key_block(self):
        buf = make_flashhead_container(self.n)
        rk.set_pubkey(buf, rk.layout(buf), self.other)
        self.assertTrue(self._otp_ok(buf, 0x1bc, self.other))
        self.assertTrue(self._otp_ok(rk.flashhead_plaintext(buf), 0, self.other))

    def test_armed_spl_and_header_must_agree(self):
        """An idblock whose SPL would burn a different hash than its header
        presents to the BootROM bricks the board on the boot after the burn."""
        dtb = make_key_dtb(self.other)                 # SPL burns the new key...
        buf = make_container(self.n)                   # ...header still the old one
        buf.extend(dtb)
        problems = rk.fused_boot_problems(buf)
        self.assertTrue(any("bricks the board" in p for p in problems), problems)

    def test_1970_release_time_is_pinned_on_sign(self):
        buf = make_container(self.n, hdr_off=0x1bc, ldr=True)
        struct.pack_into("<HBBBBB", buf, rk.LDR_RELEASE_OFF, 1970, 1, 1, 0, 0, 0)
        rk.refresh_ldr_trailer(buf)
        self.assertTrue(any("releaseTime" in p for p in rk.fused_boot_problems(buf)))
        lay = rk.layout(buf)
        rk.sign_buf(buf, lay, self.n, self.d)
        self.assertEqual(rk.ldr_release_time(buf), rk.LDR_RELEASE_FLOOR)
        self.assertTrue(rk.ldr_trailer_ok(buf))
        self.assertEqual(rk.fused_boot_problems(buf), [])

    def test_unsigned_flashhead_is_a_fused_board_problem(self):
        """The air-gap splice used to sign only the outer header, which left
        the embedded copy with a signature from a different key."""
        buf = make_flashhead_container(self.n)          # inner signature is zeroed
        problems = rk.fused_boot_problems(buf)
        self.assertTrue(any("flashhead inner signature" in p for p in problems), problems)
        rk.resign_flashhead(buf, self.n, self.d)
        self.assertFalse(any("flashhead" in p for p in rk.fused_boot_problems(buf)))

    def test_newer_release_time_is_left_alone(self):
        buf = make_container(self.n, hdr_off=0x1bc, ldr=True)
        struct.pack_into("<HBBBBB", buf, rk.LDR_RELEASE_OFF, 2026, 9, 21, 23, 4, 55)
        self.assertFalse(rk.pin_ldr_release_time(buf))
        self.assertEqual(rk.ldr_release_time(buf), (2026, 9, 21, 23, 4, 55))

    def test_real_bundle_rekey_is_fused_board_clean(self):
        """Full re-key of a real build with a real second key: header, flashhead
        header and flashhead SPL DTB must all end up on the new key, and the
        hash an armed SPL would burn must equal what the ROM will compute."""
        try:
            from Cryptodome.PublicKey import RSA
        except ImportError:
            self.skipTest("Cryptodome not available (needed for a second test key)")
        pat = os.path.join(REPO, "opt", "luckfox", "build-output", "*signed-devkey*")
        dirs = [d for d in glob.glob(pat)
                if os.path.isfile(os.path.join(d, "download.bin"))
                and os.path.isfile(os.path.join(d, "idblock.img"))]
        if not dirs:
            self.skipTest("no signed build with both images (gitignored)")
        other = RSA.generate(2048)
        n1, d1 = int(other.n), int(other.d)
        want = rk.burn_key_hash(n1.to_bytes(rk.SIG_LEN, "big"))
        for d in dirs:
            for name in ("idblock.img", "download.bin"):
                with self.subTest(image=os.path.join(os.path.basename(d), name)):
                    buf = rk.read(os.path.join(d, name))
                    lay = rk.layout(buf)
                    rk.set_pubkey(buf, lay, n1)
                    if name == "idblock.img":
                        rk.arm_burn(buf, lay)
                    rk.sign_buf(buf, lay, n1, d1)
                    self.assertEqual(rk.fused_boot_problems(buf), [])
                    self.assertEqual(rk.key_block_hash(buf, lay["hdr"]), want)
                    if name == "idblock.img":
                        self.assertEqual(rk.spl_burn_hash(buf), want)
                    else:
                        pt = rk.flashhead_plaintext(buf)
                        self.assertEqual(rk.spl_burn_hash(pt), want,
                                         "flashhead SPL DTB still on the old key")
                        self.assertTrue(rk.components_ok(bytearray(pt), {"hdr": 0}))
                        self.assertTrue(rk.flashhead_sig_ok(buf, n1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
