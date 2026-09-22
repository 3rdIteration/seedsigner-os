#!/usr/bin/env python3
"""Tests for tools/airgap-sign.py - the PC half of the air-gapped signing flow.

Synthetic: builds a release folder from scratch (reusing test_luckfox_release's
harness), runs the `force` subcommand, simulates the device's Sign Digest with
the committed dev key, and splices the signature back. Runs in CI.

Run:  python3 tests/test_airgap_sign.py
"""
import importlib.util, os, shutil, struct, sys, tempfile, types, unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SB = os.path.join(REPO, "opt", "luckfox", "secure-boot")
DEV_PUB = os.path.join(SB, "dev-keys", "dev.pubkey")

sys.path.insert(0, SB)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rkloader as rk            # noqa: E402
import fitsign as fs             # noqa: E402
import luckfox_release as lr     # noqa: E402
from test_luckfox_release import make_release, N, D   # noqa: E402

# The tool's filename has a dash; load it explicitly. Its own imports resolve to
# the same module instances already loaded above (it inserts SB on sys.path too).
_spec = importlib.util.spec_from_file_location("airgap_sign", os.path.join(REPO, "tools", "airgap-sign.py"))
ags = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ags)


def make_container(modulus, hdr_off=0x0, filler=b"\xa5", ldr=False):
    """A minimal RKNS container (test_rkloader's builder, inlined so importing
    that module does not swap sys.modules["rkloader"] out from under us)."""
    buf = bytearray(filler * (hdr_off + rk.HDR_LEN + rk.SIG_LEN + 0x40))
    if ldr:
        buf[0:4] = rk.LDR_TAG
    buf[hdr_off:hdr_off + 4] = rk.MAGIC_UNSIGNED
    struct.pack_into("<I", buf, hdr_off + 0x0c, 0x01)
    # the whole key block (N, E, C) as the vendor tools write it, not just N
    if modulus:
        rk.write_key_block(buf, hdr_off, modulus)
    if ldr:
        rk.refresh_ldr_trailer(buf)
    return buf


def sign_like_device(card):
    """What the app's Sign Digest writes back: one .sig per .digest (the exact
    deterministic-salt PSS encoding it uses, so a spliced result is byte-for-byte
    what on-device signing would produce) plus release-rsa.pub."""
    d = os.path.join(card, ags.CARD_DIRNAME)
    for name in sorted(os.listdir(d)):
        if not name.endswith(".digest"):
            continue
        base = name[:-len(".digest")]
        tier = ags.ARTIFACTS[base][1]
        with open(os.path.join(d, name), "rb") as f:
            digest = f.read()
        salt_len = rk.SALT_LEN if tier == "ldr" else fs.max_salt_len(N)
        em = rk.pss_encode(digest, N.bit_length() - 1, rk.deterministic_salt(digest, salt_len))
        value = pow(int.from_bytes(em, "big"), D, N).to_bytes(256, "little" if tier == "ldr" else "big")
        with open(os.path.join(d, base + ".sig"), "wb") as f:
            f.write(value)
    shutil.copy(DEV_PUB, os.path.join(d, "release-rsa.pub"))


def force_args(bundle, card, off=False):
    return types.SimpleNamespace(bundle=bundle, card=card, off=off)


def splice_args(bundle, card, no_check=True):
    return types.SimpleNamespace(bundle=bundle, card=card, only=None,
                                 rsa_pubkey=None, rootfs_pubkey=None, no_check=no_check)


