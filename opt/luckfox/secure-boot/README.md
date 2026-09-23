# Luckfox secure boot — signing and bench tooling

**Most of this directory now runs during a normal image build.** Since
`5181cd1`, `signing: on` is the CI default: with `SEEDSIGNER_FIT_SIGNATURE=1`
the build signs the U-Boot FIT images *and* the rootfs, using the **committed
public dev keys** in `dev-keys/` and `dev-keys-rootfs/`. Those keys are not
secret, so a default build is signed but not protected — see each key dir's
README.

**No build ever burns a fuse.** The OTP burn stays opt-in behind
`SEEDSIGNER_FIT_BURN_KEY_HASH=1` plus an explicit confirmation token, and is
never set by CI.

| Runs in every signed build | Manual bench tools only |
|---|---|
| `make-dev-keys.sh`, `patch-mkfs-ubi-signing.sh`, `patch-mkfs-squashfs-signing.sh`, `dev-keys*/`, `initramfs*/`, `build-initramfs-binaries.sh` | `sign-secure-boot.sh`, `enable-fit-signature.sh`, `verify-fit-payloads.py` |

Start with [`docs/luckfox/secure-boot.md`](../../../docs/luckfox/secure-boot.md) — background, and
§2 for the four ways to sign a release: build-time (this directory, in-build), re-sign on a PC
(`rkloader.py` / `fitsign.py` / `minisign.py` with `tools/airgap-sign.py`), re-sign on a SeedSigner
(Resign Release), or air-gapped (`tools/airgap-sign.py` + Sign Digests on Card). The fuse-burn bench steps are
[`docs/luckfox/secure-boot-bench-procedure.md`](../../../docs/luckfox/secure-boot-bench-procedure.md).

## Contents

| File | What it does |
|---|---|
| `sign-secure-boot.sh` | Generate/load an RSA key, sign the loader + idblock (+ uboot/boot with a build tree), verify offline, print the OTP hash a burn would write. Never flashes, never burns. `--burn` only *arms* the fuse write and refuses without an explicit confirm token. |
| `enable-fit-signature.sh` | Turn on `CONFIG_FIT_SIGNATURE` / `CONFIG_SPL_FIT_SIGNATURE` in a **checked-out SDK's** U-Boot defconfig. Opt-in on purpose (see below). |
| `rkloader.py` | Sign / verify / inspect / re-key `download.bin` and `idblock.img` **offline, in pure Python** — no `rk_sign_tool`, no vendor blob. `digest` + `splice` are the air-gap boundary: 32 bytes out to the signer, 256 bytes back. Tested by `tests/test_rkloader.py`. |
| `fitsign.py` | Sign / verify / splice / canonicalise the U-Boot FIT images (`uboot.img`, `boot.img`) **offline, in pure Python** — no `mkimage`, no SDK. Re-derives exactly what mkimage signed from the `hashed-nodes` / `hashed-strings` properties the FIT already carries. Tested by `tests/test_fitsign.py`. |
| `minisign.py` | Sign / verify the **rootfs** with minisign (Ed25519) **in pure Python** — no `minisign-host` binary. `keygen --entropy` turns 32 bytes of BIP85 entropy straight into the keypair, so the rootfs key is reproducible from a seed and need never be stored. Byte-compatible with the vendored binary. Tested by `tests/test_minisign.py`. |
| `verify-fit-payloads.py` | Parse a FIT; list payloads and recomputed hashes, dump the signature node, or compare two images' payloads (release vs rebuild). |

## Why enforcement is not an auto-applied SDK edit

The build's automatic SDK customisations (`apply_sdk_patches` in `os-build.sh` /
`build-local.sh`, and the partition layout in `apply-partition-layout.sh`) run on
*every* build. Signature **enforcement** there would brick every unsigned build,
because a build whose images are not subsequently signed would refuse to boot.
Enforcement must therefore be opt-in and always paired with a signing step.

That pairing is what `SEEDSIGNER_FIT_SIGNATURE=1` does: `apply_fit_signature_config`
in `os-build.sh` / `build-local.sh` flips the defconfig *and* provisions the keys
*and* signs, as one unit. `enable-fit-signature.sh` is the standalone equivalent
for a hand-checked-out SDK, where you are doing the signing yourself.

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
