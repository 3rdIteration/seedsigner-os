# Air-gapped signing

Signing the Luckfox boot chain without the private key ever touching the build
host. Three signature tiers, three cadences, one pattern: **the build host emits
a digest, something else signs it, the build host splices the signature back.**

Nothing here needs `rk_sign_tool`, `mkimage`, `minisign`, the Rockchip SDK or a
build tree — the three signers are pure-Python stdlib and run anywhere, which is
what makes a SeedSigner viable as the signer.

> **Status.** The formats are validated against every signed artifact this repo
> produces (and, for minisign, byte-for-byte against the vendor binary). An
> offline-re-signed image has **not yet been booted on hardware.** Do that on a
> sacrificial, **unfused** board before trusting any of it. Nothing in this
> document burns a fuse.

## The three tiers

| Tier | Artifacts | Changes | Key | Tool |
|---|---|---|---|---|
| **A — firmware root** | `download.bin`, `idblock.img` | rarely | RSA-2048 | `rkloader.py` |
| **B — kernel** | `uboot.img`, `boot.img` | per release | RSA-2048 (same key) | `fitsign.py` |
| **C — payload** | `rootfs.img` / `rootfs.ubifs` | every release | Ed25519 | `minisign.py` |

## The air-gap boundary

Tiny in every tier, which is what makes QR transfer practical:

| Tier | Build host sends | Signer returns |
|---|---|---|
| A | 32 bytes (SHA-256) | 256 bytes |
| B | 32 bytes (SHA-256) | 256 bytes |
| C | 64 bytes (BLAKE2b-512) | a ~200-byte `.minisig` |

```bash
SB=opt/luckfox/secure-boot

# On the build host: emit what needs signing
python3 $SB/rkloader.py digest download.bin -o out/download.digest
python3 $SB/rkloader.py digest idblock.img  -o out/idblock.digest
python3 $SB/fitsign.py  digest uboot.img    -o out/uboot.digest
python3 $SB/fitsign.py  digest boot.img     -o out/boot.digest
python3 $SB/minisign.py digest rootfs.img   -o out/rootfs.digest   # reads rootfs.img.size

# ... transfer out/ to the signer, sign, bring signatures back ...

# On the build host: splice, verifying as you go
python3 $SB/rkloader.py splice download.bin --sig sigs/download.sig
python3 $SB/rkloader.py splice idblock.img  --sig sigs/idblock.sig
python3 $SB/fitsign.py  splice uboot.img    --sig sigs/uboot.sig --pubkey release.pub
python3 $SB/fitsign.py  splice boot.img     --sig sigs/boot.sig  --pubkey release.pub
cp sigs/rootfs.minisig rootfs.img.minisig
```

`rkloader.py splice` refuses a signature that does not verify against the key
embedded in the image, so a wrong key, wrong endianness or stale digest fails
loudly rather than producing an unbootable image.

## Deriving the keys from a BIP85 seed

Both keys can be reproduced from a BIP39 seed, so neither has to be stored.

**RSA (tiers A and B).** The SeedSigner fork's `bip85_rsa_from_root()` returns a
PyCryptodome RSA object; export it as PEM and hand it to the signer:

```python
open("bip85_signing.pem", "wb").write(key.export_key("PEM"))
```

`rkloader.py` and `fitsign.py` read that PEM directly (`--key`), as does
`make-dev-keys.sh --from` if you want the `dev.{key,pubkey,crt}` triple for an
in-build signed build.

**Ed25519 (tier C).** 32 bytes of BIP85 entropy become the minisign keypair
deterministically:

```bash
python3 $SB/minisign.py keygen --entropy <64 hex chars> -p rootfs.pub -s rootfs.key
```

Same entropy always gives the same keypair, so `rootfs.key` is a convenience,
not an asset — delete it and re-derive. Note the `key_id` is derived from the
public key rather than random, which is what makes this reproducible; a keypair
from `minisign -G` will have a random one.

## Swapping the chain to a new key

Needed once, when moving off the published dev key. `uboot.img` is the awkward
one: it embeds the public key U-Boot uses to verify `boot.img`, so changing keys
changes a payload, which changes its hash, which is covered by the signature —
hence the `rehash` between `setkey` and `sign`.

```bash
python3 $SB/rkloader.py setkey download.bin --pubkey new.pub
python3 $SB/rkloader.py sign   download.bin --key    new.key
python3 $SB/rkloader.py setkey idblock.img  --pubkey new.pub
python3 $SB/rkloader.py sign   idblock.img  --key    new.key

python3 $SB/fitsign.py setkey uboot.img --pubkey new.pub --old-pubkey old.pub
python3 $SB/fitsign.py rehash uboot.img
python3 $SB/fitsign.py sign   uboot.img --key new.key

python3 $SB/fitsign.py sign   boot.img  --key new.key   # embeds no key itself
```

Then confirm the whole chain verifies under the new key **and is rejected under
the old one**.

> `rkloader.py setkey` rewrites fields in the 0x600 header that are **not fully
> characterised** beyond the modulus. This is the least-proven step here. Test
> unfused.

