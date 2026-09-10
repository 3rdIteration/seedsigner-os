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

**A. Generated key (simplest).**

```sh
mkdir -p ~/keys
bash "$SB/sign-secure-boot.sh" gen-key --keys ~/keys --bits 2048 --tools "$TOOLS"
```

**B. BIP85-derived key from a SeedSigner (reproducible backup).** Validated: the
fork's `bip85_rsa_from_root()` returns a PyCryptodome `RSA` object
(`gpg_views.py`, app `828365`, `MIN_RSA_KEY_BITS = 2048`), and a PyCryptodome
`export_key('PEM')` is accepted by `rk_sign_tool` (test: `loading key ok /
signing ok / verifying ok`). No GPG round-trip is needed — export the RSA object
straight to PEM:

```python
# inside the SeedSigner env, from the BIP85-derived key object
open("private_key.pem","wb").write(key.export_key("PEM"))
open("public_key.pem","wb").write(key.publickey().export_key("PEM"))
```

Drop those two files in `~/keys` and skip `gen-key`. The signing key is then
reproducible from the BIP39 seed + derivation path — the whole backup advantage.

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

The `seedsigner-os` Docker build wipes and re-clones the SDK each run and never
signs, so enforcement is added to a **standalone SDK checkout** instead:

```sh
# lay down the pinned SDK (the seedsigner-os build's own helper does this):
bash <seedsigner-os>/opt/luckfox/prepare-sdk-checkout.sh ~/sdk-parent \
     https://github.com/3rdIteration/luckfox-pico.git
SDK=~/sdk-parent/luckfox-pico

bash "$SB/enable-fit-signature.sh" "$SDK"     # sets CONFIG_(SPL_)FIT_SIGNATURE=y
cd "$SDK" && ./build.sh lunch                 # pick RV1103_Luckfox_Pico_Mini
./build.sh                                    # or ./build.sh uboot for just the loader chain
```

The exact defconfig it edits:
`$SDK/sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig`.

> An enforcing build whose images are **not** signed will not boot. That's why
> Stage 2 (sign) always follows Stage 1, and why enforcement is never in the
> auto-applied build patches.

## Stage 2 — sign the whole chain

With a build tree, `fit-sign.sh` signs loader + idblock + `uboot.img` +
`boot.img` in one pass (the prebuilt flash folder can only do loader + idblock):

```sh
bash "$SB/sign-secure-boot.sh" sign --keys ~/keys \
     --images ~/out --build-tree "$SDK/output/image" --tools "$TOOLS"
```

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

> The prebuilt-folder path instead uses `rk_sign_tool ss --flag 0x20`, where
> `0x20` is documented for RK3308/PX30, **not RV1106**. Prefer the build +
> `--burn-key-hash` path; treat the flag path as unverified.

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
