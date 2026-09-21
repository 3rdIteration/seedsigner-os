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

The one-command form is `tools/airgap-sign.py` (below); the raw commands are:

```bash
SB=opt/luckfox/secure-boot

# On the build host: emit what needs signing
python3 $SB/rkloader.py digest download.bin -o out/download.digest
python3 $SB/rkloader.py digest idblock.img  -o out/idblock.digest
python3 $SB/fitsign.py  digest uboot.img    -o out/uboot.digest
# boot.img's digest comes LAST: on a re-key it depends on the tier-C injection below
python3 $SB/minisign.py digest rootfs.img   -o out/rootfs.digest   # SD/squashfs bundles only!

# ... transfer out/ to the signer, sign, bring signatures back ...

# On the build host: splice, verifying as you go
python3 $SB/rkloader.py splice download.bin --sig sigs/download.sig
python3 $SB/rkloader.py splice idblock.img  --sig sigs/idblock.sig
python3 $SB/fitsign.py  splice uboot.img    --sig sigs/uboot.sig --pubkey release.pub
# tier C: inject the returned .minisig into boot.img's initramfs, then seal it
python3 $SB/luckfox_release.py inject <bundle> --minisig sigs/rootfs.minisig \
        --pubkey release-rootfs.pub [--fit-pubkey release-rsa.pub]
# (boot.digest was emitted AFTER the injection; splice its signature back)
python3 $SB/fitsign.py  splice boot.img     --sig sigs/boot.sig   --pubkey release-rsa.pub
cp sigs/rootfs.minisig rootfs.img.minisig    # sidecar for host-side verification
```

Two things the raw commands get wrong if you are not careful:

* **NAND bundles.** What tier C signs is the *logical UBI volume*, not the bytes
  of `rootfs.img` (UBI rewrites erase counters, so the raw image is not stable).
  `minisign.py digest rootfs.img` hashes the file and is only correct for
  SD/squashfs bundles; on NAND use `luckfox_release.rootfs_prehash()` — which
  streams volume 0's data LEBs in logical order, exactly what the device reads
  from `/dev/ubi0_0`. The signed size comes from `ROOTFS_SIGNED_SIZE` in
  boot.img's `/init`, not a `.size` sidecar. `tools/airgap-sign.py` does this
  automatically per bundle type.
* **Ordering on a re-key.** `boot.img`'s digest covers its ramdisk, and the
  tier-C signature lives *in* that ramdisk — so inject first, then emit
  `boot.digest`. The rootfs digest itself depends on nothing, which is what lets
  a low-memory signer do it in a first round-trip.

`rkloader.py splice` refuses a signature that does not verify against the key
embedded in the image, and `luckfox_release.py inject` refuses a `.minisig`
that does not cover exactly this folder's rootfs — so a wrong key, wrong
endianness or stale digest fails loudly rather than producing an unbootable
image.

### tools/airgap-sign.py

The PC half of the device **Sign Digest** flow (and of the raw commands above),
in one command per direction:

```bash
# (only when moving off the bundle's current boot key) round 0: embed the new
# RSA public key into download.bin / idblock.img / uboot.img - public halves
# only, read from release-rsa.pub on the card (Export Pubkeys or Sign Digest).
python3 tools/airgap-sign.py rekey   <bundle> --card /media/sdcard

# prepare the card for the signer (writes <card>/seedsigner-release-sign/)
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard [--only a,b,c]

# toggle the forced rootfs check without a private key here: rework boot.img's
# initramfs locally, drop any stale update.img, leave boot.digest on the card.
# The PC-side counterpart of the app's Force Rootfs Check action - use it when
# the board is too small to run that (it crashes on the Pico Mini).
python3 tools/airgap-sign.py force   <bundle> --card /media/sdcard [--off]

# after the device has written the signatures back: splice everything, verify.
# Sign Digest also wrote release-rsa.pub / release-rootfs.pub into the folder, so
# no --*-pubkey flags are needed; they only override those copies.
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard \
        [--rsa-pubkey F] [--rootfs-pubkey F] [--no-check]
```

