# ForgeBox: offline firmware signing with ShieldSigner / SeedSigner

This pairs the app's **Tools → ForgeBox Signing** flow with OS-provided
`forgebox_sign.py`. It signs ForgeBox's owner-authorized OTA format, using a
dedicated BIP85-derived secp256k1 key that never leaves the signer. It does not
turn a retail Keystone build into a ForgeBox-compatible port.

## Prerequisites and pairing

Build the app PR and OS PR together. The OS installs the protocol module at
`/usr/lib/seedsigner/secure-boot/forgebox_sign.py` in Pi/La Frite and Luckfox
builds that carry secure-boot tools. Existing `no-secure-boot-tools` opt-outs
remain respected and hide this app menu. No Node, npm or compiler is needed on
SeedSigner. Its existing `ecdsa==0.19.1` and `embit==0.8.0` dependencies supply
the signing primitives and BIP85 implementation.

For a desktop app checkout, set `SEEDSIGNER_SECURE_BOOT_DIR` to this OS checkout's
`opt/luckfox/secure-boot` directory. Do not point it at an untrusted card. The
app OS gitlink is a release pin: do not advance it until the paired release.

On the PC, install Python 3.10+, Node 24, and:

```powershell
python -m pip install ecdsa==0.19.1
npm install --prefix ./forgebox-tools forgebox-cli@1.2.0
$cli = (Resolve-Path ./forgebox-tools/node_modules/forgebox-cli).Path
$card = 'E:\'
```

Run the following from this OS repository. Substitute the actual removable-card
drive and firmware paths. The helper uses the official CLI **only for QuickLZ
compression and USB protocol**, and enforces the tested CLI version. This is a
desktop workflow; none of these PC dependencies belongs on the offline signer.

## 1. Recover and export the public key

Load the intended root seed (mnemonic plus passphrase, or an XprvSeed) on
SeedSigner. Open **Tools → ForgeBox Signing → Export BIP85 Public Key**, select
the seed and a dedicated index, review the path and complete public key, then
confirm export. The card receives only:

```
forgebox-signing/pubkey.pem
forgebox-signing/public.json
```

The path is standard BIP85 HD-seed WIF application `m/83696968'/2'/index'`: derive
the hardened child, run BIP85's HMAC-SHA512, take its first 32 bytes, and validate
the scalar. It is not the raw BIP32 child secret. An invalid scalar fails; it
never silently switches indexes. Do not use that same child for a wallet/funds.

Record the root backup, passphrase convention, index and public-key fingerprint.
Repeat export after independently restoring the root and verify the full public
key is identical **before** registering it. Copy `pubkey.pem` to a trusted PC-side
record such as `./forgebox-owner.pub.pem`; use that copy for later preparation
and assembly. No WIF or private PEM is exported or required.

## 2. One-time owner registration without a private key on the PC

This is an optional **live USB operation**, separate from firmware signing:

```powershell
$python = (Get-Command python).Source
node tools/forgebox-bridge.cjs register $cli ./forgebox-owner.pub.pem $card $python
```

Connect ForgeBox in its factory registration state first. The bridge reads the
factory version and requests a 32-byte nonce. It writes a registration request,
then waits while keeping the USB connection open. On SeedSigner choose **Sign
Request on Card**, review the registration warning/nonce, select the same root
and index, compare the public key, and confirm signing. Return the card to the PC
and press Enter. The bridge verifies the response against the **original live
session**, then sends the proof. Compare all public-key hex on the ForgeBox
screen with the trusted export before confirming on the device.

For factory version exactly `1.0.0`, this mirrors the official CLI's legacy
proof (SHA256 of the 65-byte public key); other versions require a nonce and sign
SHA256(public key || nonce). It never downgrades automatically after an error.
The bridge never sends a registration packet until a valid response arrives.

**Physical status:** challenge/legacy, altered response, rejection and disconnect
paths are tested against an injected device. Real device registration and nonce
lifetime while the card travels have not been tested. If ForgeBox expires a
nonce, start a fresh session and sign the new request. Registration is documented
as once per device lifetime; a different index cannot replace an enrolled key.

## 3. Prepare the firmware on the build PC

Build your firmware using its normal build process. Use the final padded
`mh1903_full.bin`, not the raw application ELF or an already signed OTA.