Re-keying `idblock.img` changes the SPL DTB, which lives inside a hashed
component, so the component hash has to be refreshed before the header is
signed. `sign_buf()` does that for you; the ordering only matters if you drive
the pieces by hand.

## Arming the OTP burn

A loader whose SPL DTB carries `burn-key-hash = <1>` writes the public-key hash
to OTP on first boot and turns on secure boot **permanently**. That is normally
a build-time option (`SEEDSIGNER_FIT_BURN_KEY_HASH=1`), but it can be done to an
already-signed image:

```bash
python3 $SB/rkloader.py setburn idblock.img --confirm I-UNDERSTAND-THIS-BURNS-A-FUSE
python3 $SB/rkloader.py sign    idblock.img --key your.key
python3 $SB/rkloader.py verify  idblock.img --pubkey your.pub
```

The property costs 30 bytes and the DTB is followed by padding inside its
component, so the file length does not change. Validated against a real
`SEEDSIGNER_FIT_BURN_KEY_HASH=1` build: the armed DTB is byte-identical to the
one the SDK emits.

`setburn` clears the signature, so the image must be re-signed afterwards, and
it refuses without the confirmation token. **Arm only what you intend to fuse:
booting a board from an armed loader is the irreversible step, and if the key
whose hash gets burned is the published dev key, the board is permanently
fused to a key everyone has.**

## The rootfs key is not yet independently swappable

Today the rootfs signature and the signed size are baked **inside** the
initramfs that lives in `boot.img`'s FIT ramdisk slot, and the rootfs public key
is embedded there too. Consequences:

- Re-signing the rootfs **with the same key** is fine — replace
  `rootfs.img.minisig`.
- Changing the rootfs **key** requires rebuilding the initramfs and re-signing
  `boot.img`, which a post-build tool cannot do. It needs a build with
  `SEEDSIGNER_ROOTFS_KEY_DIR` set.

Detaching the signature from the initramfs — keeping only the public key inside
the signed image and moving the signature to a sidecar in the partition padding
— would make tier C fully independent of the RSA key, so routine releases would
need only an Ed25519 signature. That change is designed but not implemented; it
alters the on-device format and needs a fresh bench run.

## Smartcards

- **Tier C on an OpenPGP / SmartPGP card: viable.** minisign needs two raw
  Ed25519 signatures over short messages (the 64-byte digest, and
  `signature || trusted_comment`). An OpenPGP 3.4+ card with an EdDSA key signs
  the supplied message directly via `PSO:CDS`, reachable through
  `gpg-connect-agent 'SCD PKSIGN'` or direct APDU.
- **Tiers A and B on an OpenPGP card: not possible.** `PSO:CDS` applies PKCS#1
  v1.5 to a DigestInfo; the card cannot produce the RSA-PSS signature this chain
  requires, and the padding is fixed by the BootROM and the SPL hardware-crypto
  verifier, so it cannot be changed to suit the card. A PIV/PKCS#11 token
  exposing raw RSA (`CKM_RSA_X_509`, e.g. YubiKey PIV) works, as would a
  JavaCard applet exposing raw RSA.

## Running the signer on a SeedSigner

On a Pi or La Frite image the tooling is installed by the build
(`install_secure_boot_tools()` in [`opt/build.sh`](../../opt/build.sh)), from the
same copies in this repo that CI signs with:

| On the image | What it is |
|---|---|
| `/opt/secure-boot/{rkloader,fitsign,minisign}.py` | the signers as CLIs, for verifying or re-signing from a shell |
| `/opt/src/seedsigner/helpers/luckfox_secure_boot/` | the app's copies, backing **Tools → Re-sign Release** |

Both come from `opt/luckfox/secure-boot/`. The build **overwrites** the app's
vendored copies with this repo's, so a shipped image cannot run a drifted
version whichever app branch was cloned; a mismatch is reported during the
build. The app repo has its own sync test for development time.

So a single La Frite or Pi 02W image is both the GUI ceremony and a shell you
can verify a release from:

```sh
/opt/secure-boot/rkloader.py verify /mnt/microsd/release/idblock.img --pubkey mine.pub
```

The practical limit is not CPU — RSA-PSS is one `pow()`, and hashing is C — but
where a ~225 MB image bundle can be staged:

- **La Frite, Pi 02W, Pi 2/4** — comfortable; can host the full
  bundle-in/bundle-out flow from removable media.
- **Luckfox Pico Max / Pi** — feasible on RAM (everything streams in 64 KiB
  chunks), but the NAND/eMMC profiles currently have no usable MicroSD in Linux:
  the controller on the `sdmmc0` pins is configured as SDIO (`supports-sdio`,
  `non-removable`), so no `/dev/mmcblk1` appears. Fixing that is a device-tree
  change, not a runtime one.
- **Luckfox Pico Mini (64 MB)** — best-effort for bulk work.
- **Any board, any time** — the *digest signer* role needs no storage at all:
  32 bytes in, 256 bytes out over QR.

## See also

- [verifying-a-release.md](verifying-a-release.md) — the other side: checking a distributed image
- [secure-boot.md](secure-boot.md) — design, threat model, consequences, bench results
- [secure-boot-bench-procedure.md](secure-boot-bench-procedure.md) — the staged hardware procedure
