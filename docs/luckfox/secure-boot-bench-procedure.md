# Luckfox secure boot — bench procedure

A runnable checklist for testing Rockchip secure boot on a **sacrificial**
RV1103/RV1106 board. Read [`secure-boot.md`](secure-boot.md) first — §1 for what
secure boot does and does not protect, §2 for the ways to sign a release, and §3
for arming, the consequences of the fuse, and recovery. This document is the
step-by-step bench version of §3.

Everything up to Stage D is reversible (reflash). **Stage D burns a one-time
fuse and cannot be undone.** Do Stages 0–C on a board you have *not* fused, and
answer the recovery question in [§Recovery](#recovery--answer-this-before-stage-d)
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
> This key carries the custody weight described in `secure-boot.md` §1.1: whoever
> holds the seed can regenerate it and sign firmware your fused devices trust. Do
> not reuse a wallet seed.

> **Size: use 2048.** `rk_sign_tool` signs and verifies 4096 too, but the SPL's
> hardware-crypto verify is hardcoded to RSA-2048 and rejects anything else with
> `-EINVAL` before the BootROM is ever reached (bench-confirmed 2026-09-12,
> `secure-boot.md` §6.6). **Do not fuse a 4096 hash.**

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

Record that hash. After fusing, Linux cannot read it back; the only other
record is the burning idblock's SPL `hash@np` (`secure-boot.md` §3.5).

---

## Stage 1 — build a fully-signed image

**The build signs the whole chain in place.** With `SEEDSIGNER_FIT_SIGNATURE=1`:

1. `CONFIG_(SPL_)FIT_SIGNATURE=y` is set in the u-boot defconfig, and the
   committed **PUBLIC dev key**
   ([`secure-boot/dev-keys/`](../../opt/luckfox/secure-boot/dev-keys/)) is placed
   in the u-boot tree (`apply_fit_signature_config`). The u-boot build then signs
   `uboot.img` and embeds that key's public half into the SPL DTB (the loader).
2. **After** the firmware build, `sign_boot_image` signs `boot.img` too, via the
   SDK's own `scripts/fit.sh --boot_img` — because nothing else in this SDK ever
   signs `boot.img` (`mk-fitimage.sh` packs it with the `dev` signature *template*
   and no `-k`). Without this step an enforcing u-boot rejects `boot.img` at boot
   (`Failed to verify required signature 'key-dev'`) and falls back to maskrom.

So the whole chain — loader → `uboot.img` → `boot.img` — is signed by one key,
and **the direct build output boots as-is.** No separate signing pass is needed.

```sh
SEEDSIGNER_FIT_SIGNATURE=1 ./build.sh --luckfox build --nand --model mini --variant dev
```

The dev key is **fixed and public** on purpose: it keeps the signed build
reproducible, and if you burn OTP with it the board fuses to a key everyone has —
**recoverable (still updatable) rather than a permanent brick** — though it grants
no protection and the board can then never move to a real key. See
[`secure-boot/dev-keys/README.md`](../../opt/luckfox/secure-boot/dev-keys/README.md).

> **Testing with the dev key (Stage 3 straight after Stage 1):** flash the direct
> output. `## Verified-boot: 0` (unfused) but the software signature checks are
> live, so this proves the signed chain boots before you ever touch a fuse.

> **A signed FIT disables runtime device-tree edits — bake anything that relied on
> them.** U-Boot won't rewrite a signed, conf-required FIT's DTB at boot, so two
> things that normally happen at runtime break on a signed build and must be baked
> into the DTB at build time. The opt-in build already does both for the Mini:
> - **Kernel command line** — the SDK injects the NAND `root=ubi0:rootfs …` at
>   runtime; signed, it uses the DTB's baked SD default and hangs at "Waiting for
>   root device". `apply_signed_nand_bootargs` bakes the NAND cmdline in.
> - **SPI display** — `luckfox-config` enables `&spi0`/`spidev0.0` via a runtime
>   configfs overlay that `dtc`-core-dumps on a signed build (no `__symbols__` to
>   resolve `&spi0`), so the screen stays black. `apply_spi_display_dts` enables
>   SPI statically (pinctrl **without** MISO — that pin, RK_PC3, is the panel
>   reset). Screen + camera confirmed working on the fused board (2026-09-12).
>
> If you add any peripheral that depends on a boot-time DTB fixup or overlay,
> expect the same and bake it in statically for the signed build.

**Building with a real secret key.** Replace the dev key with your own before the
build so the loader/uboot/boot are signed by it:

- **Native `build-local.sh`:** set `SEEDSIGNER_FIT_KEY_DIR=<dir with
  dev.{key,pubkey,crt}>` (generate with
  [`secure-boot/make-dev-keys.sh`](../../opt/luckfox/secure-boot/make-dev-keys.sh),
  including `--from` a BIP85 PEM). A host path resolves natively here.
- **Docker:** a host path can't be handed to the container. Either use the native
  path above, or (advanced) mount your key dir in and point `SEEDSIGNER_FIT_KEY_DIR`
  at the mount.

## Stage 2 — (legacy) host re-sign — NOT used on this SDK

> **This SDK does not support the `fit-sign.sh` host re-sign flow.** `fit-sign.sh`
> needs a `fit_signcfg/sign.readonly_config` carrying the SPL/uboot checksums and
> a `MINIALL.ini`, and **nothing in this luckfox SDK ever generates it** (checked:
> no `-k`, no `fit-sign`, no `sign.readonly_config` emission anywhere in
> `project/build.sh`). The build in Stage 1 signs everything in place instead, so
> the raw output is already bootable and — when built with your real key — already
> protected. The `sign-secure-boot.sh --build-tree` path and the exported
> `fit-sign-tree/` remain only for a future SDK that emits that config; skip them.

The rest of this section (the old `fit-sign.sh` invocation) is retained below for
reference only.

## Stage 2 (reference only) — sign the whole chain with the real key

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
button still enter Maskrom** on a fused board, and does Maskrom accept a
**dev-key-signed** loader afterwards? The answer decides whether every later test
is recoverable or one-shot. (Independently, note UART CTRL+C reaches a U-Boot
prompt at `bootdelay=0` — bench-confirmed — so a fused production build also wants
`CONFIG_BOOTDELAY=-2` and `CONFIG_CONSOLE_DISABLE_CLI=y`.)

> **Answered on the bench (2026-09-12).** BOOT still enters Maskrom on a fused
> board; it accepts a **dev-key-signed** loader and **rejects** an unsigned one.
> Reflashing works with the vendor SocToolKit in **partition (Download) mode** so
> long as the `DownloadBin` entry is the *signed* `download.bin`, and also via
> **Firmware → `update.img` → Upgrade** (which carries the signed loader inside the
> `.img`). So a board fused to the public dev key is fully recoverable — the
> committed dev key is public, so anyone can produce a loader it accepts.

> **Re-signed (non-dev) keys (2026-09-21).** A board fused to a re-signed key
> went straight to maskrom after the burn and refused every `download.bin`,
> until two defects were fixed. Neither one shows on an unfused board:
> a stale PKA constant in the re-keyed loader header, and a 1970-01-01
> `releaseTime` in every CI `download.bin`
> ([secure-boot.md §6.8](secure-boot.md#68-bench-first-fuse-to-a-re-signed-key-2026-09-21)).
> Before Stage 4, every one of these must pass on the exact files you will flash:
>
> ```sh
> python3 "$SB/rkloader.py" inspect idblock.img     # "OTP key hash" == "SPL burns", no "!! FUSED BOARD"
> python3 "$SB/rkloader.py" verify  download.bin --pubkey your.pub
> python3 "$SB/luckfox_release.py" check <release folder>
> ```
>
> Also keep a `download.bin` for the new key on hand, one that `rkloader.py verify`
> passes, before burning. If the board ever sits in maskrom, recover it with
> [soctoolkit-cli.md](soctoolkit-cli.md) (`db`, then `wl`).

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

## Stage 6 — rootfs verification (initramfs verifier)

With `SEEDSIGNER_FIT_SIGNATURE=1`, the signed `boot.img` carries a verifier
initramfs that minisign-checks the rootfs volume before mounting it (§5.2 in
`secure-boot.md`). One image covers both board states — test all three:

**Fused board.** LCD: orange *Verifying rootfs Signature* → pass screen. The
pass screen's colour and text depend on which keys signed this build (see
**Dev-key indicator** in §5.2 of `secure-boot.md`): with the committed PUBLIC
dev keys it is yellow *PASSED / FIT: dev / rootfs: dev*; only a build signed
with real secret keys shows green *PASSED / rootfs signature valid*. UART
(`rootfs-verify:` prefix): `verifying minisign signature (streaming …)`, then
`signature OK`. Takes ~15 s on the 93 MiB Mini NAND partition — that is the
full-volume read, not a hang.

**Unfused board, same image.** LCD: orange *SHIELDSIGNER / SECURE BOOT not
enabled*, held ~5 s, then normal boot. UART: `secure boot NOT fused
(fuse.programmed=0 on cmdline, no =1) — skipping rootfs verification`. If a
*fused* board shows this instead, the fuse state is being misread — stop and
investigate (see `secure-boot.md` §6.7, row E4, for how the first attempt failed exactly this way).

**Tamper test (dev build, ADB).** Flip a few bytes in the volume, reboot:

```sh
dd if=/dev/ubi0_0 of=/tmp/v bs=4096 count=1
printf 'X' | dd of=/tmp/v bs=1 seek=100 conv=notrunc
dd if=/tmp/v of=/dev/ubi0_0 bs=4096 count=1
reboot
```

Expected: red *FAILED / rootfs signature mismatch / press KEY_DOWN* and a halt.
Pressing the HAT key (KEY_DOWN on Mini) boots an **UNVERIFIED** rootfs — the
deliberate physical escape hatch; UART logs `WARN: … continuing with UNVERIFIED
rootfs`. Restore by reflashing the `rootfs` partition from the build output.

---

## Airgapped signing on a SeedSigner

Implemented. The private key can stay on a SeedSigner (BIP85-derived) for every
tier: the PC writes 32–64-byte digests to a MicroSD card, the device signs them
(Sign Digest, or the guided Air-Gap Re-Key), and `tools/airgap-sign.py` splices
the signatures back. See [secure-boot.md §2.4](secure-boot.md#24-air-gapped-signing)
for the procedure and [airgapped-signing.md](airgapped-signing.md) for the formats.

This section used to record the attempt to finish `rk_sign_tool`'s
extract/inject route (the `.sign.rsa` encoding). That route became unnecessary
once the loader signature format was recovered directly (RSA-PSS, saltLen 32,
little-endian — `secure-boot.md` §6.2, Q16), and `rkloader.py` now does the
digest and splice itself.
