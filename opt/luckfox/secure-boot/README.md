# Luckfox secure boot — bench tooling

**These are manual bench tools. Nothing here runs during a normal image build,
and no SeedSigner build signs anything or burns a fuse.** They exist to *test*
Rockchip secure boot on sacrificial RV1103/RV1106 hardware.

Start with the process doc: [`docs/luckfox/secure-boot-bench-procedure.md`](../../../docs/luckfox/secure-boot-bench-procedure.md).
Background, threat model and consequences: [`docs/luckfox/secure-boot.md`](../../../docs/luckfox/secure-boot.md).

## Contents

| File | What it does |
|---|---|
| `sign-secure-boot.sh` | Generate/load an RSA key, sign the loader + idblock (+ uboot/boot with a build tree), verify offline, print the OTP hash a burn would write. Never flashes, never burns. `--burn` only *arms* the fuse write and refuses without an explicit confirm token. |
| `enable-fit-signature.sh` | Turn on `CONFIG_FIT_SIGNATURE` / `CONFIG_SPL_FIT_SIGNATURE` in a **checked-out SDK's** U-Boot defconfig. Opt-in on purpose (see below). |

## Why these are not build patches

The auto-applied SDK patches in `../patches/luckfox-sdk/` run on *every* build.
Signature **enforcement** there would brick every normal build, because a build
whose images are not subsequently signed would refuse to boot. Enforcement must
be opt-in and paired with a signing step, so it lives here as a manual script.

## Prerequisites

- The `rkbin` signing tools (`rk_sign_tool`, `fit-sign.sh`) from
  <https://github.com/3rdIteration/rkbin> — also vendored in a built SDK at
  `sysdrv/source/uboot/rkbin/tools/`. Point `--tools` at whichever you use.
- `rkdeveloptool` (same repo) for USB flashing, board in Maskrom.
- A **sacrificial** board. The OTP burn is irreversible.

## Quick start (safe — no fuse)

```sh
mkdir -p ~/keys ~/images && cp <flash-folder>/{download.bin,idblock.img} ~/images/
./sign-secure-boot.sh gen-key --keys ~/keys --bits 2048 --tools <rkbin/tools>
./sign-secure-boot.sh sign    --keys ~/keys --images ~/images --tools <rkbin/tools>
```

That signs, verifies, and prints the OTP hash — all reversible. The irreversible
burn is a later, explicit step covered in the procedure doc.
