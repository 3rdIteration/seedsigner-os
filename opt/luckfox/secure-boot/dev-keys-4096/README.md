# PUBLIC dev key (RSA-4096) — NOT a secret

Same purpose and rules as [`../dev-keys/`](../dev-keys/README.md), but **4096-bit**
and a **distinct key** ("secondary dev key"). Used only when a build sets
`SEEDSIGNER_FIT_BITS=4096`, to test RSA-4096 secure boot on a sacrificial board.
The private key is committed on purpose; it is not secret and must never sign real
firmware.

## Why a separate 4096 key

Two things are validated at once by building/burning with this key:

1. **RSA-4096 in silicon.** `CONFIG_RSA_N_SIZE=0x200` shows the SPL/U-Boot RSA
   *verify* is sized for 4096, but the **BootROM** (separate mask ROM) is the real
   unknown for the loader. Only a fused board settles it.
2. **A different key than the 2048 `dev-keys/`.** Confirms the key-selection path,
   not just the one baked-in key.

## Danger unique to 4096 — potential HARD BRICK

Unlike the 2048 dev key (known-good on this SoC), **if the RV1106 BootROM does not
support a 4096-bit loader key, fusing this key's hash bricks the board permanently
— no loader will ever verify again, even though the key is public.** So:

- **Test UNFUSED first.** Flash a 4096-signed build on a *non-fused* board and
  confirm `sha256,rsa4096:dev … OK` at SPL and a normal boot. That proves the
  software (SPL/U-Boot) 4096 path with zero fuse risk.
- **Only then**, and only if you accept the brick risk, burn a 4096 hash on a
  sacrificial board to test the BootROM.

## How a 4096 build is wired (`SEEDSIGNER_FIT_BITS=4096`)

- This key replaces `dev-keys/` as the FIT signing key.
- `CONFIG_FIT_ENABLE_RSA4096_SUPPORT=y` is added to the U-Boot defconfig — that
  makes `fit_nodes.sh` emit `sha256,rsa4096` for `uboot.img` and makes
  `check_rsa_algo` expect `rsa4096`.
- The kernel `boot.its` signature `algo` is patched `sha256,rsa2048` →
  `sha256,rsa4096` (the template hardcodes it and ignores the config).

Public modulus SHA-256: `ccc545ca30c69ab4691a948b22d13a156ace6f5c629f33e99c0a260777c0a7a7`