```powershell
python tools/forgebox-airgap.py prepare --firmware ./mh1903_full.bin --unsigned ./forgebox-unsigned.ota --cli-dir $cli --public-key ./forgebox-owner.pub.pem --card $card
```

The PC retains `forgebox-unsigned.ota`. The card receives a small
`forgebox-signing/request.json` containing the original/compressed SHA256 hashes,
sizes, a label, the expected public key, package hash and a canonical request ID.
The unsigned output must be a new filename. `prepare` uses the pinned official
CLI compressor without giving it a signing key.

## 4. Sign on SeedSigner

Choose **Tools → ForgeBox Signing → Sign Request on Card**. Read the digest-only
warning, review the label and both hashes against the PC record, select the
signing seed/index, review its public key, and confirm **Sign**.

The device verifies the request shape and expected public key, signs the two
32-byte hashes with deterministic RFC6979 ECDSA, normalizes low-S, verifies its
own signatures, then writes `forgebox-signing/response.json`. It signs the digest
directly: no Bitcoin signed-message prefix, PSBT wrapper or extra SHA256 pass.
Only raw r||s signatures and public metadata go back to the PC. Cancellation,
wrong key and malformed input do not trigger signing. A previous response may
remain on the card after cancellation; it is tied to its old request ID and will
not verify for a different request.

## 5. Verify and assemble on the PC

```powershell
python tools/forgebox-airgap.py assemble --unsigned ./forgebox-unsigned.ota --firmware ./mh1903_full.bin --public-key ./forgebox-owner.pub.pem --card $card --out ./forgebox.bin
```

Assembly requires the trusted public key, exact original firmware and exact
unsigned package. It rejects stale responses, changed hashes/content, incorrect
keys, invalid/non-low-S signatures and existing output files. Only the two
128-character ASCII signature slots are replaced; the rest stays byte-identical.
Install the resulting `forgebox.bin` using the normal factory update/recovery
procedure. The signer does not flash hardware or change the bootloader.

## Trust boundaries and implementation limits

- This is **digest-only authorization**. The signer cannot inspect the firmware,
  prove reproducibility, detect malicious code, authenticate a filename or prove
  that the two hashes represent the same build. Request IDs bind responses to
  requests; they do not make a malicious PC trustworthy. The PC checks content
  hashes and original sizes, but this helper does not independently decompress
  QuickLZ; compression is delegated to the pinned official implementation.
- The key is dedicated to firmware signing. It is not stored in the ForgeBox
  secure elements and does not add JavaCard support. Root backup compromise
  compromises firmware authorization; loss of root/passphrase/index can make
  owner-signed recovery impossible.
- Private material remains in process memory. Mutable entropy is overwritten,
  references are dropped on exits, and no private key is logged, cached or
  serialized. Python/ecdsa/embit contain immutable integers/bytes, so reliable
  memory zeroization and constant-time signing cannot be guaranteed. Pure-Python
  ECDSA has timing side channels; use a trusted physically offline signing device.
- JSON is bounded to 16 KiB, duplicate/unknown fields and invalid curves/sizes are
  rejected, fixed filenames prevent path injection, and symlink/nonregular input
  files are refused. Card content is never executed. Writes are atomic public
  data files; removal/power loss still requires retrying and verifying results.
- Full OS images and physical devices were not built/booted as part of these
  protocol tests. Installation is tested against synthetic Pi/La Frite and
  Luckfox roots; physical update and registration remain separate bring-up tests.

## Tests

```sh
python -m pip install ecdsa==0.19.1 embit==0.8.0 cryptography==45.0.5
FORGEBOX_CLI_DIR=/path/to/node_modules/forgebox-cli python tests/test_forgebox_sign.py -v
node tests/test_forgebox_bridge.cjs
bash tests/test_install_secure_boot_tools.sh
```

The optional CLI interoperability test compresses a multi-chunk image with the
official CLI, signs it through the offline protocol, assembles it and checks both
signatures using the official verifier. Unit tests also use OpenSSL's prehashed
ECDSA implementation independently and the published BIP85 WIF test vector.

References: [BIP85](https://bips.dev/85/),
[ForgeBox CLI](https://github.com/KeystoneHQ/forgebox-cli),
[ForgeBox setup](https://github.com/KeystoneHQ/forgebox).