class Force(unittest.TestCase):
    """`force`: the PC-side counterpart of the app's Force Rootfs Check action."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="airgap-force-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bundle = os.path.join(self.tmp, "release")
        make_release(self.bundle)          # dev-key signed, force-aware /init, marker off
        self.card = os.path.join(self.tmp, "card")

    def boot_buf(self):
        return rk.read(os.path.join(self.bundle, "boot.img"))

    def test_turn_on_round_trip(self):
        original = lr.initramfs_members(self.boot_buf())
        self.assertEqual(ags.cmd_force(force_args(self.bundle, self.card)), 0)

        # the marker is in the image now; every other initramfs member is untouched
        members = lr.initramfs_members(self.boot_buf())
        self.assertIn(lr.FORCE_MARKER, members)
        for name, data in original.items():
            if name != "init":
                self.assertEqual(members[name], data, name)

        # the digest on the card is exactly what splice will verify against
        d = os.path.join(self.card, ags.CARD_DIRNAME)
        with open(os.path.join(d, "boot.digest"), "rb") as f:
            self.assertEqual(f.read(), fs.signed_digest(self.boot_buf()))

        # the image is unsigned until the signature comes back
        self.assertFalse(fs.verify_buf(self.boot_buf(), N))

        sign_like_device(self.card)
        self.assertEqual(ags.cmd_splice(splice_args(self.bundle, self.card)), 0)
        boot = self.boot_buf()
        self.assertTrue(fs.verify_buf(boot, N))
        self.assertIn(lr.FORCE_MARKER, lr.initramfs_members(boot))
        # the rework changed the ramdisk size; the auto-flash script was fixed to match
        self.assertFalse(lr.sd_update_check(self.bundle)["fixable"])

    def test_turn_off_restores_the_original_ramdisk(self):
        original = lr._ramdisk(self.boot_buf())
        ags.cmd_force(force_args(self.bundle, self.card))          # on
        sign_like_device(self.card)
        ags.cmd_splice(splice_args(self.bundle, self.card))

        ags.cmd_force(force_args(self.bundle, self.card, off=True))  # off again
        self.assertNotIn(lr.FORCE_MARKER, lr.initramfs_members(self.boot_buf()))
        sign_like_device(self.card)
        ags.cmd_splice(splice_args(self.bundle, self.card))

        boot = self.boot_buf()
        self.assertTrue(fs.verify_buf(boot, N))
        # toggling on then off is a fixed point: the ramdisk is byte-identical to the start
        self.assertEqual(lr._ramdisk(boot), original)

    def test_no_op_when_already_in_the_requested_state(self):
        ags.cmd_force(force_args(self.bundle, self.card))          # on
        sign_like_device(self.card)
        ags.cmd_splice(splice_args(self.bundle, self.card))

        d = os.path.join(self.card, ags.CARD_DIRNAME)
        card_before = {n: open(os.path.join(d, n), "rb").read() for n in sorted(os.listdir(d))}
        before = bytes(self.boot_buf())
        self.assertEqual(ags.cmd_force(force_args(self.bundle, self.card)), 0)   # already on
        self.assertEqual(bytes(self.boot_buf()), before)
        card_after = {n: open(os.path.join(d, n), "rb").read() for n in sorted(os.listdir(d))}
        self.assertEqual(card_before, card_after)          # nothing re-emitted

    def test_removes_a_stale_update_img(self):
        with open(os.path.join(self.bundle, "update.img"), "wb") as f:
            f.write(b"stale chain")
        ags.cmd_force(force_args(self.bundle, self.card))
        self.assertFalse(os.path.exists(os.path.join(self.bundle, "update.img")))

    def test_refused_on_a_verifier_that_predates_the_marker(self):
        shutil.rmtree(self.bundle)
        make_release(self.bundle, force_aware=False)
        with self.assertRaises(SystemExit) as ctx:
            ags.cmd_force(force_args(self.bundle, self.card))
        self.assertIn("predates forced rootfs checks", str(ctx.exception.code))

    def test_full_check_passes_after_the_round_trip(self):
        """With the whole chain present and signed under one key, splice's final
        check_release must come out VALID - that is what a user sees on their PC."""
        for name, off, ldr in (("idblock.img", 0x0, False), ("download.bin", 0x1bc, True)):
            buf = bytearray(make_container(N, hdr_off=off, ldr=ldr))
            rk.sign_buf(buf, rk.layout(buf), N, D)
            with open(os.path.join(self.bundle, name), "wb") as f:
                f.write(bytes(buf))

        # uboot.img: a signed FIT that embeds the loader's key big-endian (the
        # "uboot.img key" check searches for exactly those bytes).
        from test_luckfox_release import build_boot, kernel_dtb
        with open(os.path.join(self.bundle, "uboot.img"), "wb") as f:
            f.write(bytes(build_boot({"fdt": kernel_dtb(),
                                      "kernel": N.to_bytes(256, "big") + b"K" * 100})))

        ags.cmd_force(force_args(self.bundle, self.card))
        sign_like_device(self.card)
        self.assertEqual(ags.cmd_splice(splice_args(self.bundle, self.card, no_check=False)), 0)
        rep = lr.check_release(self.bundle)
        self.assertTrue(rep.ok, lr.format_report(rep))
        self.assertTrue(rep.force_rootfs)


class DigestsSpliceRefactor(unittest.TestCase):
    """The _emit_digest extraction must not have changed `digests`/`splice` behaviour."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="airgap-digest-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bundle = os.path.join(self.tmp, "release")
        make_release(self.bundle)
        self.card = os.path.join(self.tmp, "card")

    def test_digests_boot_only_then_splice(self):
        a = types.SimpleNamespace(bundle=self.bundle, card=self.card, only="boot")
        ags.cmd_digests(a)
        d = os.path.join(self.card, ags.CARD_DIRNAME)
        with open(os.path.join(d, "manifest.txt")) as f:
            manifest = f.read()
        self.assertIn("boot.digest", manifest)
        self.assertNotIn("rootfs.digest", manifest)

        sign_like_device(self.card)
        splice = types.SimpleNamespace(bundle=self.bundle, card=self.card, only="boot",
                                       rsa_pubkey=None, rootfs_pubkey=None, no_check=True)
        self.assertEqual(ags.cmd_splice(splice), 0)
        # re-signing the unchanged image with the same key is a fixed point
        self.assertTrue(fs.verify_buf(rk.read(os.path.join(self.bundle, "boot.img")), N))


if __name__ == "__main__":
    unittest.main()
