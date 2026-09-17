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
| FIT/loader RSA modulus | `c8b597b50bbb94c7c700011c2aefc43eb97d3b391da28bc130936d8d9f530f17` |
| rootfs minisign `dev.pubkey` (file hash) | `324f4a638edc35c3e709d1569ad8ec3a5cced2ca5995d088eae703f7434a6878` |

A device also tells you at boot: the verifier screen shows **yellow** instead of
green when either key is a published dev key, and orange *SECURE BOOT not
enabled* on an unfused board.

### What each signature actually covers

Worth knowing so the checks are not over-read:

- **Loader / idblock** — the 0x600-byte header only. That header contains the
  hashes the BootROM chain uses; the rest of the file is covered transitively.
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
  has actually been fused, or what key it was fused to — the OTP hash cannot be
  read back after burning.
- `update.img` is a repack of the other images; verify the components, not the
  bundle.
- These verifiers have been validated against every signed artifact this repo
  has produced, and against RFC 8032 / the vendor binaries where applicable.
  They have **not** yet been used to gate a release.
