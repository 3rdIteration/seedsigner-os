# Luckfox secure boot — bench procedure

A runnable checklist for testing Rockchip secure boot on a **sacrificial**
RV1103/RV1106 board. Read [`secure-boot.md`](secure-boot.md) first for what
secure boot does and does not protect, and the consequences of the fuse.

Everything up to Stage D is reversible (reflash). **Stage D burns a one-time
fuse and cannot be undone.** Do Stages 0–C on a board you have *not* fused, and
answer the recovery question in [§Recovery](#recovery-answer-this-before-stage-d)
before burning anything.

Commands below were validated in WSL against `rkbin` @ `3rdIteration/rkbin` and a
real `Luckfox_Pico_Mini_Flash` image; transcripts are quoted inline. Signing
tools: `sign-secure-boot.sh` and `enable-fit-signature.sh` in
[`opt/luckfox/secure-boot/`](../../opt/luckfox/secure-boot/).

## Prerequisites

```sh
git clone https://github.com/3rdIteration/rkbin.git      # signing + flash tools
TOOLS=$PWD/rkbin/tools                                    # rk_sign_tool, fit-sign.sh, rkdeveloptool
SB=<seedsigner-os>/opt/luckfox/secure-boot
```

`rk_sign_tool cc --chip 1106` for the Mini too — plain `1103` is rejected by the
tool's `setting.ini` support list; the Mini's U-Boot identifies as RV1106.

---

## Stage 0 — key + signing rehearsal (no board)

### Key options

`gen-key` writes **one** keys dir that every signing path here accepts:
`dev.key` / `dev.pubkey` / `dev.crt` (the triple Rockchip's `mkimage` FIT signing
needs — both the in-SDK build and `fit-sign.sh`), plus `private_key.pem` /
`public_key.pem` copies that `rk_sign_tool` reads for the prebuilt loader+idblock
path. The triple itself comes from the shared
[`make-dev-keys.sh`](../../opt/luckfox/secure-boot/make-dev-keys.sh); `gen-key`
wraps it and adds the `.pem` copies.

**A. Generated key (simplest).**

```sh
bash "$SB/sign-secure-boot.sh" gen-key --keys ~/keys --bits 2048
```

(No `--tools` needed for `gen-key` any more — it only uses `openssl`.)

**B. BIP85-derived key from a SeedSigner (reproducible backup).** Validated: the
fork's `bip85_rsa_from_root()` returns a PyCryptodome `RSA` object
(`gpg_views.py`, app `828365`, `MIN_RSA_KEY_BITS = 2048`), and a PyCryptodome
`export_key('PEM')` is accepted downstream (test: `loading key ok / signing ok /
verifying ok`). Export the RSA object to a PEM on the SeedSigner:

```python
# inside the SeedSigner env, from the BIP85-derived key object
open("bip85_signing.pem","wb").write(key.export_key("PEM"))
```

then wrap that PEM into the full `dev.*` triple (this also normalises it and
builds the `dev.crt` mkimage needs):

```sh
bash "$SB/sign-secure-boot.sh" gen-key --keys ~/keys --from bip85_signing.pem
```

The signing key is then reproducible from the BIP39 seed + derivation path — the
whole backup advantage.

> **Use a dedicated seed (or at least a dedicated index) for firmware signing.**
> This key carries the custody weight described in `secure-boot.md` §7: whoever
> holds the seed can regenerate it and sign firmware your fused devices trust. Do
> not reuse a wallet seed.

> **Size:** 2048 matches the shipped `sha256,rsa2048` FITs and the documented
> BootROM size. `rk_sign_tool` signs and verifies 4096 too, but whether the
> RV1106 BootROM accepts 4096 for the **loader** is unverified in silicon — a
> mismatch is only discovered *after* the fuse. Test 4096 on a spare board first.

### Sign + verify + see the OTP hash

```sh
mkdir -p ~/images && cp <flash-folder>/{download.bin,idblock.img} ~/images/
bash "$SB/sign-secure-boot.sh" sign --keys ~/keys --images ~/images --tools "$TOOLS"
```

Expected (validated) — both verifies pass and the OTP hash is printed:

```
[sign] verify loader: OK
[sign] verify idblock: OK
[sign] OTP hash a burn WOULD write (record this — it cannot be read back after fusing):
    ee 5a ff 64 51 7b 7c e4 78 81 f3 71 cc 77 52 6f
    dc ac a7 a1 77 59 3b 69 d5 18 73 5b df 12 94 31
```

Record that hash. After fusing there is no way to read it back to compare.

---

## Stage 1 — build U-Boot with signature enforcement

**The SDK signs the FIT *during* the build.** This is the key thing to
understand: `CONFIG_FIT_SIGNATURE=y` and in-build signing are coupled in this
SDK. `sysdrv/source/uboot/u-boot/scripts/fit-core.sh` runs `check_rsa_keys` and
`mkimage -k keys/` while packing `uboot.img`, so the u-boot build **aborts with
`ERROR: No keys/dev.key` unless `keys/dev.{key,pubkey,crt}` exist in the u-boot
tree.** There is no "compile enforcement in, sign later" — enforcement needs a
key present at build time. `mkimage` also embeds that key's public half into the
SPL DTB (the loader), so whatever key builds the image is the one the loader
trusts, until it is replaced in Stage 2.

Two ways to run the build:

**A. The `seedsigner-os` Docker build (what the bench uses).** Opt in with
`SEEDSIGNER_FIT_SIGNATURE=1`; the build enables `CONFIG_(SPL_)FIT_SIGNATURE`,
then lays down a **throwaway** RSA key so the build completes, and exports a
`fit-sign-tree-<profile>/` under `build-output/` for host re-signing:

```sh
SEEDSIGNER_FIT_SIGNATURE=1 ./build.sh --luckfox build --nand --model mini --variant dev
```

The throwaway key's pubkey is only a placeholder — Stage 2 replaces it with your
real key. (A host path can't be handed to the container, so on the Docker path
the real key is always applied post-build in Stage 2. `SEEDSIGNER_FIT_BITS`
overrides the throwaway size.)

**B. A standalone SDK checkout** (native, no Docker) — here you can build with
the real key directly, so the loader embeds the real pubkey and Stage 2 is only
needed to arm the burn:

```sh
bash <seedsigner-os>/opt/luckfox/prepare-sdk-checkout.sh ~/sdk-parent \
     https://github.com/3rdIteration/luckfox-pico.git
SDK=~/sdk-parent/luckfox-pico

bash "$SB/enable-fit-signature.sh" "$SDK"       # sets CONFIG_(SPL_)FIT_SIGNATURE=y
cp ~/keys/dev.key ~/keys/dev.pubkey ~/keys/dev.crt \
   "$SDK/sysdrv/source/uboot/u-boot/keys/"       # the real key the build signs with
cd "$SDK" && ./build.sh lunch                    # pick RV1103_Luckfox_Pico_Mini
./build.sh                                       # or ./build.sh uboot for just the loader chain
```

The exact defconfig `enable-fit-signature.sh` edits:
`$SDK/sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig`.

> An enforcing build whose images are **not** signed will not boot. That's why
> Stage 2 (sign) always follows Stage 1 on the Docker path, and why enforcement
> is never in the auto-applied build patches (it is opt-in only).

## Stage 2 — sign the whole chain with the real key

With a build tree, `fit-sign.sh` re-signs loader + idblock + `uboot.img` +
`boot.img` in one pass and **replaces the pubkey embedded in the SPL DTB** with
your real key's — so the throwaway build key never reaches a device (the prebuilt
flash folder can only do loader + idblock):