`digests` writes `manifest.txt` plus one `.digest` per artifact (UBI-aware for
NAND bundles). `splice` performs the tier-A/B splices, the tier-C injection and
re-seal, fixes any sd_update.txt write lengths the rework changed, and finishes
with a full `check_release` — it exits non-zero if anything does not verify.
`force` is one such round-trip scoped to boot.img: after its Sign Digest pass,
a plain `splice` (no flags) splices the signature back and must come out VALID,
since only that image changed.

**A re-key takes two signing round-trips**, in this order:

```bash
python3 tools/airgap-sign.py rekey   <bundle> --card /media/sdcard
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard --only rootfs
# ... device: Sign Digest ...
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard --only rootfs --no-check
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard \
        --only download,idblock,uboot,boot
# ... device: Sign Digest ...
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard   # RESULT: VALID
```

`rekey` clears the loaders' signatures and removes `update.img` (it packs a copy
of the old chain); mid-flow bundles are expected to fail `check_release`, which
is what `--no-check` is for. The order exists because of the two things above:
rootfs must be injected before `boot.digest` is emitted, and every digest must
be taken over the *re-keyed* images — a signature made against the old key's
header will not verify under the new embedded modulus, and `splice` refuses it.

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

Needed once, when moving off the published dev key. If the private key must not
touch this machine at all, use the air-gap form instead: `tools/airgap-sign.py
rekey` does exactly the public-key half of what is below (setkey + rehash on the
loaders and uboot), and the two signing round-trips that follow it supply the
signatures — see [tools/airgap-sign.py](#toolsairgap-signpy) for the sequence.

The commands here assume the private key is available locally. `uboot.img` is
the awkward one: it embeds the public key U-Boot uses to verify `boot.img`, so
changing keys changes a payload, which changes its hash, which is covered by the
signature — hence the `rehash` between `setkey` and `sign`.

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

### What `setkey` rewrites besides the modulus

The key node (`/signature/key-dev`) in the SPL DTB and in `uboot.img`'s fdt
payload carries more than the modulus, and **two of those fields are derived
from it**. Missing either one produces an image that every *software* verifier
accepts but the board rejects:

| Field | Size / encoding | Derived as | Consumed by |
|---|---|---|---|
| `rsa,modulus` | 256 B big-endian | — (the key) | everything |
| `rsa,n0-inverse` | u32 BE | `-n⁻¹ mod 2³²` | the SW Montgomery path (`rsa_mod_exp_sw`) |
| `rsa,r-squared` | 256 B BE (or zeroed to a single u32 by the build's minimisation) | `2^(2·bits) mod n` | the SW path only |
| `rsa,np` | 256 B BE, value ≈133 bits | `⌊2^(bitlen(n)+132) / n⌋` | **the SKE engine** (`CONFIG_SPL_FIT_HW_CRYPTO=y`, non-V1 — the Luckfox build) |
| `hash@np/value` | 32 B (sha256) | see below | `rsa_burn_key_hash()` before an OTP burn |

Why `rsa,np` is the dangerous one: with HW crypto enabled, SPL verifies
`uboot.img` through the SKE engine, which does **not** recompute its reduction
constant from the modulus. It loads `rsa,np` verbatim (`RK_PKA_SET_NP`, no
validation) and exponentiates with it. A stale value — i.e. one still holding
the *old* key's constant after a re-key — makes the modular exponentiation come
out wrong, so PSS padding fails on-device with

```
padding_pss_verify: invalid pss padding (0xbc is missing)
Failed to verify required signature 'key-dev'
fit verify configure failed, ret=-1
```

while `rkloader.py verify`, `fitsign.py verify` and Rockchip's own host tool
all pass, because the software path never reads this field. That exact symptom
is what a BIP85 re-sign did until `set_pubkey()` learned to rewrite it.

The constant itself is what `rk_pka_calcNp_and_initmodop()` computes when the
engine has no stored value (`RK_PKA_CREATE_NP`): it divides `2^sizeN · 2¹³²` by
`n` (the shift-and-divide loop runs with `s = 132`, operand `2^sizeN`). The
formula above was verified byte-for-byte against the value Rockchip's mkimage
writes for the committed dev key, and `tests/test_rkloader.py` pins both it and
the burn hash as regression vectors.

**The burn pin.** `hash@np/value` is sha256 over the key material exactly as
`rsa_burn_key_hash()` lays it out in a calloc'd buffer — little-endian, with
the field sizes from rv1106's Kconfig (`CONFIG_RSA_N_SIZE=0x200`,
`E=0x10`, `C=0x20`; the N field zero-pads past the 256-byte modulus):

```python
def pka_barrett_np(n):                      # -> rsa,np value (int)
    return (1 << (n.bit_length() + 132)) // n

BURN_N_SIZE, BURN_E_SIZE, BURN_C_SIZE = 0x200, 0x10, 0x20   # rv1106 Kconfig

def burn_key_hash(n_be, e=65537):           # -> hash@np/value (32 bytes)
    np_be = pka_barrett_np(int.from_bytes(n_be, "big")).to_bytes(256, "big")
    data = (n_be[::-1].ljust(BURN_N_SIZE, b"\x00")          # n, LE, zero-padded
            + e.to_bytes(BURN_E_SIZE, "little")             # low 16 bytes of e, LE
            + np_be[::-1][:BURN_C_SIZE])                    # low 32 bytes of np, LE
    return hashlib.sha256(data).digest()
```

It is only consulted when `burn-key-hash = <1>` — but a mismatch there does not
skip the burn: SPL compares its freshly computed digest against the stored one
and **fails FIT verification**, rejecting boot. So a re-key must refresh it too,
or any later arm-burn on that image bricks the boot instead of burning.

Both fields are pure functions of the modulus (the exponent is 65537 in every
Rockchip key), so `rkloader.swap_pka_constants()` — called from both
`set_pubkey()` implementations — byte-searches the old derived values and
splices in the new ones, exactly like the modulus/n0/r² swaps. On builds where
the fields are absent or zeroed (SW-only, or `CONFIG_ROCKCHIP_CRYPTO_V1`, which
uses `rsa,c` instead) nothing matches and it is a no-op.

**Sources.** The on-device behaviour lives in the SDK's U-Boot:
`lib/rsa/rsa-verify.c` (`rsa_mod_exp_hw()`, `rsa_get_key_prop()`,
`rsa_burn_key_hash()`), `drivers/crypto/rockchip/crypto_v2_pka.c`
(`rk_exptmod_np()`, `rk_calcNp_and_initmodop()`, `RK_PKA_BARRETT_IN_WORDS=5`)
and `common/image-sig.c` (`fit_config_check_sig()` → the burn call). The host
side is Rockchip's rkbin tooling: `mkimage -k <keydir> -K <dtb>` writes all of
these properties when it signs, and `fit-sign.sh` minimises them afterwards
(zeroing `rsa,c`/`hash@c` for non-V1 HW builds — note it leaves `rsa,np` in
place). The Kconfig sizes come from the SDK's `configs/rv1106_defconfig`.

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

Arming works on re-signed images too: `set_pubkey()` refreshes `hash@np` for
the new modulus (see above), so an armed BIP85 loader burns *your* key hash —
not the dev key's, and not a mismatch that would reject boot.

## Changing the rootfs key

The rootfs signature, the Ed25519 key that checks it, and the signed size all
live **inside** the initramfs in `boot.img`'s FIT ramdisk slot; `rootfs.img`
carries no signature. So a rootfs re-sign leaves `rootfs.img` byte-identical and
rewrites `boot.img`: `luckfox_release.rework_initramfs()` first verifies the
rootfs against the key `boot.img` trusts now (refusing anything that does not
verify), signs it with the new key, replaces `/pubkey` and `/rootfs.sig`, updates
the pass-screen key classes in `/init`, and `fitsign.replace_payload()` puts the
new ramdisk back. `boot.img` then needs an RSA re-sign, which is why the device
tool does both keys in one **Resign Release**.

Detaching the signature from the initramfs, so routine releases need only an
Ed25519 signature, remains possible but is not implemented; it would change the
on-device format and need a fresh bench run.

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

The signers are stdlib-only Python, so they run on any SeedSigner OS target. The
practical limit is not CPU — RSA-PSS is one `pow()`, and hashing is C — but
where a ~225 MB image bundle can be staged:

- **La Frite, Pi 02W, Pi 2/4** — comfortable; can host the full
  bundle-in/bundle-out flow from removable media.
- **Luckfox Pico Max / Pi** — feasible on RAM (everything streams in 64 KiB
  chunks). NAND/eMMC builds get their MicroSD slot as removable storage from a
  device-tree override (`apply_sdmmc_dts_patch`); the SDK wired it as SDIO.
- **Luckfox Pico Mini (64 MB)** — carries the signers too: they are ~55 KB of
  stdlib and every heavy path streams, so a full mini-bundle re-sign peaks at
  ~14 MB of Python heap (measured in-memory against a production bundle). The
  app warns when free memory is low before running the heavy actions and points
  at Sign Digest as the fallback.
- **Any board, any time** — the *digest signer* role needs no storage at all:
  a few dozen bytes in, one signature out (below).

### Where Resign Release's keys come from

The app's **Tools → Luckfox Build Tools → Resign Release** first asks for a key source:

- **BIP85 Derive** — from a loaded seed and two child indexes (RSA-2048, Ed25519),
  as above. Nothing to store: the seed and indexes re-derive the keys.
- **Load from MicroSD** — pick one file per key.
- **Load from SeedKeeper** — pick one secret per key (any type; its contents are
  parsed the same way as a file). The keys are held in RAM only until signing.

Accepted formats: the RSA key as an unencrypted PEM or DER private key (PKCS#1 or
PKCS#8, 2048-bit, e = 65537); the Ed25519 key as an unencrypted minisign secret
key (`minisign -G -W`, or `minisign.py keygen -s`), a PKCS#8 PEM/DER Ed25519 key
(`openssl genpkey -algorithm ed25519`), or the bare 32-byte seed (raw or 64 hex
characters). Passphrase-protected minisign keys are refused on the device:
minisign's default scrypt parameters need about 1 GiB of RAM.

### Sign Digest — signing without a bundle

**Tools → Luckfox Build Tools → Sign Digest** signs bare digests instead of a
bundle, so any board can act as the signer with no storage at all (the digest
signer role from the air-gap table above). The PC lays the digests on a MicroSD
card; the device writes the signatures back into the same folder. Insert the card
before powering the board on — these images do not detect hot-swapped cards (see
[README](README.md#microsd-card)):

```
<card>/seedsigner-release-sign/
  manifest.txt        # what each file is and which tier it belongs to
  download.digest     # 32 B, SHA-256          (tier A)
  idblock.digest      # 32 B, SHA-256          (tier A)
  uboot.digest        # 32 B, SHA-256          (tier B)
  boot.digest         # 32 B, SHA-256          (tier B)
  rootfs.digest       # 64 B, BLAKE2b-512      (tier C)

# written back by the device:
  download.sig        # 256 B raw RSA-PSS, little-endian
  idblock.sig         # 256 B
  uboot.sig           # 256 B
  boot.sig            # 256 B
  rootfs.minisig      # minisign text format (~200 B)

# also written back by the device - the public halves of whatever keys it used,
# so the card is self-contained for `splice` (same names/formats as Export Pubkeys):
  release-rsa.pub     # PEM RSA-2048, only if a tier A/B digest was signed
  release-rootfs.pub  # minisign public key, only if rootfs.digest was signed
```

The digests are exactly what the CLI commands above emit (`rkloader.py digest`,
`fitsign.py digest`, `minisign.py digest --size N`), so a card prepared by hand
works too. The device refuses files of the wrong size (32 vs 64 bytes) with a
clear message, signs each file it recognises, and reports per-file results. RSA
signatures use the deterministic salt (`shake_256("seedsigner-pss-v1\0" || mhash)`),
so re-signing is idempotent; tier C carries a third-party minisign key's stored
`key_id` through, so signatures from such keys still verify.

On the PC side, `tools/airgap-sign.py` does both halves in one command each:
`digests <bundle> --card <mount>` writes the folder above; `splice <bundle>
--card <mount>` splices every returned signature back and verifies the whole
chain against the public keys. Because Sign Digest drops those keys into the
folder itself, `splice` needs no `--*-pubkey` flags in the normal case — it reads
`release-rsa.pub` / `release-rootfs.pub` from the card; the flags remain as an
override for cards signed by something else (e.g. a hand-run CLI signer).

## See also

- [verifying-a-release.md](verifying-a-release.md) — the other side: checking a distributed image
- [secure-boot.md](secure-boot.md) — design, threat model, consequences, bench results
- [secure-boot-bench-procedure.md](secure-boot-bench-procedure.md) — the staged hardware procedure
