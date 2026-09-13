# PUBLIC dev key — NOT a secret

`dev.key` / `dev.pubkey` here are an **intentionally published** Ed25519
minisign keypair. The private key is committed to this repo on purpose (it is
encrypted with the passphrase `seedsigner-dev`, which is also public — see
below). **It is not secret and must never be used as a real rootfs-signing key.**

## Why it exists

With `SEEDSIGNER_FIT_SIGNATURE=1`, `os-build.sh` signs the rootfs volume's
logical UBIFS contents with minisign during the build (hooked into the SDK's
`mkfs_ubi.sh`) and embeds the public key + signature in the initramfs that is
packed into the signed `boot.img`. That signing step needs *some* key at build
time, and it must be able to run unattended — no interactive passphrase prompt.

Using a **fixed, public** key with a **known, documented** passphrase instead of
a fresh random one gives two properties that a throwaway key does not (same
rationale as [`../dev-keys/README.md`](../dev-keys/README.md)):

1. **Determinism.** minisign signatures are deterministic when the trusted
   comment is fixed (`-t seedsigner-os-rootfs`, no timestamp), so the same key
   over the same rootfs bytes produces a byte-identical `.minisig` every build —
   the signed image stays reproducible.
2. **A recoverable failure mode.** A board that boots this initramfs verifies
   against the *embedded* public key, not against anything on the untrusted
   volume. If someone ships a rootfs signed with this public key, any future
   build can still produce images it will accept — the device is unsecured but
   never bricked by a discarded random key.

## What it does NOT give you

- **No security.** Anyone holding this repo can sign a rootfs that these
  initramfses will accept. Real protection requires signing with a **secret**
  key you hold: set `SEEDSIGNER_ROOTFS_KEY_DIR` to a dir containing your own
  minisign `dev.key`/`dev.pubkey`, and `SEEDSIGNER_ROOTFS_KEY_PASSPHRASE` to its
  passphrase. The initramfs then embeds *your* public key, so only images you
  sign will verify.

## Key identity

SHA-256 of `dev.pubkey`: `324f4a638edc35c3e709d1569ad8ec3a5cced2ca5995d088eae703f7434a6878`

Any initramfs embedding a pubkey with this hash is running the public dev key
and provides **no** rootfs protection.

## Regenerating (only if the committed pair is ever compromised in practice)

```sh
minisign -G -s dev.key -p dev.pubkey   # passphrase: seedsigner-dev, twice
```

Then update the SHA-256 above and re-verify a full signed build end to end.