```sh
# Docker path (A): the tree the build exported
bash "$SB/sign-secure-boot.sh" sign --keys ~/keys \
     --images ~/out --build-tree build-output/fit-sign-tree-mini --tools "$TOOLS"

# Standalone-SDK path (B): the SDK's own output dir
bash "$SB/sign-secure-boot.sh" sign --keys ~/keys \
     --images ~/out --build-tree "$SDK/output/image" --tools "$TOOLS"
```

The `--build-tree` path uses `~/keys/dev.{key,pubkey,crt}` (via `fit-sign.sh`),
which `gen-key` produced above. On path B, if you already built with the real key
you can skip straight to the burn (Stage 4) — Stage 2 is then only needed to set
`--burn-key-hash`.

Verify offline before flashing (`vl`/`vb`/`vi` — all validated to work):

```sh
"$TOOLS/rk_sign_tool" cc --chip 1106
"$TOOLS/rk_sign_tool" vl --loader ~/out/signed/*loader*.bin
"$TOOLS/rk_sign_tool" vi --img    ~/out/signed/uboot.img
"$TOOLS/rk_sign_tool" vi --img    ~/out/signed/boot.img
```

## Stage 3 — flash signed images, still no fuse

Board in Maskrom (hold BOOT while connecting):

```sh
"$TOOLS/rkdeveloptool" ld                              # confirm Maskrom/Loader
"$TOOLS/rkdeveloptool" db ~/out/signed/download.bin
"$TOOLS/rkdeveloptool" ul ~/out/signed/download.bin
# write the remaining signed partitions with your usual flash tool
```

