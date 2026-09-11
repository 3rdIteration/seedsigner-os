# PUBLIC dev key — NOT a secret

`dev.key` / `dev.pubkey` / `dev.crt` here are an **intentionally published**
RSA-2048 keypair. The private key is committed to this repo on purpose. **It is
not secret and must never be used as a real firmware-signing key.**

## Why it exists

This SDK signs the U-Boot FIT *during* the build: with `CONFIG_FIT_SIGNATURE=y`,
`scripts/fit-core.sh` runs `mkimage -k keys/` and aborts unless
`dev.{key,pubkey,crt}` are present. So an opt-in signed build
(`SEEDSIGNER_FIT_SIGNATURE=1`) needs *some* key at build time, and `mkimage`
embeds that key's public half into the loader (SPL DTB).

Using a **fixed, public** key here instead of a fresh random one gives two
properties that a throwaway key does not:

1. **Determinism.** The signed build is reproducible — the same key produces the
   same signatures every time. (The default *unsigned* build is unaffected
   either way; this whole path is off unless `SEEDSIGNER_FIT_SIGNATURE=1`.)
2. **A recoverable failure mode.** If someone builds, skips the re-sign step, and
   then runs the irreversible OTP burn, the board fuses to *this* key's hash —
   and because the key is public, anyone can still sign firmware the board will
   boot. It is unsecured, but not bricked. A random discarded key in the same
   scenario would be a permanent brick.

## What it does NOT give you

- **No security.** A build signed with this key provides zero secure-boot
  protection: the private key is public, so anyone can sign firmware for it.
  Real protection requires re-signing with a **secret** key you hold — see
  Stage 2 in [`../../../docs/luckfox/secure-boot-bench-procedure.md`](../../../docs/luckfox/secure-boot-bench-procedure.md).
- **No undo for a burn.** Fusing to this key is still a one-time OTP write. A
  board burned to the public dev key can never afterwards be moved to a real
  secret key — it is permanently *unsecurable* (though still bootable/updatable).
  Only burn on a sacrificial board.

## Normal, secure flow

Build (this key is embedded as a placeholder) → **Stage 2: re-sign with your
real secret key** (`fit-sign.sh` replaces the embedded pubkey with yours) →
flash unfused, confirm boot → only then Stage 4 burn, which anchors the board to
*your* key.

To use a real key at build time instead of this placeholder (native
`build-local.sh` path only — a host path can't be handed to the Docker build),
set `SEEDSIGNER_FIT_KEY_DIR` to a dir holding your own `dev.{key,pubkey,crt}`
(generate with [`../make-dev-keys.sh`](../make-dev-keys.sh)).

## Key identity

Public modulus SHA-256: `c8b597b50bbb94c7c700011c2aefc43eb97d3b391da28bc130936d8d9f530f17`

Any board whose loader embeds a pubkey with this modulus is running the public
dev key and is **not** protected.
