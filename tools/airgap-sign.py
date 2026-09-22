#!/usr/bin/env python3
"""airgap-sign.py - the PC half of the air-gapped signing flow.

One command per card round-trip:

  rekey <bundle> --card <dir> [--rsa-pubkey F]
      Round 0 of an air-gap RE-KEY: embed the new RSA public key into the images
      that carry one (public halves only - no private key ever touches this
      machine). download.bin and idblock.img get the new modulus with their
      signatures cleared; uboot.img's embedded verification key is swapped and
      rehashed. boot.img is deliberately left alone: its initramfs holds the
      rootfs key pair, which splice replaces via the tier-C injection (that also
      sets /init's key classes). After this, run `digests` on the re-keyed
      bundle - for a full re-key do the rootfs round-trip first (see below), so
      boot.digest is taken over the final initramfs.

  digests <bundle> --card <dir> [--only a,b,c]
      Write <card>/seedsigner-release-sign/ with manifest.txt and one .digest
      per requested artifact, ready for the device's Sign Digest action (or any
      other signer). The rootfs digest is UBI-aware: on NAND bundles it hashes
      the logical volume exactly as the device streams it from /dev/ubi0_0, not
      the raw file bytes.

  force <bundle> --card <dir> [--off]
      Toggle the forced rootfs check WITHOUT a private key on this machine -
      the PC-side counterpart of the app's Force Rootfs Check action (which is
      too heavy for small boards such as the Pico Mini). Reworks boot.img's
      initramfs in place (adds or removes /force-rootfs-verify), drops any stale
      update.img, and leaves boot.digest on the card. Sign it with the device's
      Sign Digest, then `splice` puts the signature back and runs the full check.

  splice <bundle> --card <dir> [--rsa-pubkey F] [--rootfs-pubkey F] [--no-check]
      Splice every signature the card carries back into the bundle: tier A and B
      signatures are verified as they go; a rootfs.minisig is injected into
      boot.img's initramfs (verified against this folder's rootfs first) BEFORE
      boot.img's own signature is spliced, since that one covers the ramdisk.
      Finishes by fixing any sd_update.txt write lengths the rework changed and
      running a full check_release - non-zero exit if anything does not verify.
      --no-check skips that final step for intermediate round-trips, where the
      bundle is expected to be unsigned until the last splice lands.

      The device's Sign Digest writes release-rsa.pub / release-rootfs.pub into
      the card folder alongside the signatures; when present they are used for
      verification automatically and the --*-pubkey flags are not needed (they
      still win if given).

Round-trip ordering on a re-key: setkey/rehash the loaders first (public-key
operations, no signature needed), then `digests --only rootfs`, sign it, splice
it back with `splice` (which injects and leaves boot.img unsigned), then
`digests --only download,idblock,uboot,boot` for the second round-trip.

Python 3 standard library only; imports the secure-boot signers from
opt/luckfox/secure-boot/, which are pure stdlib too. Runs on Windows.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "opt", "luckfox", "secure-boot"))
import rkloader as rk            # noqa: E402
import fitsign as fs             # noqa: E402
import minisign as ms            # noqa: E402
import luckfox_release as lr     # noqa: E402

CARD_DIRNAME = "seedsigner-release-sign"   # Sign Digest writes here (digests, sigs, pubkeys)
KEYS_DIRNAME = "seedsigner-release-keys"   # Export Pubkeys writes here (pubkeys + README)

# name -> (tier, kind). kind: "ldr" = rkloader image, "fit" = U-Boot FIT,
# "rootfs" = the minisigned payload.
ARTIFACTS = {
    "download": ("A", "ldr"),
    "idblock":  ("A", "ldr"),
    "uboot":    ("B", "fit"),
    "boot":     ("B", "fit"),
    "rootfs":   ("C", "rootfs"),
}

TIER_NOTES = {
    "download": "tier A, RSA-2048 PSS over the marked 0x600 header; .sig is 256 bytes little-endian",
    "idblock":  "tier A, RSA-2048 PSS over the marked 0x600 header; .sig is 256 bytes little-endian",
    "uboot":    "tier B, RSA-2048 PSS over the FIT hashed nodes; .sig is 256 bytes big-endian",
    "boot":     "tier B, RSA-2048 PSS over the FIT hashed nodes (covers the ramdisk - emit AFTER any tier-C injection); .sig is 256 bytes big-endian",
    "rootfs":   "tier C, BLAKE2b-512 prehash of the first ROOTFS_SIGNED_SIZE bytes; on NAND that is the logical UBI volume, not the file; signer returns a .minisig",
}


def card_dir(card):
    d = os.path.join(card, CARD_DIRNAME)
    if not os.path.isdir(d):
        sys.exit("no %s/ folder in %s - run `digests` first" % (CARD_DIRNAME, card))
    return d


def rootfs_signed_size(folder):
    """The byte count tier C covers: /init's ROOTFS_SIGNED_SIZE, else the .size sidecar."""
    boot = os.path.join(folder, "boot.img")
    if os.path.isfile(boot):
        try:
            return lr.signed_size(lr.initramfs_members(rk.read(boot)))
        except (lr.ReleaseError, fs.FitError) as e:
            print("note: cannot read ROOTFS_SIGNED_SIZE from boot.img (%s)" % e, file=sys.stderr)
    sidecar = os.path.join(folder, "rootfs.img.size")
    if os.path.isfile(sidecar):
        return int(open(sidecar).read().strip())
    sys.exit("no way to determine the rootfs signed size (no boot.img /init, no rootfs.img.size)")