Boot and watch UART **@ 115200**. Unfused, it must boot normally (the loader
signature is ignored until the fuse exists). This proves the signed images are
bootable — the step most likely to fail silently and the last one you can retry.

The current unsigned baseline, for comparison (captured on the bench):

```
## Verified-boot: 0
FIT: no signed, no conf required
Verifying Hash Integrity ... sha256+ OK      <- integrity only, not a signature
```

## Recovery — answer this before Stage D

Burn **one** sacrificial board and immediately test recovery: does the **BOOT
button still enter Maskrom** on a fused board, and does Maskrom accept an
**unsigned** loader afterwards? The answer decides whether every later test is
recoverable or one-shot. (Independently, note UART CTRL+C reaches a U-Boot prompt
at `bootdelay=0` — bench-confirmed — so a fused production build also wants
`CONFIG_BOOTDELAY=-2` and `CONFIG_CONSOLE_DISABLE_CLI=y`.)

## Stage 4 — the burn (irreversible)

```sh
export SEEDSIGNER_SB_CONFIRM=I-UNDERSTAND-THIS-BURNS-A-FUSE
bash "$SB/sign-secure-boot.sh" sign --keys ~/keys \
     --images ~/out --build-tree "$SDK/output/image" --burn --tools "$TOOLS"
# reflash the resulting loader, reboot, watch UART
```

`--burn` maps to `fit-sign.sh --burn-key-hash` (sets `burn-key-hash 0x1` in the
SPL DTB; requires `CONFIG_SPL_FIT_HW_CRYPTO=y`, already on). On first boot the
loader writes the pubkey hash to OTP. Watch for:

```
otp write key success!!!
SecureBootEn = 1, SecureBootLock = 1
## Verified-boot: 1              <- was 0
```

> **Bench result (2026-09, RV1103 Mini):** the prebuilt-folder path's
> `rk_sign_tool ss --flag 0x20` is a **confirmed no-op on RV1106** — flashing a
> `--burn`-signed loader produced no `otp write key success`, `Verified-boot`
> stayed `0`, and the board was left unfused and fully recoverable. `0x20` is the
> RK3308/PX30 mechanism. **On RV1106 the burn only happens through the FIT
> `--burn-key-hash` path, which requires a real U-Boot build tree** (Stage 1–2 /
> `--build-tree`). The `sign-secure-boot.sh` prebuilt `--burn` path now refuses
> for this reason.

## Stage 5 — confirm enforcement

Flash an unsigned (or wrong-key) loader. It must now fail to boot. If it still
boots, the fuse did not take — the worst state, looking protected while not.

---

## Airgapped signing on a SeedSigner (design + status)

The goal: never let the private key touch the build machine — sign on an
air-gapped SeedSigner using a BIP85-derived key, via `rk_sign_tool`'s
extract/inject flow.

**Validated so far:**

- `ss --extract` then `sl`/`sb` emit the data to be signed as **bare 32-byte
  SHA-256 digests** (`si_usb_head.bin`, `si_flash_head.bin`, `si_idb_head.bin`).
  32 bytes each — trivially a QR code.
- `ss --inject` reads the signature back from a sibling file named
  `<digest>.sign.rsa` (confirmed: it finds and validates that file).
- The BIP85 RSA key can produce the signature (PyCryptodome / `cryptography`
  can PSS-sign a precomputed digest).

So the shape works: **build machine emits digests → SeedSigner signs them with
the BIP85 key → build machine injects.** Digests in, 256-byte signatures out,
both small enough for QR.

**Not yet cracked — the exact `.sign.rsa` encoding.** Every externally-produced
signature so far was rejected by inject as "invalid signature". Reverse-
engineering a tool-made signature showed **why, and the path to fix it**:

- The loader stores the pubkey modulus N **little-endian** (found at offset
  `0x3bc`, byte-for-byte equal to the key's N reversed). Rockchip uses
  little-endian bignums throughout, so the signature is almost certainly
  little-endian too — my attempts wrote it big-endian.
- Signing is randomized, i.e. genuinely **RSA-PSS** (two tool signatures of the
  same input differ), MGF1-SHA256.
- Remaining unknowns: the PSS **salt length** the tool expects, whether the
  `.sign.rsa` file is the bare little-endian signature or carries a small header,
  and confirming the digest is signed as-is (not byte-reversed first).

This is a bounded reverse-engineering task, not a fundamental blocker. Finishing
it turns "sign on the build host" into "sign on an air-gapped SeedSigner", which
is the ideal custody model for this key. Tracked as an open item; see
`secure-boot.md` §10.
