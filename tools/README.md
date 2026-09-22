# tools

Developer utilities that are not part of the build itself.

| Tool | Purpose |
| ---- | ------- |
| [`airgap-sign.py`](airgap-sign.py) | The PC half of the Luckfox air-gapped signing flow: emit digests for a signer, splice its signatures back. |
| [`imgdiff.py`](imgdiff.py) | Explain why two SeedSigner OS `.img` files are not byte-identical. |

## airgap-sign.py

```bash
python3 tools/airgap-sign.py rekey   <bundle> --card /media/sdcard [--rsa-pubkey F]
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard [--only rootfs]
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard \
        [--rsa-pubkey F] [--rootfs-pubkey F] [--no-check]
```

One command per card round-trip with the device's **Sign Digest** action (or any other signer):
`digests` writes `<card>/seedsigner-release-sign/` with a manifest and one `.digest` per artifact;
the device signs them and also drops the public halves of whatever keys it used into that folder as
`release-rsa.pub` / `release-rootfs.pub`; `splice` verifies and splices every returned signature back
into the bundle, injects a tier-C `.minisig` into `boot.img`'s initramfs (before `boot.sig`, which
covers that ramdisk), fixes any sd_update.txt write lengths the rework changed, and finishes with a
full release check. Because the card carries its own public keys, `splice` needs no `--*-pubkey`
flags in the normal case — they are only there to override the folder's copies (e.g. when signing was
done by something other than Sign Digest). The rootfs digest is UBI-aware — on NAND bundles it hashes
the logical volume exactly as the device streams it, not the raw file bytes.

`rekey` is round 0 of an air-gap **re-key** (moving a release off its current boot key): it embeds the
new RSA public key into `download.bin`, `idblock.img` and `uboot.img` using only the public halves —
the private key never touches this machine. It reads `release-rsa.pub` from the card (written by the
device's **Air-Gap Re-Key Round 0** or a previous **Sign Digest**), clears the loaders' signatures, refreshes
idblock's component hashes and uboot's payload hash, removes the stale `update.img`, and leaves
`boot.img` alone — its initramfs holds the rootfs key pair, which `splice` replaces via the tier-C
injection (that also sets `/init`'s pass-screen key classes). A full re-key then takes **two** signing
round-trips, in this order:

```bash
# round 0 - public halves only, no card signatures needed yet
python3 tools/airgap-sign.py rekey   <bundle> --card /media/sdcard

# round 1 - rootfs first, so boot.digest is taken over the FINAL initramfs
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard --only rootfs
# ... device: Sign Digest ...
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard --only rootfs --no-check

# round 2 - everything else, over the re-keyed images and the injected ramdisk
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard \
        --only download,idblock,uboot,boot
# ... device: Sign Digest ...
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard   # must print RESULT: VALID
```

The ordering is not optional: `boot.img`'s signature covers its ramdisk, and the tier-C injection
rewrites that ramdisk — so rootfs must be signed and injected before `boot.digest` is emitted. See
[docs/luckfox/airgapped-signing.md](../docs/luckfox/airgapped-signing.md) for why each step exists.

Python 3 standard library only (it imports the pure-stdlib signers from `opt/luckfox/secure-boot/`),
and it runs on Windows.

## imgdiff.py

```bash
python3 tools/imgdiff.py local.img ci.img
```

Reproducible-build triage. Narrows a mismatch from "the SHA-256 doesn't match" down to the individual
file inside the image, and for ELF binaries down to the individual embedded string that differs.
Exits `0` if the images are byte-identical, `1` if they differ.

Python 3 standard library only — no mtools, binwalk or loopback mount, and it runs on Windows.

What it walks:

1. MBR, disk-id and partition table
2. The pre-partition region (on lafrite, the pinned Amlogic bootloader blob at sector 1)
3. FAT geometry, volume serial and label
4. Every file on the FAT boot partition — metadata and SHA-256
5. For `Image`: the gzipped initramfs linked into the arm64 kernel, then every rootfs entry in the
   cpio (mode, uid/gid, mtime, size, sha256, archive order)
6. For any differing ELF: a diff of the multiset of embedded printable strings
7. For any differing squashfs: the `mkfs_time` header field

Step 5 works because the lafrite profile sets `BR2_TARGET_ROOTFS_INITRAMFS=y` with
`BR2_TARGET_ROOTFS_CPIO_GZIP=y` — there is no separate rootfs filesystem, so the whole userland is
reachable from the `.img` with no rebuild and no `--debug-rootfs` tarball. The other stages are generic
and still report usefully on Pi images, which do not carry their rootfs inside the kernel.

See [docs/agents.md](../docs/agents.md#verifying-reproducibility) for how to read the output — especially
the part about differences cascading, where the innermost file whose *content* changed is the root cause
and everything after it is just shifted offsets.
