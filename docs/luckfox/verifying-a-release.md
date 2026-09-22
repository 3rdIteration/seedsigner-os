# Verifying a distributed SeedSigner Luckfox image

Two independent questions, answered by two different checks. Do both.

| Question | Check | Needs |
|---|---|---|
| **Authenticity** — was this signed by the key I trust? | `verify` | the published public keys |
| **Reproducibility** — does it correspond to the published source? | `canonicalise` + compare | a rebuild from the pinned commit |

Neither check requires the signing key, the vendor tools, the Rockchip SDK or a
build tree. All three verifiers are pure-Python stdlib and run anywhere,
including on the device itself:

- [`secure-boot/rkloader.py`](../../opt/luckfox/secure-boot/rkloader.py) — the loader and idblock
- [`secure-boot/fitsign.py`](../../opt/luckfox/secure-boot/fitsign.py) — `uboot.img`, `boot.img`
- [`secure-boot/minisign.py`](../../opt/luckfox/secure-boot/minisign.py) — the rootfs

> **The default build is signed with a published key.** CI defaults to
> `signing: on` and uses the committed *public* dev keys, so a stock artifact
> verifies but is **not protected** — anyone can produce an image that passes.
> Check *which* key signed it (below), not merely that verification succeeded.

## 1. Authenticity

```bash
SB=opt/luckfox/secure-boot
python3 $SB/rkloader.py verify download.bin --pubkey release.pub
python3 $SB/rkloader.py verify idblock.img  --pubkey release.pub
python3 $SB/fitsign.py  verify uboot.img    --pubkey release.pub
python3 $SB/fitsign.py  verify boot.img     --pubkey release.pub
python3 $SB/minisign.py verify rootfs.img   --pubkey release-rootfs.pub
```

Exit status is `0` for a good signature and `2` for a bad one, so these compose
in a script.

To see *which* key an image is bound to, without needing the public key at all:

```bash
python3 $SB/rkloader.py inspect idblock.img
```

It prints the embedded modulus' SHA-256. Compare that against the key you
expect. The two published dev keys — **which give no protection** — are:

| Key | SHA-256 |
|---|---|
| FIT/loader RSA modulus (as `rkloader.py inspect` prints it: SHA-256 of the 256-byte big-endian modulus) | `07c0c507c9223a035b3e1b3b0d557fb50b6d0a857f61de3118363afa5348ddd8` |
| rootfs minisign `dev.pubkey` (file hash) | `324f4a638edc35c3e709d1569ad8ec3a5cced2ca5995d088eae703f7434a6878` |
| rootfs minisign key id | `FB935B80871B6C36` |

`python3 $SB/luckfox_release.py check <folder>` does all of this in one go: every
signature, which keys were used (flagging the dev keys), whether the rootfs
verifies against the key boot.img carries, and whether the MicroSD auto-flash
script would write each image in full.

A device also tells you at boot: the verifier screen shows **yellow** instead of
green when either key is a published dev key, and orange *SECURE BOOT not
enabled* on an unfused board (or, if the release forces the rootfs check on
unfused boards, an orange *PASSED … SECURE BOOT not enabled*).

### What each signature actually covers

Worth knowing so the checks are not over-read:

- **Loader / idblock** — the signature covers the 0x600-byte header only. The
  SPL and the SPL DTB that carries the public key are covered *transitively*, by
  two sha256 entries inside that header (`hdr+0x090` and `hdr+0x0e8`, over sector
  ranges given at `hdr+0x078` / `hdr+0x0d0`, relative to the header). `verify`
  checks both, and it has to: because those hashes live *inside* the signed
  header, an image with a stale one carries a perfectly valid signature and is
  still rejected by the SPL at boot.
- **`uboot.img` / `boot.img`** — the FIT metadata: the whole device-tree
  *structure*, plus the properties of the nodes named in `hashed-nodes`. The
  external payloads (kernel, DTB, ramdisk, resource) are bound in through their
  `sha256` hash nodes, which are covered. To check the payloads themselves:
  ```bash
  python3 $SB/verify-fit-payloads.py payloads boot.img
  ```
- **rootfs** — exactly the first `<image>.size` bytes, hashed with BLAKE2b-512.
  The partition is padded beyond that, and the padding is deliberately not
  covered.
- **Not covered by any signature:** `oem.img`, `userdata.img`, `env.img`. The
  `.minisig` files present for `oem`/`userdata` are produced by the same build
  hook but nothing verifies them at boot.

## 2. Reproducibility

A signed image is **not** byte-reproducible, for two reasons that have nothing
to do with the source: the RSA-PSS salt is random, and mkimage stamps a live
wall-clock `timestamp` into the signature node. Both live *outside* the signed
region, so they can be zeroed without invalidating anything.

`canonicalise` zeroes exactly those bytes, plus the embedded public key:

```bash
for f in download.bin idblock.img; do python3 $SB/rkloader.py canonicalise $f; done
for f in uboot.img boot.img;      do python3 $SB/fitsign.py  canonicalise $f; done
sha256sum download.bin idblock.img uboot.img boot.img
```

Do the same to a rebuild from the pinned commit and compare the hashes. Verified
behaviour of the canonical form:

- **Stable across independent signing runs** — different salt, different
  timestamp, identical canonical bytes. All four artifacts.
- **Key-independent** for `download.bin`, `idblock.img` and `boot.img`: an image
  re-keyed to a completely different RSA key canonicalises to the same bytes.
- **Not key-independent for `uboot.img`**, by construction — it embeds the
  public key that U-Boot uses to verify `boot.img`, inside its uncompressed
  `fdt` payload, and that payload's hash is covered. Rebuild with the *same
  public key* (which is published, so anyone can) and it matches.

For the rootfs, compare the image directly — it carries no key-dependent bytes:

```bash
head -c "$(cat rootfs.img.size)" rootfs.img | sha256sum
```

To rebuild, follow [reproducibility.md](../reproducibility.md), using the
`seedsigner-os` commit and app ref recorded in `/etc/seedsigner-os-release`
inside the image. Build with `SEEDSIGNER_FIT_SIGNATURE=1` — comparing a signed
release against an *unsigned* rebuild will not work, because signed builds bake
the kernel command line into the DTB (see `apply_signed_nand_bootargs`).

## Limits

- This verifies files, not a running device. It cannot tell you whether a board
  has actually been fused, or what key it was fused to — Linux cannot read the OTP
  hash back (see [secure-boot.md §3.5](secure-boot.md#35-which-key-is-a-fused-board-expecting)
  for the ways that do work).
- `update.img` is a repack of the other images; verify the components, not the
  bundle.
- These verifiers have been validated against every signed artifact this repo
  has produced, and against RFC 8032 / the vendor binaries where applicable.
  They have **not** yet been used to gate a release.

## See also

- [secure-boot.md](secure-boot.md) — the hub: background, signing a release (all four methods),
  burning the fuse and recovery, future work, findings. Its
  [§8 Links and resources](secure-boot.md#8-links-and-resources) lists every related document,
  tool and external reference.
- [airgapped-signing.md](airgapped-signing.md) — the signature formats being verified.
