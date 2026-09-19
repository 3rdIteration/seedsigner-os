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
- **Luckfox Pico Mini (64 MB)** — best-effort for bulk work.
- **Any board, any time** — the *digest signer* role needs no storage at all:
  32 bytes in, 256 bytes out over QR.

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

## See also

- [verifying-a-release.md](verifying-a-release.md) — the other side: checking a distributed image
- [secure-boot.md](secure-boot.md) — design, threat model, consequences, bench results
- [secure-boot-bench-procedure.md](secure-boot-bench-procedure.md) — the staged hardware procedure