def _emit_digest(d, name, bundle):
    """Write <d>/<name>.digest for one artifact; return its manifest line."""
    tier, kind = ARTIFACTS[name]
    path = os.path.join(bundle, name + (".img" if name != "download" else ".bin"))
    if not os.path.isfile(path):
        sys.exit("%s is missing from the bundle" % path)
    out = os.path.join(d, name + ".digest")
    if kind == "ldr":
        buf = rk.read(path)
        digest = rk.signing_digest(buf, rk.layout(buf))
    elif kind == "fit":
        digest = fs.signed_digest(rk.read(path))
    else:  # rootfs
        size = rootfs_signed_size(bundle)
        print("rootfs: %s, signed size %d bytes" % (lr.rootfs_kind(bundle), size))
        digest = lr.rootfs_prehash(bundle, size)
    with open(out, "wb") as f:
        f.write(digest)
    line = "%-16s sha256:%s...  %s" % (name + ".digest", digest.hex()[:16], TIER_NOTES[name])
    print("wrote %s (%d bytes)" % (out, len(digest)))
    return line


def _card_ready(card_dir_path):
    print("\ncard ready at %s - insert it into the SeedSigner and run" % card_dir_path)
    print("Tools -> Luckfox Build Tools -> Sign Digest")


def cmd_digests(a):
    names = [n.strip() for n in a.only.split(",") if n.strip()] if a.only else list(ARTIFACTS)
    bad = [n for n in names if n not in ARTIFACTS]
    if bad:
        sys.exit("unknown artifact(s): %s (choose from %s)" % (", ".join(bad), ", ".join(ARTIFACTS)))

    d = os.path.join(a.card, CARD_DIRNAME)
    os.makedirs(d, exist_ok=True)
    manifest = ["# airgap-sign.py digests - one .digest per line below",
                "# bundle: %s" % os.path.abspath(a.bundle), ""]
    for name in names:
        manifest.append(_emit_digest(d, name, a.bundle))

    with open(os.path.join(d, "manifest.txt"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    _card_ready(d)


def cmd_force(a):
    on = not a.off
    boot = os.path.join(a.bundle, "boot.img")
    if not os.path.isfile(boot):
        sys.exit("no boot.img in the bundle")
    buf = rk.read(boot)
    members = lr.initramfs_members(buf)
    if not lr.supports_force_marker(members):
        sys.exit("this release's verifier predates forced rootfs checks - it cannot be turned on")
    current = lr.FORCE_MARKER in members
    if current == on:
        print("forced rootfs check is already %s - nothing to do" % ("on" if on else "off"))
        return 0

    new_buf, done = lr.rework_initramfs(buf, force=on)
    with open(boot, "wb") as f:
        f.write(bytes(new_buf))
    for line in done:
        print(line)
    print("boot.img reworked - unsigned until its signature is spliced back")

    # update.img packs a verbatim copy of the chain; after boot.img changes it is stale.
    upd = os.path.join(a.bundle, "update.img")
    if os.path.isfile(upd):
        os.remove(upd)
        print("removed update.img (it packed the old boot.img; regenerate with mk-update-pack.sh)")

    d = os.path.join(a.card, CARD_DIRNAME)
    os.makedirs(d, exist_ok=True)
    manifest = ["# airgap-sign.py force - one .digest per line below",
                "# bundle: %s" % os.path.abspath(a.bundle), ""]
    manifest.append(_emit_digest(d, "boot", a.bundle))
    with open(os.path.join(d, "manifest.txt"), "w") as f:
        f.write("\n".join(manifest) + "\n")
    _card_ready(d)
    print("then on this machine:")
    print("  airgap-sign.py splice %s --card %s" % (a.bundle, a.card))
    print("(splice verifies boot.sig against the card's release-rsa.pub and runs the full check)")
    return 0


def _splice_ldr(path, sig_path):
    buf = rk.read(path)
    lay = rk.layout(buf)
    with open(sig_path, "rb") as f:
        sig = f.read()
    if len(sig) in (rk.SIG_LEN * 2, rk.SIG_LEN * 2 + 1):
        sig = bytes.fromhex(sig.decode().strip())
    if len(sig) != rk.SIG_LEN:
        sys.exit("%s: signature must be %d bytes, got %d" % (sig_path, rk.SIG_LEN, len(sig)))
    rk.prepare_for_signing(buf, lay)
    off, _ = lay["sig"]
    buf[off:off + rk.SIG_LEN] = sig
    n = rk.read_modulus(buf, lay)
    if not n:
        sys.exit("%s embeds no public key - run setkey before splicing" % path)
    if not rk.rsa_verify_digest(rk.msg_digest(buf, lay), int.from_bytes(sig, "little"), n):
        sys.exit("spliced signature does NOT verify against the embedded key in %s" % path)
    rk.refresh_ldr_trailer(buf)
    with open(path, "wb") as f:
        f.write(buf)
    print("%s: spliced (verified against the embedded key)" % os.path.basename(path))


def _splice_fit(path, sig_path, rsa_pubkey=None):
    buf = rk.read(path)
    node = fs.signature_node(buf)
    with open(sig_path, "rb") as f:
        value = f.read()
    if len(value) in (512, 513):
        value = bytes.fromhex(value.decode().strip())
    fs._write_value(buf, node, value)
    verified = False
    if rsa_pubkey:
        if not fs.verify_buf(buf, rk.load_pubkey(rsa_pubkey)[0]):
            sys.exit("spliced signature does NOT verify against %s" % rsa_pubkey)
        verified = True
    with open(path, "wb") as f:
        f.write(buf)
    print("%s: spliced%s" % (os.path.basename(path), " (verified)" if verified else " (not verified - pass --rsa-pubkey)"))


def _pubkey(cli_value, card, filename):
    """The CLI flag wins; otherwise the key on the card (Sign Digest's folder first, then Export Pubkeys')."""
    if cli_value:
        return cli_value
    for dirname in (CARD_DIRNAME, KEYS_DIRNAME):
        path = os.path.join(card, dirname, filename)
        if os.path.isfile(path):
            return path
    return None


def cmd_rekey(a):
    rsa_pubkey = _pubkey(a.rsa_pubkey, a.card, "release-rsa.pub")
    if not rsa_pubkey:
        sys.exit("no release-rsa.pub found (Export Pubkeys or Sign Digest writes it) - pass --rsa-pubkey")

    new_n = rk.load_pubkey(rsa_pubkey)[0]

    # The old modulus must be captured BEFORE anything is re-keyed: uboot.img can only
    # be re-keyed by searching for the key it currently embeds.
    old_n = None
    for name in ("idblock.img", "download.bin"):
        path = os.path.join(a.bundle, name)
        if os.path.isfile(path):
            buf = rk.read(path)
            old_n = rk.read_modulus(buf, rk.layout(buf))
            break

    # 1. loaders: embed the new modulus; their signatures are cleared (unsigned until signed).
    for name in ("download.bin", "idblock.img"):
        path = os.path.join(a.bundle, name)
        if not os.path.isfile(path):
            print("note: %s not present - skipped" % name)
            continue
        buf = bytearray(rk.read(path))
        lay = rk.layout(buf)
        hits = rk.set_pubkey(buf, lay, new_n)
        # set_pubkey rewrites key material inside idblock's SPL DTB - a hashed
        # component - so refresh the header's component hashes to match. The
        # trailer CRC covers those bytes too, so it goes last (no-op on idblock).
        changed = rk.rehash_components(buf, lay)
        rk.refresh_ldr_trailer(buf)
        with open(path, "wb") as f:
            f.write(bytes(buf))
        print("%s: embedded the new key (%d locations), signature cleared%s"
              % (name, hits, ", %d component hash(es) refreshed" % changed if changed else ""))

    # 2. uboot.img: swap the verification key U-Boot uses for boot.img; rehash the payload.
    path = os.path.join(a.bundle, "uboot.img")
    if os.path.isfile(path):
        buf = bytearray(rk.read(path))
        hits = 0
        if old_n is None:
            print("note: no embedded key found in the loaders - cannot locate uboot.img's copy; skipped")
        elif old_n != new_n:
            hits = fs.set_pubkey(buf, new_n, old_n)
            if not hits:
                sys.exit("uboot.img did not contain the old public key (modulus %s...) - "
                         "cannot locate its embedded verification key" % hex(old_n)[:20])
            fs.rehash_buf(buf)
        with open(path, "wb") as f:
            f.write(bytes(buf))
        print("uboot.img: swapped the embedded verification key (%d locations), rehashed%s"
              % (hits, "" if hits else " - already carried the new key"))

    # 3. update.img packs a verbatim copy of the chain it was built from; after a
    # re-key that copy is stale, so remove it (regenerate with mk-update-pack.sh if needed).
    upd = os.path.join(a.bundle, "update.img")
    if os.path.isfile(upd):
        os.remove(upd)
        print("removed update.img (it packed the old chain; regenerate with mk-update-pack.sh)")

    # 4. boot.img is deliberately left alone: its initramfs holds the rootfs key pair, which
    # splice replaces via the tier-C injection (that also sets /init's key classes).
    print("\nboot.img left alone - its re-key happens at `splice` time (tier-C injection)")
    print("next steps for a full re-key:")
    print("  digests --only rootfs            -> Sign Digest on the device")
    print("  splice --only rootfs --no-check  (injects; boot.img stays unsigned)")
    print("  digests --only download,idblock,uboot,boot   -> Sign Digest")
    print("  splice                           (final check_release must pass)")


def cmd_splice(a):
    d = card_dir(a.card)
    names = [n.strip() for n in a.only.split(",") if n.strip()] if a.only else list(ARTIFACTS)
    bad = [n for n in names if n not in ARTIFACTS]
    if bad:
        sys.exit("unknown artifact(s): %s" % ", ".join(bad))

    rsa_pubkey = _pubkey(a.rsa_pubkey, a.card, "release-rsa.pub")
    rootfs_pubkey = _pubkey(a.rootfs_pubkey, a.card, "release-rootfs.pub")

    # Tier C first: the injection rewrites boot.img's ramdisk, which boot.sig covers.
    minisig = os.path.join(d, "rootfs.minisig")
    if "rootfs" in names and os.path.isfile(minisig):
        if not rootfs_pubkey:
            sys.exit("rootfs.minisig is present but no release-rootfs.pub on the card "
                     "(Sign Digest writes it) - pass --rootfs-pubkey")
        boot = os.path.join(a.bundle, "boot.img")
        new_buf, done = lr.inject_rootfs_sig(rk.read(boot), folder=a.bundle,
                                             minisig_path=minisig, pubkey_path=rootfs_pubkey,
                                             fit_pubkey_path=rsa_pubkey)
        if done:
            with open(boot, "wb") as f:
                f.write(new_buf)
            for line in done:
                print(line)
    elif "rootfs" in names and os.path.isfile(os.path.join(d, "rootfs.digest")):
        print("note: no rootfs.minisig on the card - tier C not spliced")

    for name in names:
        if name == "rootfs":
            continue
        sig = os.path.join(d, name + ".sig")
        if not os.path.isfile(sig):
            print("note: no %s.sig on the card - skipped" % name)
            continue
        path = os.path.join(a.bundle, name + (".img" if name != "download" else ".bin"))
        if ARTIFACTS[name][1] == "ldr":
            _splice_ldr(path, sig)
        else:
            _splice_fit(path, sig, rsa_pubkey)

    # The rework changes image sizes; keep the auto-flash script honest.
    res = lr.sd_update_check(a.bundle, fix=True)
    for line in res["fixed"]:
        print("sd_update.txt fixed: %s" % line)
    if res["problems"]:
        for p in res["problems"]:
            print("  ! " + p, file=sys.stderr)

    if a.no_check:
        print("\n--no-check: skipping the full check (mid-flow bundles are expected to be invalid)")
        return 0
    rep = lr.check_release(a.bundle)
    print()
    print(lr.format_report(rep))
    return 0 if rep.ok else 2


def main():
    p = argparse.ArgumentParser(prog="airgap-sign.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("rekey", help="round 0 of an air-gap re-key: embed new public keys (no private key needed)")
    s.add_argument("bundle", help="release folder to re-key in place")
    s.add_argument("--card", required=True,
                   help="MicroSD mount point holding release-rsa.pub "
                        "(from Export Pubkeys or a previous Sign Digest), or any directory")
    s.add_argument("--rsa-pubkey", help="RSA public key (PEM) to embed; default: release-rsa.pub from the card")
    s.set_defaults(func=cmd_rekey)

    s = sub.add_parser("digests", help="write the card folder for a signing round-trip")
    s.add_argument("bundle", help="release folder (download.bin, *.img, rootfs.img)")
    s.add_argument("--card", required=True, help="MicroSD mount point (or any directory)")
    s.add_argument("--only", help="comma-separated subset of %s (default: all)" % ",".join(ARTIFACTS))
    s.set_defaults(func=cmd_digests)

    s = sub.add_parser(
        "force",
        help="toggle the forced rootfs check via a Sign Digest round-trip (no private key needed here)")
    s.add_argument("bundle", help="release folder to rework in place")
    s.add_argument("--card", required=True, help="MicroSD mount point (or any directory)")
    s.add_argument("--off", action="store_true",
                   help="turn the forced check OFF instead of on")
    s.set_defaults(func=cmd_force)

    s = sub.add_parser("splice", help="splice the returned signatures back and verify")
    s.add_argument("bundle")
    s.add_argument("--card", required=True)
    s.add_argument("--only", help="comma-separated subset of %s (default: all)" % ",".join(ARTIFACTS))
    s.add_argument("--rsa-pubkey",
                   help="RSA public key to verify tier B splices against "
                        "(default: release-rsa.pub from the card folder, if present)")
    s.add_argument("--rootfs-pubkey",
                   help="Ed25519 public key the rootfs.minisig must match (minisign format; "
                        "default: release-rootfs.pub from the card folder, if present)")
    s.add_argument("--no-check", action="store_true",
                   help="skip the final check_release (for intermediate round-trips, "
                        "where the bundle is expected to be unsigned until the last splice)")
    s.set_defaults(func=cmd_splice)

    a = p.parse_args()
    try:
        sys.exit(a.func(a))
    except (rk.RkError, fs.FitError, ms.MsError, lr.ReleaseError) as e:
        sys.exit("airgap-sign: %s" % e)


if __name__ == "__main__":
    main()
