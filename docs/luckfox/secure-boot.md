# Luckfox Pico secure boot

Secure boot on the Luckfox Pico boards (RV1103 Mini, RV1106 Pro Max and Pico Pi) is **implemented
and hardware-proven**:

- **What every build does.** It signs the whole boot chain and the rootfs. `signing: on` is the CI
  default, and it uses the committed **public** dev keys, so a default build is signed but not
  protected.
- **Re-signing with your own keys.** A release can be re-signed with keys you hold, four different
  ways ([§2](#2-signing-a-release)).
- **The fuse is always opt-in.** Burning the one-time fuse that makes a board enforce your key
  ([§3](#3-burning-the-fuse-and-recovery)) is never done by a build.
- **Not implemented yet** ([§6](#6-possible-future-work)): recognising the physical device
  (anti-phishing words / device PIN), anti-rollback (a fused board still boots an older genuine
  release), and full lockdown of the U-Boot console, the kernel command line and `sd_update.txt`.
- **Proven on silicon:**
  - 2026-09-12: a Mini fused to the dev key.
  - 2026-09-14: the rootfs verifier on fused and unfused boards.
  - 2026-09-21: a Mini fused to a BIP85-derived key after an on-device re-sign. That run also
    found, fixed and documented two defects that only a fused board shows
    ([§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21)).

**Where to start**

| You want to… | Read |
|---|---|
| Understand what it protects and how | [§1 Background](#1-background) |
| Sign or re-sign a release | [§2 Signing a release](#2-signing-a-release) |
| Burn the fuse, or recover a fused board | [§3](#3-burning-the-fuse-and-recovery), then [the bench procedure](secure-boot-bench-procedure.md) and [soctoolkit-cli.md](soctoolkit-cli.md) |
| Check someone else's release | [verifying-a-release.md](verifying-a-release.md) |
| The signature formats and pure-Python signers in depth | [airgapped-signing.md](airgapped-signing.md) |
| What is not implemented yet | [§6 Possible future work](#6-possible-future-work) |
| Why something is the way it is | [§4 Technical notes](#4-technical-notes), [§5 Implementation notes](#5-implementation-notes), [§6 Findings and history](#7-findings-open-questions-and-history) |

> **Burning the fuse cannot be undone.** A board fused to your key boots and flashes only firmware
> signed by that key, for the rest of its life. Lose the key and the board can never be updated.
> Read [§3](#3-burning-the-fuse-and-recovery) before arming anything, and rehearse on a sacrificial
> board. A board fused to the *public* dev key stays recoverable, because anyone can sign for it,
> but it is also not protected.

---

## 1. Background

### 1.1 What it protects, and what it doesn't

| Question | Answer |
|---|---|
| What does secure boot stop? | Firmware that was not signed by *your* key, from booting on a board fused to that key. The BootROM checks the loader against a key hash in on-die OTP, each stage checks the next, and the initramfs checks the rootfs ([§1.2](#12-the-boot-chain)). |
| Does it cover the rootfs? | **Yes, on signed builds.** The rootfs is minisign-signed at build time and verified in full by an initramfs inside the signed `boot.img` before it is mounted ([§5.2](#52-rootfs-verification-implementation)). |
| Does it work on SD-boot boards with no NAND? | Yes, identically: the fuse is in the SoC, not the storage ([§1.5](#15-boot-media-nand-sd-and-emmc)). |
| Can it be tested without burning a fuse? | **Yes.** A signed build boots unfused (`Verified-boot: 0`) with the software checks live, so keys, signing and boot are all rehearsed before the fuse ([§3.1](#31-before-you-arm)). Only the BootROM step needs the fuse. |
| Can the private key stay offline? | Yes. Every tier can be signed air-gapped on a SeedSigner from a BIP85 seed, with nothing but 32–64-byte digests crossing the gap ([§2.4](#24-air-gapped-signing)). |
| Does it stop someone swapping in a look-alike device? | **No.** Secure boot verifies software, not hardware. Anti-phishing words would close that gap, but they are **not implemented** — design only ([§6.1](#61-device-identity-pin-and-anti-phishing-words)). |
| Does it stop someone flashing an older, genuine release (downgrade)? | **No — anti-rollback is not implemented at any stage.** A fused board boots anything signed with its key ([§6.2](#62-anti-rollback)). |
| Does it stop someone at the UART getting a U-Boot prompt? | **No, not yet.** `CONFIG_BOOTDELAY=0` is interruptible ([§6.5](#65-locking-the-u-boot-console)). |
| Is the kernel command line trusted? | Mostly. On signed builds `root=` is baked into the signed DTB and the env partition cannot set `sys_bootargs`; `mtdparts`/`blkdevparts` remain importable, and `CONFIG_CMDLINE_FORCE=y` is the outstanding full fix ([§4.6](#46-the-kernel-command-line-envf-and-autoboot), [§6.4](#64-full-kernel-command-line-lockdown)). |
| What key size? | **RSA-2048 only** for the boot chain, which is enforced in the SPL ([§7.6](#76-bench-rsa-4096-probe-2026-09-12-unfused-board)). Ed25519 (minisign) for the rootfs. |

**Consequences to decide before touching a fuse:**

- **Key custody.** Rockchip's V1.9 application note, §5.2, verbatim: *"Once you lost it or leak it, your product will be exposed
  in high risk, also the old device will be unable to be updated anymore."* Whoever holds the key
  becomes a permanent central point of trust and failure for every device ever fused.
- **It verifies software, not hardware.** V1.9 intro: *"Secure boot will verify the validity of
  software, but not hardware."* Signed firmware boots on any board of the same platform, so this
  does **not** defend against a substituted or cloned device — a significant part of the evil-maid
  threat model is untouched.
- **Reproducible builds survive.** Signing is a final step over an otherwise byte-reproducible
  image, so users can still reproduce and verify the unsigned payload ([§4.8](#48-reproducibility-of-signed-releases)).
- **Recovery narrows.** A fused device cannot be rescued by flashing an unsigned image: recovery
  needs a loader signed for the fused key ([§3.4](#34-recovery)). Combined with the download-disable
  fuse ([§3.6](#36-the-download-disable-fuse)) it is possible to build a device with no recovery
  path at all.
- **Who holds the key?** A project-held key contradicts "build and flash your own image". The
  alternative — **each user fuses their own key** — preserves that property at the cost of an
  irreversible, brick-capable step in the user's hands. This is what the re-sign tools
  ([§2.2](#22-re-sign-an-existing-release-on-a-pc)–[§2.4](#24-air-gapped-signing)) make practical,
  and it remains a policy decision rather than a technical one.

### 1.2 The boot chain

```
BootROM ──verify──> loader/idblock ──verify──> uboot.img ──verify──> boot.img ──verify──> rootfs
    ▲                (SPL, in NAND)             (U-Boot FIT)          (kernel FIT       (initramfs +
hash in OTP                                                            + initramfs)       minisign)
```

1. **BootROM → loader.** Reads the public key from the loader partition, SHA-256s it, and compares
   it against the hash in OTP. Mismatch → boot fails, silently (UART shows only `RKUART`). Then it
   verifies the RSA-2048 signature over the loader header. On success it **passes the public key up
   to U-Boot**. (From Rockchip's Application Note V1.9 §1.3–1.4; RV1106 boots via SPL,
   `rkbin/bin/rv11/rv1106_spl_*.bin`, so the SPL variant applies.)
2. **SPL → `uboot.img` → `boot.img`.** FIT signature checks against the key in the SPL DTB and
   U-Boot's own control DTB.
3. **initramfs → rootfs.** The verifier inside the signed `boot.img` checks a minisign signature over
   the rootfs before `pivot_root`.

**What "the public key from the loader" means in bytes** (hardware-confirmed 2026-09-21,
[§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21)): the BootROM hashes the RKSS header's key
block, `hdr[0x200:0x430]` = N (0x200, LE) ‖ E (0x10) ‖ C (0x20, the low bytes of the PKA Barrett
constant), and compares that with OTP. The SPL burns the same layout computed from its DTB. The
two only agree if the header's C matches the modulus, which a re-key has to rewrite
([airgapped-signing.md](airgapped-signing.md#the-header-key-block-what-the-bootrom-checks)). A
fused board also refuses a `download.bin` whose LDR `releaseTime` is 1970-01-01, which no
unfused board checks.

**The AVB half of Rockchip's Next Dev guide does not apply here.** `vbmeta.img`,
`fastboot oem fuse at-perm-attr` and dm-verity-via-`fs_mgr` are Android mechanisms; this is a
Buildroot system with no fastboot and no `fs_mgr`.

### 1.3 The three signature tiers

| Tier | Artifacts | Changes | Key | Pure-Python tool | Vendor equivalent |
|---|---|---|---|---|---|
| **A — firmware root** | `download.bin`, `idblock.img` | rarely | RSA-2048 | `rkloader.py` | `rk_sign_tool sl` / `sb` |
| **B — kernel** | `uboot.img`, `boot.img` | per release | RSA-2048 (same key) | `fitsign.py` | `mkimage` via the SDK's `fit.sh` |
| **C — payload** | the rootfs (logical UBI volume, or raw squashfs) | every release | Ed25519 | `minisign.py` | `minisign` |

The rootfs signature lives **inside** `boot.img` (in the initramfs), not next to `rootfs.img`, so
re-signing the rootfs rewrites `boot.img`, which then needs a tier-B re-sign. The formats, and
exactly what each signature covers, are in [airgapped-signing.md](airgapped-signing.md).

### 1.4 Keys

**The committed dev keys** (`opt/luckfox/secure-boot/dev-keys/` for RSA,
`dev-keys-rootfs/` for minisign) are public on purpose. They keep signed builds reproducible and
the failure mode recoverable, but they grant no protection: anyone can sign with them. The boot
screen says so — a fused board shows a **yellow** `PASSED / FIT: dev / rootfs: dev` rather than the
green one ([§5.2](#52-rootfs-verification-implementation)).

**A real key** is either:

- **Derived from a BIP39 seed with BIP85** (RSA-2048 at one child index, Ed25519 at another). Nothing
  to store: the seed and indexes re-derive the keys. This is what the SeedSigner app uses, and what
  was fused on 2026-09-21. Details in
  [airgapped-signing.md](airgapped-signing.md#deriving-the-keys-from-a-bip85-seed).
- **Generated offline with OpenSSL** (V1.9 §5.4 explicitly supports "`.pem` file format generated by
  openssl"), which keeps generation on a machine of your choosing rather than inside a closed-source
  vendor tool:

  ```bash
  # On an air-gapped machine
  openssl genrsa -out privateKey.pem 2048
  openssl rsa -in privateKey.pem -pubout -out publicKey.pem
  ```

- **Held in a token.** A PIV/PKCS#11 token exposing raw RSA (`CKM_RSA_X_509`) can sign tiers A and B;
  an OpenPGP card can sign tier C only. `rk_sign_tool` has native HSM settings. See
  [§4.3](#43-rk_sign_tool-field-notes) and
  [airgapped-signing.md](airgapped-signing.md#smartcards).

> **Back the key up before it is ever used.** A lost key means every fused device is permanently
> un-upgradable. With BIP85 the backup is the seed plus the two indexes.

The practical asymmetry: the RSA key is needed whenever the loader, `uboot.img` or `boot.img`
changes, while the **rootfs key is used for every release** — and both can be kept off the build
host ([§2.4](#24-air-gapped-signing)).

### 1.5 Boot media: NAND, SD and eMMC

Some Luckfox Pico revisions have no SPI NAND and boot from microSD; the Pico Pi boots from eMMC.
**Secure boot applies to them identically**, because the fuse lives in the SoC, not in the storage:
the BootROM verifies whatever loader it loads, from whichever medium it loads it.

Verified by inspecting a built SD image
(`opt/luckfox/out-all-*/seedsigner-luckfox-pico-mini-sd-*.img`):

```
sector 0     blkdevparts=mmcblk1:32K(env),512K@32K(idblock),256K(uboot),32M(boot),
                                 512M(oem),256M(userdata),6G(rootfs)
             sys_bootargs= root=/dev/mmcblk1p7 rootfstype=squashfs
sector 64    RKNS....            <- the loader/idblock, at the standard Rockchip offset
```

Same `idblock → uboot → boot` chain, same loader at sector 64, same squashfs rootfs. Nothing about
the verification model changes.

Two things *do* change, and they pull in opposite directions:

- **SD-boot devices need this more, not less.** A microSD is removable and rewritable with nothing
  more exotic than a card reader. Without secure boot, brief physical access is enough to replace
  the entire firmware — no soldering, no NAND programmer. The BootROM check is precisely what closes
  it.
- **The rootfs matters far more on SD.** On NAND, modifying the rootfs needs hardware; on SD it needs
  a card reader. **On SD-only devices, rootfs verification is not optional polish — it is most of the
  actual protection.** Signed builds close this gap for SD too: the raw-partition squashfs is
  minisign-signed at build time and verified in full by the initramfs before mount
  ([§5.2](#52-rootfs-verification-implementation)).

For testing, SD is the *better* medium: the reversible rehearsal ([§3.1](#31-before-you-arm)) can be
re-run by rewriting the card, with no rockusb/maskrom dance. That convenience stops at the fuse —
after the burn an unsigned card will not boot, so a rewritable card does not rescue a botched key
setup. Also see the `sd_update.txt` warning in [§4.7](#47-removable-media-sd_updatetxt-signed-images-and-rollback).

---

## 2. Signing a release

Four ways to produce a release signed with a key you choose. All four produce the same thing, and
every one ends with the same check ([§2.6](#26-checking-a-signed-release)). MicroSD and eMMC
releases need one extra step, [§2.5](#25-microsd-and-emmc-releases).

| Method | Private key lives on | Needs | Use when |
|---|---|---|---|
| [2.1 Build it signed](#21-build-it-signed-on-a-pc) | the build host | the SDK build (Docker/local/CI) | you build from source with your own key |
| [2.2 Re-sign on a PC](#22-re-sign-an-existing-release-on-a-pc) | the PC | Python 3 + this repo | you have a CI release and your key on a PC |
| [2.3 Re-sign on the device](#23-re-sign-on-the-device) | the SeedSigner (RAM only) | a SeedSigner with enough RAM + a MicroSD | one device does everything; not on the Pico Mini |
| [2.4 Air-gapped](#24-air-gapped-signing) | the SeedSigner (RAM only) | a PC + any SeedSigner + a MicroSD | the key must never touch a networked machine |

> **Run the PC-side tools from a checkout that has the fused-board fixes** (PR #128 or later).
> `tools/airgap-sign.py` and the `secure-boot/*.py` signers import each other from their own
> checkout, so an older checkout re-keys loaders with a stale header constant that only a fused
> board rejects ([§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21)). A re-key done that way
> cannot be repaired in place — start again from a fresh copy of the CI bundle.

### 2.1 Build it signed on a PC

This is what every build already does with the dev keys. Point it at your own keys instead:

| Variable | Meaning |
|---|---|
| `SEEDSIGNER_FIT_SIGNATURE=1` | Enable U-Boot/SPL signature enforcement and sign the whole chain (CI input `signing: on`, the default). |
| `SEEDSIGNER_FIT_KEY_DIR` | Directory holding `dev.key` + `dev.pubkey` + `dev.crt` for the RSA key (make them with `secure-boot/make-dev-keys.sh`, or `--from <pem>` for a BIP85 export). Default: the committed public dev key. |
| `SEEDSIGNER_ROOTFS_KEY_DIR` / `SEEDSIGNER_ROOTFS_KEY_PASSPHRASE` | Minisign `dev.key`/`dev.pubkey` for the rootfs, and its passphrase (required for a real key; the committed dev key uses the public passphrase `seedsigner-dev`). |
| `SEEDSIGNER_ROOTFS_VERIFY_UNFUSED=1` | Also verify the rootfs on unfused boards (CI input `rootfs_verify_unfused`; [§5.2](#52-rootfs-verification-implementation)). |
| `SEEDSIGNER_FIT_BURN_KEY_HASH=1` | **Arm the fuse** in the built loader ([§3.2](#32-ways-to-arm)). Never set by CI. |

What the build signs, and in what order:

1. The SDK's own `make.sh`/`fit.sh` FIT flow signs the loader, `idblock.img` and `uboot.img` in-build.
   The keys must be in the U-Boot tree as `keys/dev.{key,pubkey,crt}` or the build aborts with
   `ERROR: No keys/dev.key`; `provision_fit_build_keys()` drops them there.
2. **`boot.img` is not signed by the SDK** (`mk-fitimage.sh` packs it with the `dev` signature
   *template* and no `-k`), so `sign_boot_image` signs it with the SDK's own `scripts/fit.sh
   --boot_img`. Without that step an enforcing U-Boot rejects it (bench row C2).
3. The rootfs is minisign-signed by the `mkfs_ubi.sh` / `mkfs_squashfs.sh` hooks, and
   `embed_rootfs_verifier()` builds the verifier initramfs into `boot.img` **before**
   `sign_boot_image`, so the FIT signature covers it.
4. `deterministic-sign.sh` re-signs all four boot-chain images with digest-derived PSS salts and a
   zeroed FIT timestamp, so two builds of the same commit are byte-identical
   ([§4.8](#48-reproducibility-of-signed-releases)).
5. `normalise_boot_images()` pins `download.bin`'s and `update.img`'s `releaseTime` — floored at
   **2025-01-01**, because a fused board refuses a 1970-dated loader — and repairs their trailer
   checksums. This only touches fields outside the signatures, so it runs after signing.

The build also bakes the kernel command line into the signed DTB (`apply_signed_nand_bootargs`) and
enables the SPI display statically (`apply_spi_display_dts`), because a signed FIT disables all
runtime DTB modification (bench rows C7/C8).

**Hand-signing with Rockchip's tools** (bench use; not called by any build):
`opt/luckfox/secure-boot/sign-secure-boot.sh gen-key | sign | verify | otp-hash` drives
`rk_sign_tool` and `fit-sign.sh` for a real key, prints the OTP hash a burn would write, and never
flashes or burns. See [its README](../../opt/luckfox/secure-boot/README.md) and the
[bench procedure](secure-boot-bench-procedure.md). `rk_sign_tool` itself is covered in
[§4.3](#43-rk_sign_tool-field-notes).

### 2.2 Re-sign an existing release on a PC

For a downloaded CI release (signed with the dev keys) and your keys on the PC. Everything is pure
Python, so no SDK, `rk_sign_tool` or `mkimage` is needed. The rootfs signature sits inside
`boot.img` and NAND bundles need a UBI-aware digest, so this reuses `airgap-sign.py` with the PC
doing the signing (any directory stands in for the MicroSD card).

Validated end to end on a CI Pico Mini NAND bundle on 2026-09-22 (`RESULT: VALID`).

```bash
SB=opt/luckfox/secure-boot
B=<release folder>          # e.g. seedsigner-luckfox-pico-mini-nand-files-...
W=<scratch dir>             # stands in for the card
# new.key / new.pub  : your RSA-2048 key (PEM)
# rootfs.key / rootfs.pub : your minisign key (minisign.py keygen, unencrypted)

# 1. embed the new RSA public key in the loaders and uboot.img (clears their signatures)
python3 tools/airgap-sign.py rekey   "$B" --card "$W" --rsa-pubkey new.pub

# 2. the rootfs: digest, sign, inject into boot.img's initramfs
python3 tools/airgap-sign.py digests "$B" --card "$W" --only rootfs
python3 $SB/minisign.py sign-digest --digest "$W/seedsigner-release-sign/rootfs.digest" \
        --seckey rootfs.key -o "$W/seedsigner-release-sign/rootfs.minisig"
python3 tools/airgap-sign.py splice  "$B" --card "$W" --only rootfs --no-check \
        --rsa-pubkey new.pub --rootfs-pubkey rootfs.pub

# 3. sign the four boot-chain images (rkloader also signs download.bin's embedded flashhead)
for f in download.bin idblock.img; do python3 $SB/rkloader.py sign "$B/$f" --key new.key; done
for f in uboot.img boot.img;       do python3 $SB/fitsign.py  sign "$B/$f" --key new.key; done

# 4. check (must print RESULT: VALID)
python3 $SB/luckfox_release.py check "$B"
```

- To re-sign **without changing keys** (e.g. after reworking `boot.img`), skip steps 1–2 and sign
  only what changed.
- The lower-level commands behind step 1 (`rkloader.py setkey`, `fitsign.py setkey` + `rehash`),
  and what a re-key rewrites besides the modulus, are in
  [airgapped-signing.md](airgapped-signing.md#swapping-the-chain-to-a-new-key).
- `rekey` deletes `update.img`: it packs a verbatim copy of the old chain.

### 2.3 Re-sign on the device

The SeedSigner app's **Tools → Luckfox Build Tools → Resign Release** re-signs a whole release
folder on a MicroSD card in one pass — loaders, both FITs and the rootfs (rewriting `boot.img`'s
initramfs), then runs the full check. Keys are held in RAM only.

- **Key sources:** BIP85 Derive (a loaded seed + an RSA and an Ed25519 child index), Load from
  MicroSD (a file per key), or Load from SeedKeeper (a secret per key). Accepted formats are listed
  in [airgapped-signing.md](airgapped-signing.md#where-resign-releases-keys-come-from).
- **It deletes `update.img`** (it would still carry the old chain) and fixes `sd_update.txt`'s write
  lengths for the new image sizes.
- **Not on the Pico Mini:** re-signing the rootfs needs more memory than the Mini has and crashes
  it, so the app refuses and points at Sign Digest ([§2.4](#24-air-gapped-signing)) instead. The same
  applies to **Force Rootfs Check** (`airgap-sign.py force` is its PC-side counterpart).
- The other Build Tools actions: **Check Release** (the same check as §2.6), **Export Pubkeys**,
  **Provision MicroSD** (copy a checked release to the card root for U-Boot's auto-flash), and
  **Danger Zone → Arm eFuse Burn** ([§3.2](#32-ways-to-arm)).

What each action changes is described in
[airgapped-signing.md](airgapped-signing.md#running-the-signer-on-a-seedsigner).

### 2.4 Air-gapped signing

The private key never leaves the SeedSigner and never touches the PC: the PC writes **digests**
(32 or 64 bytes each) to a MicroSD card, the SeedSigner signs them, and the PC splices the
signatures back. Any SeedSigner can be the signer, including a Pico Mini or a Pi Zero, because it
never needs the release itself.

On the device, two entry points under **Tools → Luckfox Build Tools**:

- **Sign Digest** signs whatever digests are on the card. Use it for a routine re-sign under an
  existing key.
- **Air-Gap Re-Key** is a guided three-round ceremony for moving a release to new keys:
  - Round 0 — Export Pubkeys
  - Round 1 — Sign Rootfs Digest
  - Round 2 — Sign Boot Chain

  Each round validates the card before signing.

Each step finishes back on its own menu rather than at Home, so the BIP85 keys it derived stay
cached for the next round (Home clears them). Insert the card before powering the board on — these
images do not detect hot-swapped cards ([README](README.md#microsd-card)).

**Moving to new keys** (two signing round-trips):

```bash
python3 tools/airgap-sign.py rekey   <bundle> --card /media/sdcard    # after Round 0 put release-rsa.pub on the card
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard --only rootfs
# ... device: Air-Gap Re-Key -> Round 1 (or Sign Digest) ...
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard --only rootfs --no-check
python3 tools/airgap-sign.py digests <bundle> --card /media/sdcard --only download,idblock,uboot,boot
# ... device: Air-Gap Re-Key -> Round 2 (or Sign Digest) ...
python3 tools/airgap-sign.py splice  <bundle> --card /media/sdcard    # must end RESULT: VALID
```

**Re-signing under an existing key** is one round-trip: `digests` (all, or `--only` what changed) →
Sign Digest → `splice`.

Things to know:

- **Order matters on a re-key.** The rootfs signature is injected into `boot.img`'s ramdisk, which
  `boot.digest` covers, so the rootfs round comes first. Every digest must be taken over the
  *re-keyed* images; `splice` refuses a signature that does not verify.
- **`download.bin`'s embedded flashhead** (the idblock copy that `upgrade_tool ul` writes) has no
  digest of its own: its header is byte-identical to `idblock.img`'s after a re-key, so `splice`
  signs it with the device's `idblock.sig`, verifying it first.
- **Toggle the forced rootfs check** without the key on the PC: `airgap-sign.py force <bundle> --card
  <mount> [--off]`, then one Sign Digest round-trip and `splice`.
- The card layout, the raw per-tier commands, and why the NAND rootfs digest is UBI-aware are in
  [airgapped-signing.md](airgapped-signing.md#toolsairgap-signpy).

### 2.5 MicroSD and eMMC releases

A NAND release is a folder of partition images. A **MicroSD/eMMC release is the same folder**
(`fit-sign-tree-<profile>/` in the build artifacts) **plus a flashable whole-card `.img` built from
it**. So re-signing one is: re-sign the folder by any method above, then rebuild the image.

```bash
# ... re-sign <folder> exactly as in 2.1-2.4, then:
python3 $SB/luckfox_release.py check    <folder>            # must be RESULT: VALID
python3 $SB/luckfox_release.py sd-image <folder> -o card.img
# write card.img to the card (dd / Raspberry Pi Imager / balenaEtcher)
```

What `sd-image` does, and why it is safe to rebuild:

- It reads the partition table out of the folder's own `env.img`
  (`blkdevparts=mmcblk1:32K(env),512K@32K(idblock),…`) and writes each `<name>.img` at the running
  offset, zero between them, ending at the end of `rootfs.img` — the same layout as the build's
  `blkenvflash`, which is why the rootfs partition's declared 6G does not inflate the file. Verified
  byte-for-byte against a CI SD artifact (2026-09-22): rebuilding an untouched folder reproduces the
  shipped `.img` exactly, hash for hash.
- It refuses a partition image that is missing or too big for its slot.
- It refreshes `rootfs.img.minisig` first (below).

**Only the boot chain changes.** A re-signed SD image differs from the original in the `idblock`,
`uboot` and `boot` slots only; `env`, `oem`, `userdata` and the (often large) `rootfs` are
byte-identical, because the rootfs signature lives inside `boot.img`.

**`rootfs.img.minisig`** is a copy of that signature, shipped beside the rootfs. Nothing on the
device reads it — the verifier uses `boot.img` — but a stale copy would mislead anyone checking the
folder by hand, so the re-sign tools (`airgap-sign.py splice`, the app's Resign Release) and
`sd-image` refresh it, and `check` reports it when it is stale. `rootfs.img.size` only changes if the
rootfs itself does.

**`update.img`** in an SD artifact packs the old chain; the re-key tools delete it.

> **Not yet booted on hardware.** The SD re-sign, the rebuilt image and the air-gapped round-trip
> were all validated on the 2026-09-22 CI artifact, but no re-signed card has been booted. Do that on
> an **unfused** board that genuinely boots from MicroSD before trusting it — note that some clone
> Minis cannot SD-boot at all (`MMC: no card present`).

#### Flashing a board that boots from MicroSD

An SD-only board carries its whole boot chain on the card, so **the card is what you write** — there
is no NAND to flash, and USB Download mode does not write it. Three ways, in order of preference:

1. **Write the whole image (normal).** `dd`, Raspberry Pi Imager or balenaEtcher, exactly as for an
   unsigned image. Everything — loader, U-Boot, kernel, rootfs — is inside `card.img`.

   ```bash
   sudo dd if=card.img of=/dev/sdX bs=4M conv=fsync status=progress
   ```

2. **Write only what a re-sign changed**, keeping the card's `oem`, `userdata` and rootfs. After a
   re-sign that is just the three boot-chain partitions, at these offsets from the release's own
   `env.img` table (Pico Mini SD; take them from your own `env.img`, or from
   `luckfox_release.py sd-image`'s output, rather than assuming):

   | Image | Offset | Sector | `dd` |
   |---|---|---|---|
   | `env.img` | 0 | 0 | `seek=0 bs=512` |
   | `idblock.img` | 32 KiB | 64 | `seek=64 bs=512` |
   | `uboot.img` | 544 KiB | 1088 | `seek=1088 bs=512` |
   | `boot.img` | 800 KiB | 1600 | `seek=1600 bs=512` |

   ```bash
   sudo dd if=idblock.img of=/dev/sdX bs=512 seek=64   conv=fsync
   sudo dd if=uboot.img   of=/dev/sdX bs=512 seek=1088 conv=fsync
   sudo dd if=boot.img    of=/dev/sdX bs=512 seek=1600 conv=fsync
   ```

3. **The card's own `sd_update.txt`**, which on an SD release writes the card itself (`mmc write`,
   where a NAND release uses `mtd write`). It is the U-Boot auto-flash path, driven from a FAT
   partition holding the images. `luckfox_release.py sd-update <folder>` checks its write lengths and
   `--fix` repairs them. Remember it is unsigned code execution
   ([§4.7](#47-removable-media-sd_updatetxt-signed-images-and-rollback)).

**What USB/SocToolkit can and cannot do here.** `upgrade_tool db` only loads a loader into RAM
([soctoolkit-cli.md](soctoolkit-cli.md)); it never writes the boot medium, so sending a re-signed
`download.bin` to an SD board changes nothing on the card. Whether the usbplug can be pointed at the
card to write it (`upgrade_tool ssd`, SwitchStorage) is **untested here** — assume not, and use a card
reader. Maskrom still matters on a fused SD board for a different reason: if the card's loader is
wrong the board drops there, and recovery is to rewrite the card, not to flash over USB.

### 2.6 Checking a signed release

```bash
SB=opt/luckfox/secure-boot
python3 $SB/luckfox_release.py check <release folder>     # the whole release: RESULT: VALID / INVALID
python3 $SB/rkloader.py inspect <release>/idblock.img     # OTP key hash, SPL burns, !! FUSED BOARD lines
python3 $SB/rkloader.py verify  <release>/download.bin --pubkey release-rsa.pub
python3 $SB/fitsign.py  verify  <release>/boot.img     --pubkey release-rsa.pub
python3 $SB/verify-fit-payloads.py compare <release>/boot.img <rebuilt>/boot.img
```

`check` verifies every signature under one key, the `uboot.img` → `boot.img` key embedding, the
rootfs against the key `boot.img` trusts, the MicroSD auto-flash script, and everything a **fused**
board checks that an unfused one doesn't:

- the header key block (C must match the modulus);
- an armed SPL burning the same hash its header presents;
- the flashhead's own signature;
- `download.bin`'s `releaseTime`.

It also warns when either key is the public dev key. For checking a release you did not build
(authenticity and reproducibility, with no keys), see
[verifying-a-release.md](verifying-a-release.md).

---

## 3. Burning the fuse, and recovery

### 3.1 Before you arm

Everything up to the burn is reversible, and a signed build behaves the same on an unfused board
(the software checks are live; only the BootROM step is missing). Rehearse on a sacrificial board:

1. **Boot the signed release unfused.** Expect `FIT: signed, conf required` and
   `sha256,rsa2048:<key>+ OK` in U-Boot; `Verified-boot: 0` is expected until the fuse.
2. **The negative test — do not skip it.** Corrupt one byte of the kernel payload inside a signed
   `boot.img` and confirm U-Boot refuses it; repeat with a `boot.img` signed by a different key. A
   verification step that has never rejected anything has not been shown to work.
3. **Run the pre-arm checks on the exact files you will flash.** All must pass:

   ```bash
   python3 $SB/rkloader.py inspect idblock.img     # "OTP key hash" == "SPL burns", no "!! FUSED BOARD"
   python3 $SB/rkloader.py verify  download.bin --pubkey your.pub
   python3 $SB/luckfox_release.py check <release folder>
   ```

   `rk_sign_tool otp --loader <signed loader> --hash` prints the same OTP value independently.
   **Record it**: it is the only record of what a board expects ([§3.5](#35-which-key-is-a-fused-board-expecting)).
4. **Have recovery ready:** a `download.bin` for the new key that passes `verify`, and a proven
   maskrom path on this board ([§3.4](#34-recovery)).

The runnable, staged version of this (keys, build, flash, burn, confirm) is the
[bench procedure](secure-boot-bench-procedure.md).

> **What cannot be rehearsed.** BootROM enforcement itself — it is only observable after the fuse is
> burned. Two defects that only it catches were found that way
> ([§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21)); both are now checked in software.

### 3.2 Ways to arm

A loader whose SPL DTB carries `burn-key-hash = <1>` writes the key hash to OTP and enables secure
boot on its first boot. Three ways to produce one:

- **In-build:** `SEEDSIGNER_FIT_BURN_KEY_HASH=1` (with `SEEDSIGNER_FIT_SIGNATURE=1`). Bench row C3.
- **On an existing release, on a PC:** `rkloader.py setburn idblock.img --confirm
  I-UNDERSTAND-THIS-BURNS-A-FUSE`, then `rkloader.py sign`. The armed DTB is byte-identical to the
  SDK's ([airgapped-signing.md](airgapped-signing.md#arming-the-otp-burn)).
- **On the device:** Danger Zone → **Arm eFuse Burn**. It refuses unless `check_release` passes and
  the key is not the dev key, and it re-checks the armed image before writing it.

Only `idblock.img` is armed; SocToolkit's Download mode writes it to NAND. **What does not work on
this SoC:** the legacy `sign_flag=0x20` / `ss --flag 0x20` loader flag (V1.9 §6.6's `config.ini` edit;
Q2 in [§7.2](#72-answered-questions)),
and the standalone `rkbin/fit-sign.sh --burn-key-hash` re-sign flow, which needs
`fit_signcfg/sign.readonly_config` that this SDK never generates (Q3).

### 3.3 What the logs show

```
## Verified-boot: 0                          <- before the burn
RSA: Write RSA key hash successfully.        <- SPL, on the burn boot
## Verified-boot: 1                          <- every boot after
conf: sha256,rsa2048:dev+                    <- U-Boot verifying boot.img (the key name hint stays "dev")
```

The SPL refuses to burn unless the key it holds hashes to its DTB's `hash@np`, and it reads the OTP
back afterwards, so "Write RSA key hash successfully" means the OTP holds exactly that value. On the
first boot after a failed or mismatched burn the board drops to maskrom and prints only `RKUART`.
(V1.9 §8.1 documents `Secure Boot Mode: 0x1` / `SecureBootEn = 1, SecureBootLock = 1`, and
`otp write key success!!!` or `otp write error: !!!`, for older SoCs; RV1106 prints the lines
above instead.)

**Enforcement check:** on the fused board, flashing an image signed by another key must fail. If an
unsigned image still boots, the fuse did not take — the worst state: it looks protected and is not.

### 3.4 Recovery

The BOOT button still enters maskrom on a fused board (bench row C6). Maskrom accepts only a loader
whose header hashes to the fused OTP value, so recovery needs **a `download.bin` signed for the
fused key**:

- SocToolkit Download mode (or `upgrade_tool db`) with that `download.bin`, then write the
  partitions (bench row C9).
- **Power-cycle between `db` attempts.** After one rejected loader, even a good one can fail until the
  board is reset (bench row F4).
- Read SocToolkit's own log to see which file it actually sent.

The full CLI procedure, the NAND sector layout, and a troubleshooting sequence for "Download boot
failed!" are in [soctoolkit-cli.md](soctoolkit-cli.md).

### 3.5 Which key is a fused board expecting?

The OTP holds **no public key** — only the 32-byte SHA-256 of the header key block (N‖E‖C), plus the
secure-boot enable flag. So the question is always "which of the keys I have does this hash match".

- **Linux cannot read it.** The kernel's `rockchip-otp` nvmem driver sees only the non-secure OTP
  view ([§4.5](#45-otp-what-linux-can-and-cannot-see)).
- **SPL/U-Boot can** (`rsa_burn_key_hash()` reads `OTP_RSA_HASH_ADDR` from secure OTP), but on a fused
  board only code signed with the fused key runs there.
- **Maskrom / usbplug:** `upgrade_tool rsm` (ReadSecureMode) probably reports fused-or-not, but is
  untested; no known command returns the hash.

This is walled off with the rest of the secure OTP region; it is not secret (it is a hash of a
public key). Practical ways to find it:

1. **If the board boots:** the key in its NAND idblock is by definition the fused key. Read the
   idblock back and run `rkloader.py inspect` — its "OTP key hash" is the OTP value.
2. **If it is stuck in maskrom but the burning idblock is still on NAND:** that idblock's SPL DTB
   `hash@np` ("SPL burns" in `inspect`) is exactly what was burned. Without a working loader, read it
   with an SPI-NAND programmer.
3. **Trial `db`** with loaders for candidate keys — but each needs that key's private half.
4. **Record it at burn time** ([§3.1](#31-before-you-arm) step 3). This is the only reliable way.

### 3.6 The download-disable fuse

`rkbin/doc/release/RV1106_EN.md` notes that `rv1106_ddr` v1.16 adds *"Support disabling download
function through OTP"* — an independent, irreversible fuse that disables the rockusb download path.
(The SeedSigner build currently ships DDR blob **v1.15**, per `fwver: v1.15` in the boot log, which
predates that feature.)

Burning it would remove the recovery failover configured by
[`opt/luckfox/uboot-recovery-config.sh`](../../opt/luckfox/uboot-recovery-config.sh) and described
in [README.md](README.md), and the maskrom recovery in §3.4. **Recommend leaving it alone** even if
secure boot is adopted: it turns every future firmware bug into a dead board. Its status and
trade-offs as possible future work are in [§6.10](#610-disabling-the-maskrom-download-interface).

---

## 4. Technical notes

### 4.1 U-Boot configuration

`sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig` already contains:

```
CONFIG_SPL_ROCKCHIP_SECURE_OTP=y     # SPL can reach secure OTP
CONFIG_ROCKCHIP_OTP=y
CONFIG_RSA=y                         # RSA verify in U-Boot
CONFIG_SPL_RSA=y                     # ...and in SPL
CONFIG_RSA_N_SIZE=0x200              # modulus field up to 4096-bit (the key-block N field size)
CONFIG_RSA_E_SIZE=0x10
CONFIG_FIT_HW_CRYPTO=y               # FIT hashing via the crypto block
CONFIG_SPL_FIT_HW_CRYPTO=y
CONFIG_SPL_FIT_GENERATOR="arch/arm/mach-rockchip/make_fit_optee.sh"
```

**`CONFIG_FIT_SIGNATURE` and `CONFIG_SPL_FIT_SIGNATURE` are absent** in the stock defconfig: the
verification code is compiled in, but nothing requires a valid signature. `SEEDSIGNER_FIT_SIGNATURE=1`
turns them on (`apply_fit_signature_config` in `os-build.sh` / `build-local.sh`), always together
with signing — enforcement without signing would brick every unsigned build, which is why it is not
an auto-applied SDK patch. `enable-fit-signature.sh` is the standalone equivalent for a hand-checked-out
SDK.

With `CONFIG_SPL_FIT_HW_CRYPTO=y` the SPL verifies `uboot.img` on the PKA engine, which loads the
Barrett constant `rsa,np` from the DTB unvalidated — see
[airgapped-signing.md](airgapped-signing.md#what-setkey-rewrites-besides-the-modulus) for why a stale
`rsa,np` fails only on-device (`invalid pss padding (0xbc is missing)`).

### 4.2 FIT image anatomy

Parsed from a real build (`opt/luckfox/out-all-*/seedsigner-luckfox-pico-mini-nand-files-*/`):

`uboot.img`

```
/                              description   = FIT Image with ATF/OP-TEE/U-Boot/MCU
/images/uboot                  compression   = lzma
/images/uboot/digest           algo          = sha256
/images/fdt                    type          = flat_dt
/configurations/conf/signature algo          = sha256,rsa2048
/configurations/conf/signature sign-images   = loadables fdt
/configurations/conf/signature key-name-hint = dev          <-- Rockchip placeholder name
```

`boot.img`

```
/                              description   = FIT image with Linux kernel, FDT blob and resource
/images/kernel                 data-size     = 2667880
/images/fdt                    data-size     = 36384
/images/resource               data-size     = 74752        (type "multi")
/configurations/conf/signature algo          = sha256,rsa2048
/configurations/conf/signature sign-images   = fdt kernel multi
/configurations/conf/signature key-name-hint = dev
```

Both carry a `signature` node named for the **development key**; the name hint stays `dev` whatever
key actually signs. The stock `boot.img` has no ramdisk slot; signed builds add one for the rootfs
verifier and add `ramdisk` to `sign-images` ([§5.2](#52-rootfs-verification-implementation)).

The FIT header is a flattened device tree, so it can be parsed without `dtc`:

```bash
python3 -c 'import re,struct,sys; d=open(sys.argv[1],"rb").read(); [print(m.start(), "totalsize", struct.unpack(">I", d[m.start()+4:m.start()+8])[0]) for m in re.finditer(b"\xd0\x0d\xfe\xed", d)]' boot.img
```

`boot.img` holds the FIT header at offset 0 and the kernel DTB at offset 2048. Walking the FDT
struct block from there yields the `/images/*` and `/configurations/conf/signature` properties above.
`verify-fit-payloads.py` and `fitsign.py info` do this properly.

### 4.3 `rk_sign_tool` field notes

Rockchip's closed-source signer (`sysdrv/source/uboot/rkbin/tools/rk_sign_tool`, v1.49; upstream
`rockchip-linux/rkbin/tools/` also has `fit-sign.sh`, `fit_check_sign` and `boot_merger`). The
pure-Python signers replace it for every tier, but it remains the independent reference — e.g.
`otp --loader --hash` confirmed the 2026-09-21 diagnosis.

**Chip id.** RV1106 is supported (`cc --chip 1106` → "setting chip ok"). **`1103` is rejected; the
RV1103 entry is `1103b`.** The authoritative list is not compiled in — it lives in
`rkbin/tools/setting.ini`:

```ini
support_chip= 3506|3572|3576|3562|3528|3538|3588|3566|3568|3308|3326|3399|3229|3228h|
              3368|3228|3288|px30|3328|1808|3228P|1109|1126|2206|1106|1103b|1106b|1126b
```

Plain `1103` and `1108` are absent and rejected with *"is not in the support list"*; `zzzz`, `9999`,
`hello` and `0000` are rejected too. The same file puts **`1106` and `1103b` under `hard_sign_pss`,
`new_crypto` and `new_idb`** — RSA-PSS padding, the newer crypto block, and the new (RKNS) idblock
format — which is why `rk_sign_tool vb --idb` on a shipped `idblock.img` reports *"invalid idblock
tag"* against the older format expectations. The SDK has **no RV1103 U-Boot defconfig** — the Mini
builds with `luckfox_rv1106_uboot_defconfig`, and `fit-sign.sh` derives the id as
`${CHIP_NAME: 2: 6}`, so **sign the RV1103 Mini as `1106`**. (`1103b` is also accepted and may be the
true RV1103B entry; untested against hardware.) Running it needs `setting.ini` and `boot_merger` next
to the binary.

**Keys.** `rk_sign_tool kk --bits 2048|3072|4096 --out .` (e.g. `kk --bits 4096`) generates
`private_key.pem` + `public_key.pem` (all three sizes work in the tool; the chain accepts only 2048, [§7.6](#76-bench-rsa-4096-probe-2026-09-12-unfused-board)).
`--sm2` / `--ec` exist but are not on the documented BootROM path. `lk --key <priv> --pubkey <pub>`
loads an existing (e.g. OpenSSL- or BIP85-generated) keypair.

**Verbs** (from its own help output):

| Verb | Purpose |
|---|---|
| `sl` / `vl` | sign / **verify** loader (signs both the "usbhead" and the "flashhead") |
| `si` / `vi` | sign / **verify** image (uboot, boot, trust) — `rk_sign_tool vi --img uboot.img` on a shipped image returns *"the image did not support to sign"*: FIT-era RV1106 images are signed by `mkimage`, so use the FIT flow, not raw `rk_sign_tool si` |
| `sb` / `vb` | sign / **verify** idblock binary |
| `sf` / `vf` | sign / **verify** update firmware (`update.img`) |
| `sd` / `vd` | sign / verify DDR test config |
| `otp --loader [--hash]` | **the OTP payload a signed loader needs** — record it before a burn |
| `ss --flag <hex>` | set sign flag (V1.9 §6.6's `sign_flag`; does nothing on RV1106, Q2) |
| `ss --version <hex>` | set sign version (a non-OTP field; not the rollback index, Q11) |
| `ss --nonce`, `ss --cert` | signing nonce; secure cert |
| `mcr` | `rk_sign_tool mcr <--key> <--pubkey>`: create secondary cert (possible root/delegate hierarchy; unexplored, Q10) |

`vl`/`vb` are software checks — they passed on the loaders with the stale header constant that a
fused board rejected. `sl`/`sb` with a newly loaded key rewrite the header key block (N, E and C)
and re-sign both loader headers (confirmed 2026-09-21: `otp --hash` on the result matched the new
key), but they do **not** re-key the SPL DTB inside the idblock (`rsa,modulus`, `rsa,np`, `hash@np`),
so the SPL would still verify `uboot.img` against the old key.

**Native HSM.** `setting.ini` carries `using_hsm=`, `hsm_engine_id=`, `hsm_private_key_id=`,
`hsm_public_key_id=` — first-class OpenSSL-engine signing, so a PKCS#11 token can hold the key with
no digest shuffling. Untested here (no token to hand); the engine id and key-id syntax are open (Q8b).

**Extract / inject.** `ss --extract` then `sl --loader download.bin` emits the data to sign as bare
32-byte SHA-256 digests (`si_usb_head.bin`, `si_flash_head.bin`; also `si_idb_head.bin`,
`si_update_hash.bin` for other targets). Run and confirmed:

```
$ rk_sign_tool ss --out=<dir>
$ rk_sign_tool ss --extract
$ rk_sign_tool sl --loader download.bin
extract data into si_usb_head.bin...
extract data into si_flash_head.bin...
```

`ss --inject` reads the signature back from a sibling `<digest>.sign.rsa`. The padding is **RSA-PSS**
(`hard_sign_pss`), not PKCS#1 v1.5 — signing these digests with 
`openssl pkeyutl -pkeyopt rsa_padding_mode:pkcs1` produces a well-formed 256-byte blob the tool rejects. The format was later
recovered directly (Q16), so `rkloader.py` does digest/splice itself and this route is optional.

**Two gotchas, both discovered the hard way:**

- **`ss --out=<path>` requires the `=` form.** Space-separated (`ss --out <path>`) fails with
  `setting sign argument failed, ... is not existed` and silently leaves the previous value.
- **The tool is stateful.** `sign_state`, `select_chip`, key paths and `sign_out` all persist in
  `setting.ini`, so a tool left in `extract` or `inject` mode keeps behaving that way in a later,
  apparently unrelated run. Reset `sign_state=` before normal signing — an easy way to produce an
  unsigned image while believing you signed it.

**`fit-sign.sh`** (`rkbin/tools/fit-sign.sh`; `--key-dir`, `--src-dir`, `--out-dir`, `--burn-key-hash`, `--rollback-index <img>
<n>`, `--version <img> <n>`): signs FITs with `mkimage -f image.its -k <key-dir> -K u-boot-spl.dtb -E
-p 0x1200 -r image.itb -v <version>` (`-K` injects the public key into the SPL DTB; the `-N pkcs11`
engine route for tokens is plausible, Q6) and the loader/idblock with `rk_sign_tool cc --chip <id>`,
`lk --key ... --pubkey ...`, then `sl --loader <download|loader|MiniLoaderAll>.bin` and
`sb --idb <idblock>.img`. It reads `<src-dir>/fit_signcfg/sign.readonly_config`, which **this SDK never generates**, so
the standalone re-sign flow is unusable here; the in-build flow is used instead (Q3). With
`--burn-key-hash` it sets `burn-key-hash 0x1` on `/signature/key-dev` and hard-requires
`CONFIG_SPL_FIT_HW_CRYPTO=y`.

### 4.4 Loader and idblock format

| Artifact | Signed message | Signature at | Encoding |
|---|---|---|---|
| `idblock.img` | `[0x000 : 0x600]` | `0x600` | RSA-PSS, SHA-256, MGF1-SHA256, **saltLen 32**, **little-endian** |
| `download.bin` | `[0x1bc : 0x7bc]` | `0x7bc` | identical |

A 0x600-byte RKSS header followed by its signature. The magic goes `RKNS` → `RKSS` (and the u32 at
header+0x0c gains `0x10`) **before** the digest is taken. The modulus is embedded little-endian at
header+0x200 — `0x3bc` in `download.bin`, where it was first spotted. The header carries the key block
(N‖E‖C at +0x200..+0x430, what the BootROM hashes) and sha256s of two components (the SPL and its
DTB). `idblock.img` also carries the key big-endian in its SPL DTB (`rsa,modulus`, `rsa,np`,
`hash@np`, …). `download.bin` is a boot_merger `LDR ` container with a CRC-32 trailer (polynomial
`0x04C10DB7`), a `releaseTime`, and an RC4-obfuscated second copy of the whole idblock (the
flashhead). Full detail, including how each was recovered, is in
[airgapped-signing.md](airgapped-signing.md) and `rkloader.py`'s docstring.

### 4.5 OTP: what Linux can and cannot see

The shipped DTB has `otp@ff3d0000` (`rockchip,rv1106-otp`) enabled and the kernel sets
`CONFIG_ROCKCHIP_OTP=y`. It is used only for chip identity — `cpu_code`, `otp_id`, `cpu_leakage` —
surfaced as the `Serial` line in `/proc/cpuinfo`. The Linux driver is **read-only on RV1106**:
`rv1106_data` in `drivers/nvmem/rockchip-otp.c` sets `.size = 0x80` and has no `.reg_write`, and those
128 bytes already hold factory cells ([§6.1](#61-device-identity-pin-and-anti-phishing-words)).

This nvmem device exposes a **non-secure view** that does *not* contain the secure-boot enable flag
or the key hash — the SPL reads those through a separate hardware path (the
`rv1106_spl_rockchip_otp_start/stop` register sequence in `drivers/misc/rv1106-secure-otp.S`). Byte
0x80 of the userspace blob is the chip ID (`"RV\x11\x03"` on RV1103) on both fused and unfused boards,
so **do not** use it to detect secure-boot state (bench row E4). The userspace-visible fuse bytes do
differ (offsets 0x2d/0xad read `0x0e` fused vs `0x00` unfused, mirrored copies), but that layout is
undocumented, so nothing depends on it; trust U-Boot's `fuse.programmed` kernel-cmdline flag instead
([§5.2](#52-rootfs-verification-implementation)).

The only other known secure-OTP allocation is the rollback counter at `0xe0`
(`OTP_UBOOT_ROLLBACK_OFFSET`, 8 bytes), which the SPL can read and write — unused by this build, which
sets no rollback index ([§6.2](#62-anti-rollback)).

### 4.6 The kernel command line, ENVF and autoboot

**Current state on signed builds:** `root=` and the rootfs arguments are baked into the signed DTB
`/chosen`, and the unsigned env partition **cannot** set `sys_bootargs`. `mtdparts`/`blkdevparts` are
still imported from it and merged into the command line; `CONFIG_CMDLINE_FORCE=y` is the outstanding
full fix. How that picture was established:

The Luckfox U-Boot builds with `CONFIG_ENVF=y` and:

```
CONFIG_ENVF_LIST="blkdevparts mtdparts sys_bootargs app reserved ipaddr serverip netmask gatewayip ethaddr"
```

At boot, `env/envf.c` reads the **unsigned** env partition (`ENVF: Primary 0x00000000 - 0x00040000`
in the boot log) and imports it with `himport_r(..., envf_num, envf_list)`, which takes **only the
variables in that list**. Then `arch/arm/mach-rockchip/board.c` (around line 1302 at the pinned SDK
commit) does this:

```c
env = env_get("sys_bootargs");
if (env) {
    env_update("bootargs", env);
```

On an **unsigned** build, whatever `sys_bootargs` the env partition holds is merged into the kernel
command line. The SD image carries
`sys_bootargs= root=/dev/mmcblk1p7 rootfstype=squashfs rk_dma_heap_cma=1M` at sector 0, and no signature covers any of it (bench row A4 confirmed the same on
NAND). An attacker who can write the env partition adds `rdinit=`, `init=` and `root=`, and a genuine
signed kernel boots into their own root filesystem without ever running the initramfs verifier —
trivial on SD boards, where it sits on the removable card, and reachable on NAND boards through
`sd_update.txt`'s `mtd write` ([§4.7](#47-removable-media-sd_updatetxt-signed-images-and-rollback)).

- **2026-09-12 — a signed FIT changes the runtime picture.** When `boot.img` is a signed,
  conf-required FIT, U-Boot no longer rewrites the kernel DTB's `/chosen/bootargs` at runtime — the
  fused Mini booted with exactly the `/chosen` string baked into the DTB. This was first seen as a
  *failure* (the SDK's shared `ipc.dtsi` hardcodes the SD default `root=/dev/mmcblk1p7`, so the NAND
  board hung, bench row C7); `apply_signed_nand_bootargs` now bakes the NAND rootfs cmdline in.
- **2026-09-13 — the baked cmdline must match the rootfs fs type.** The first version unconditionally
  baked `root=ubi0:rootfs ubi.mtd=6 rootfstype=ubifs` — correct for dev builds (writable dynamic UBIFS
  volume) but wrong for non-dev, where readonly-rootfs packs **squashfs** into a *static* UBI volume
  exposed as `/dev/ubiblock0_0` ("Waiting for root device", no recovery short of reflash).
  `apply_signed_nand_bootargs` now branches on the resolved readonly-rootfs setting and bakes
  `ubi.block=0,rootfs root=/dev/ubiblock0_0 rootfstype=squashfs ubi.mtd=6 rk_dma_heap_cma=<size>` for
  non-dev — the same split the SDK's own `__GET_TARGET_PARTITION_FS_TYPE` makes for spi_nand.
- **2026-09-14 — on signed builds the env partition cannot touch bootargs at all.** Both import paths
  in `env/envf.c` are guarded by `CONFIG_IS_ENABLED(FIT_SIGNATURE)`: `env_get_string()` returns NULL
  for `sys_bootargs`, and `envf_init_vars()` refuses to whitelist it (and hard-errors if anyone lists
  plain `bootargs`). These boards also have **no persistent U-Boot env backend** (`Using default environment`;
  every `CONFIG_ENV_IS_IN_*` unset). What remains importable is `mtdparts`/`blkdevparts`,
  merged verbatim by `bootargs_add_partition()` — bounded (a redefined layout cannot make the rootfs
  verify) but not zero.

**The filter is also good news:** the partition **cannot** set `bootdelay` or Rockchip's `cli`
variable, because neither is whitelisted.

Mitigations for full lockdown, in order of preference:

1. **Kernel `CONFIG_CMDLINE` with `CONFIG_CMDLINE_FORCE=y`.** The command line is compiled into the
   kernel, inside the signed `boot.img`, and the kernel ignores whatever the bootloader passes.
   `root=`, `rootfstype=`, `rk_dma_heap_cma=` and the MTD partition layout then have to be baked in
   for each board/medium variant. Untested on the SDK's 5.10 kernel.
2. **Remove `sys_bootargs`, `blkdevparts` and `mtdparts` from `CONFIG_ENVF_LIST`** (or disable
   `CONFIG_ENVF`) and carry those values in the compiled-in default environment inside the signed
   `uboot.img`. This repo delivers its partition layout through `RK_PARTITION_CMD_IN_ENV` (see
   `opt/luckfox/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch`), so that path would
   have to move.
3. **Pin the rootfs device inside the initramfs** instead of reading `root=`.

Only (1) closes the whole class; (2) and (3) are defence in depth.

**Autoboot.** The boot log shows `Hit key to stop autoboot('CTRL+C'):  0`. **`CONFIG_BOOTDELAY=0`
does not prevent interruption** — the SDK's `common/autoboot.c` runs the abort check whenever
`bootdelay >= 0`, and the Kconfig help says so: *"set to 0 to autoboot with no delay, but you can stop
it by key input ... set to -2 to autoboot with no delay and not check for abort."* Holding CTRL+C on
the UART at power-on reaches a U-Boot `=>` prompt (bench row B1), and on a fused board that still means
memory read/write and control of the environment. Rockchip also extended the abort test with
`|| env_get("cli")`, so a `cli` environment variable reaches the prompt with no keypress at all. A
locked-down build needs `CONFIG_BOOTDELAY=-2` (which the env partition cannot undo, see above) and
`CONFIG_CONSOLE_DISABLE_CLI=y`, since upstream U-Boot still drops into its CLI when `bootcmd` fails.
Check on hardware what a failed boot actually does. **Neither is set today** — the build uses
`CONFIG_BOOTDELAY=0` ([§6.5](#65-locking-the-u-boot-console)).

### 4.7 Removable media: `sd_update.txt`, signed images, and rollback

> **`sd_update.txt` is unsigned code execution, and secure boot does not cover it.** On every boot
> U-Boot looks for a card and runs its `sd_update.txt`; the boot log shows
> `## retrieving sd_update.txt ...` before the kernel loads. That file is a **U-Boot command
> script** (`mw.b`, `fatload`, `mtd erase`, `mtd write`, ... see
> [`opt/luckfox/patch-sd-update-scripts.sh`](../../opt/luckfox/patch-sd-update-scripts.sh)), and
> nothing signs or verifies it. On a fused board it cannot make unsigned firmware *boot*, but anyone
> who can insert a card gets arbitrary U-Boot commands before the kernel: erase or overwrite any NAND
> partition, brick the device, or write to memory. A secure-boot build should disable the `sd_update`
> auto-run or require a signed script. It is an intentional convenience today and becomes an attack
> surface the moment the rest of the chain is locked.
>
> Secondary effect: with secure boot enabled, images written through this path must be signed, or
> the flash reports success and the device then refuses to boot.

**Signed images on microSD** are mostly native behaviour once verification is enabled: every stage
above the BootROM checks the FIT signature **regardless of which medium the image came from**, and
the SPL already prefers the card:

```
Trying to boot from MMC2
MMC: no card present
...
Trying to boot from MTD1
```

On an unfused, unenforcing board that ordering is itself the attack (any card carrying a `uboot.img`
replaces the bootloader); with enforcement it becomes a feature. "Only boot it if it's signed" holds
only when four things are true:

1. **The command line is inside the signature** ([§4.6](#46-the-kernel-command-line-envf-and-autoboot)).
2. **The rootfs is verified too** — the initramfs inside the signed `boot.img` does this
   ([§5.2](#52-rootfs-verification-implementation)).
3. **Removable media supplies data, never code.** `sd_update.txt` is a script U-Boot *executes*; a
   signed image is data U-Boot *verifies*. If flashing NAND from a card has to stay, verify each
   image's signature before writing it, and never write the env partition. (`rk_sign_tool sf`/`vf`
   also sign and verify whole `update.img` packages.)
4. **Old signed images have to be refused** — not implemented today ([§6.2](#62-anti-rollback)),
   and for `boot.img` it currently needs OP-TEE. A
   genuine but outdated `boot.img` passes the signature check. U-Boot proper has
   `CONFIG_FIT_ROLLBACK_PROTECT` (enforced in `common/image-fit.c`), but `fit-sign.sh` refuses a
   `boot.img` rollback index unless `CONFIG_OPTEE_CLIENT` is enabled too: *"Don't support
   --rollback-index ... due to CONFIG_FIT_ROLLBACK_PROTECT=y but CONFIG_OPTEE_CLIENT=n"*. Only the
   SPL → `uboot.img` step can be rollback-protected directly from secure OTP (supported by the SDK,
   **not enabled in this build** — no stage is rollback-protected today, [§6.2](#62-anti-rollback)).
   In U-Boot proper,
   `fit_read_otp_rollback_index()` (`arch/arm/mach-rockchip/board.c`) calls
   `trusty_read_rollback_index()`, which is an OP-TEE client call despite the name; SPL's function of
   the same name reads secure OTP directly. Without OP-TEE, a `boot.img` floor has to be anchored in
   a rollback-protected `uboot.img` instead (Q14).

With all four in place, a card holding a signed `uboot.img` and `boot.img` (initramfs included) plus
`rootfs.img` is a complete, verifiable firmware medium, on SD-only boards and as an update path for
NAND boards.

### 4.8 Reproducibility of signed releases

Examined 2026-09-12 with [`secure-boot/verify-fit-payloads.py`](../../opt/luckfox/secure-boot/verify-fit-payloads.py).
A signed `uboot.img` / `boot.img` is a ~2 KB FDT header (metadata + per-image sha256 + a 256-byte
RSA-PSS `/configurations/conf/signature/value`) followed by the image **data stored externally**
(`data-position` / `data-size`). Recomputing sha256 over each external payload matches the stored
`hash` node exactly, and the `kernel` payload hash equals the value seen at boot on UART.

**Every payload and all metadata in these two FITs is key-independent — the only key-dependent bytes
are the 256-byte `signature/value`, and the pubkey isn't even in these FITs (it's in the loader's SPL
DTB).** So a signed release verifies as "reproducible payloads + a detached signature": rebuild with
the same config, then `verify-fit-payloads.py compare <release-image> <rebuilt-image>` must report
every payload MATCH. Authenticity is checked separately against the published pubkey
([verifying-a-release.md](verifying-a-release.md)).

Both halves are now implemented in pure Python: `rkloader.py` for the loaders (re-signing with the
same key changes only the signature bytes; `canonicalise` zeroes every key-dependent field) and
`fitsign.py` for the FITs (re-derives the signed region from `hashed-nodes` / `hashed-strings`, i.e.
U-Boot's `fdt_find_regions`). The remaining non-determinism the vendor tools introduce is removed
in-build by `deterministic-sign.sh`:

- **PSS salts:** the vendor tools draw random salts; ours derive them as `shake_256("seedsigner-pss-v1\0"
  || mhash)`, which RFC 8017 verification accepts unchanged.
- **The FIT `timestamp`:** mkimage 2017.09 writes a **live wall-clock `timestamp`** into
  `/configurations/conf/signature` (it does not honour `SOURCE_DATE_EPOCH`; two values ~19 minutes apart
  were observed within a single build). It sits *outside* the signed region — `hashed-nodes` does not
  list the signature node — so it is zeroed without invalidating anything.
- **`releaseTime`** in `download.bin` / `update.img`: pinned by `normalise_boot_images()` (floored at
  2025-01-01 — [§2.1](#21-build-it-signed-on-a-pc)).

### 4.9 The hardware crypto driver is not built

`opt/luckfox/os-build.sh` sets `CONFIG_CRYPTO_DEV_ROCKCHIP=y` and asserts it, but the hardware crypto
driver is **absent from the running kernel** (bench-confirmed) — `/proc/crypto` has no `rk` algorithms
and `ff440000.crypto` is unbound. The umbrella symbol needs `CONFIG_CRYPTO_DEV_ROCKCHIP_V3=y` (the
RV1106 sub-option) to compile any code, and the build's assertion only greps the defconfig text, so it
reports success regardless. Harmless — SeedSigner uses software crypto — but pinning `&crypto` in the
DTS is currently a no-op. The `&rng` pin, by contrast, is real and working (see
[`docs/hwrng.md`](../hwrng.md)). This is the Linux driver; U-Boot's PKA use (§4.1) is separate and works.

---

## 5. Implementation notes

### 5.1 Rootfs verification: design

The vendor chain stops at `boot.img`. The rootfs is a separate partition (103M on the Mini, per
`opt/luckfox/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch`), so closing that gap
was our design.

**Where verification logic can run:**

| Layer | What is possible | Verdict |
|---|---|---|
| **SPL / U-Boot** | RSA-2048 only (already compiled in). Anything more means porting crypto into U-Boot C. OpenPGP parsing is not realistic here. | **Do not put policy at this layer.** |
| **initramfs inside `boot.img`** | Full userspace before pivoting to the real rootfs. Arbitrary logic: signature schemes, m-of-n thresholds, key rotation, revocation. | **This is the right layer.** |

`boot.img` is a FIT, and FIT supports a ramdisk: the `sign-images = fdt kernel multi` list simply gains
`ramdisk`, so **an initramfs is covered by the same RSA signature that already protects the kernel** —
no new cryptographic machinery.

**Space budget.** boot partition **4M**; stock `boot.img` **2.65MB**; headroom **~1.3MB**. That fits
busybox plus a compact verifier. It does **not** fit GnuPG2, which is already in the rootfs at ~2MB
(`opt/luckfox/configs/luckfox_pico_defconfig:490-491`).

**Pin a key, not a hash.** There is an in-repo precedent for hash pinning:
[`opt/rootfs-overlay/etc/mdev/mdev.sh`](../../opt/rootfs-overlay/etc/mdev/mdev.sh) refuses to mount
`diy-tools.squashfs` on a SHA256 mismatch (`REFUSED_HASH_MISMATCH`, see
[`docs/diy_tools.md`](../diy_tools.md)). That model is rigid: a pinned hash authorises exactly one
rootfs, so every update requires re-signing `boot.img`. A pinned *public key* inside the signed
`boot.img` authorises many future rootfs images, giving **rootfs updates without re-burning OTP or
re-signing the loader.** It does not escape having a pinned trust root; it upgrades it from a value to
an authority.

**Candidate signature schemes considered:**

| Scheme | Approx. size | Notes |
|---|---|---|
| Bitcoin signed message | ~200–300KB | Signing key can live on a hardware wallet or another SeedSigner; familiar UX for this audience; m-of-n is natural |
| minisign / signify (Ed25519) | ~50KB | Smallest and simplest parser — **chosen** |
| Full GnuPG | ~2MB | Matches existing release-signing practice; largest pre-boot attack surface |

> **Attack-surface caveat.** Anything in the initramfs runs *before* the rootfs is verified and is
> itself protected only by the `boot.img` signature. A large, historically CVE-prone format parser
> (OpenPGP especially) is a poor thing to expose pre-boot.

**Verify in full, not lazily.** The original plan was to sign a **dm-verity root hash** so that only a
small check runs at boot. **dm-verity does not work on UBI at all** (2026-09-13 correction): lazy
per-block verification requires the *physical* block layout to be stable between writes, and UBI's
wear levelling rewrites LEBs, so a block offset that verified yesterday points at different bytes
today. The **logical** volume contents are stable (what `/dev/ubi0_0` / `/dev/ubiblock0_0` expose), but
not their physical location. On eMMC (Pico Pi) a raw block root could use dm-verity; on NAND the only
sound scheme is signing the logical contents and checking them in full at boot — one full SPI-NAND
read of the volume per power-on (a few seconds, bench §7.7), while the device is otherwise idle.

### 5.2 Rootfs verification: implementation

Implemented for **every boot medium** — NAND, MicroSD and eMMC — behind `SEEDSIGNER_FIT_SIGNATURE=1`
(the same opt-in that signs `boot.img`). Everything is in `opt/luckfox/`; nothing changes for
unsigned builds. The one board-specific mapping currently implemented is the Mini's DTS
(`apply_signed_nand_bootargs`); other profiles skip bootargs baking with a notice rather than
guessing.

**What is signed, and when.** The rootfs image bytes exactly as they reach the kernel are
minisign-signed at build time **in pre-hashed mode (`-H`)**: minisign streams the image in
64 KiB chunks through BLAKE2b-512 and signs the 64-byte digest, so neither signing nor verification
ever holds the whole image in RAM. The hashed mode is recorded inside the `.minisig` itself (signature
algorithm field `"ED"`), which makes verification self-describing. Which hook fires depends on the
medium:

* **NAND** — [`secure-boot/patch-mkfs-ubi-signing.sh`](../../opt/luckfox/secure-boot/patch-mkfs-ubi-signing.sh)
  hooks the SDK's `mkfs_ubi.sh` after its common ubinize line (so it covers every fs type): the
  volume's *logical* contents — the exact `.ubifs` file (dev variant) or `.squashfs` file (non-dev
  readonly-rootfs) that gets packed into UBI — are signed, and the signed size recorded in
  `rootfs.ubifs.size`. Signing runs inside the fakeroot script with a vendored x86-64 minisign
  (`initramfs-binaries/minisign-host`).
* **MicroSD / eMMC** — [`secure-boot/patch-mkfs-squashfs-signing.sh`](../../opt/luckfox/secure-boot/patch-mkfs-squashfs-signing.sh)
  appends a hook to the SDK's `mkfs_squashfs.sh` (the raw-partition builder; no UBI involved). The
  stock SD/eMMC board configs use squashfs for rootfs in both variants, and the SDK writes that file
  **verbatim** to partition offset 0 (`build_mkimg`, fs_type=squashfs), so the signed prefix is exactly
  what the kernel sees; the rest of the (6G) partition is untrusted padding the verifier never reads.
  The hook runs at EOF — after patch-fs-determinism's superblock `mkfs_time` pin, which rewrites bytes
  of the image — and records the signed size in `rootfs.img.size`.

Both hooks are gated on `SEEDSIGNER_ROOTFS_SIGNING_KEY` (exported by `os-build.sh` only when
`SEEDSIGNER_FIT_SIGNATURE=1`) with the same key and trusted comment, so one public key covers every
medium; signatures are deterministic (explicit trusted comment, no timestamp). Peak RAM during
verification is ~128 KiB regardless of rootfs size — a full 93 MiB NAND volume or a multi-GB MicroSD
partition verify the same way (without `-H`, minisign mallocs the entire message on both sides; 2×38 MB
already OOMs the 64 MiB Mini's initramfs).

**What verifies, and where.** After `build.sh firmware`, `os-build.sh`'s `embed_rootfs_verifier()`
assembles a small initramfs — busybox + minisign + an ST7789 status display (`ss-lcd`) + the public key
+ the signature + `/init` — as a deterministic cpio.gz (sorted entries, pinned mtime,
`cpio --reproducible`, `gzip -n`; all four binaries SHA-256-pinned in-repo) and repacks it into
`boot.img`'s FIT **ramdisk slot** (`fit-unpack.sh` → add node + conf entry + `"ramdisk"` in sign-images
→ `mkimage -E`). `sign_boot_image()` then re-signs the whole FIT, so the verifier is covered by the
same RSA signature that protects the kernel. The signature, the public key and the signed size
(`ROOTFS_SIGNED_SIZE` in `/init`) all live in that initramfs, which is why re-signing the rootfs
rewrites `boot.img` ([airgapped-signing.md](airgapped-signing.md#changing-the-rootfs-key)).

**Boot flow.** The medium-specific setup happens in the signed DTB: NAND bakes
`ubi.mtd=6`/`ubi.block=0,rootfs` (UBI auto-attach), MicroSD/eMMC bake `rootfstype=squashfs` next to the
stock `root=/dev/mmcblk1p7` — required because on a signed FIT U-Boot ignores the env partition's
`sys_bootargs` entirely ([§4.6](#46-the-kernel-command-line-envf-and-autoboot)). `/init` then reads
`root=` from the command line to learn the presentation (squashfs-on-ubiblock, raw UBIFS, or
raw-partition squashfs at `/dev/mmcblk*`), waits for the device, checks whether secure boot is fused on
*this board* (see **Fuse detection** below), and — unless skipped — **streams** the rootfs bytes
straight into `minisign -V`: `dd` reads ceil(size/4096) blocks from the volume/partition device and
pipes them through `head -c <signed size>` (UBI autoresize pads the volume, and the SD/eMMC partition
tail is zero-filled padding — both beyond the signed prefix) into minisign's stdin. Because the
signature records pre-hashed mode, minisign BLAKE2b-512s the pipe in 64 KiB chunks — no temp file,
O(1) RAM end-to-end. A short or failed read yields fewer bytes → digest mismatch → fail-closed,
indistinguishable from a tampered rootfs. Only then does `/init` mount + `pivot_root` to `/sbin/init`.
Progress is shown on the LCD and logged to UART (`rootfs-verify:` prefix).

**Failure policy: red FAIL screen + halt — with a physical escape hatch.** On a mismatch (or read
error) `/init` shows `FAILED / rootfs signature mismatch / press <KEY>` in red and blocks in
`ss-lcd waitkey`: it configures GPIO1_C7 as an input (the same IOMUX/pull-up/direction/IE register
sequence `/usr/bin/configure-gpio.sh` applies before each app launch — the RV1106 pinctrl driver
silently ignores gpiolib bias flags) and polls it until pressed. That pin is wired to a button on every
Luckfox variant (KEY_DOWN on Mini, KEY1 on Pro Max, KEY3 on Pico Pi), so one baked-in program works for
all three boards; only the label shown differs (`__WAITKEY_KEY_NAME__`, substituted at build time). A
person with physical access presses it to boot an **UNVERIFIED** rootfs (green `BOOTING`,
`WARN: … continuing with UNVERIFIED rootfs` on UART, and no green PASSED screen); without the press
the board halts — no reboot loop; a fused board keeps refusing until a correctly signed image is
flashed, recovery is a power-cycle.

**Dev-key indicator.** A *passing* verification is not the same as a *protective* one: while a build
uses the committed PUBLIC dev keys (see [`secure-boot/dev-keys/README.md`](../../opt/luckfox/secure-boot/dev-keys/README.md)
and [`dev-keys-rootfs/README.md`](../../opt/luckfox/secure-boot/dev-keys-rootfs/README.md)), anyone can
sign firmware, so a green PASSED would overstate the protection. `embed_rootfs_verifier()` classifies
each signature at build time by comparing the **actual key bytes** against the committed dev pubkeys
(SHA-256 — not paths, so a copy of the dev key under another name is still flagged): FIT against
`$ubootdir/keys/dev.pubkey` (laid down by `provision_fit_build_keys()`), rootfs against the
`dev.pubkey` that becomes `/pubkey`. The classes (`dev`/`prod`) are substituted into `/init`, which —
only when verification actually ran, i.e. on a fused board — shows **yellow**
`PASSED / FIT: <class> / rootfs: <class>` if either signature is dev, and the usual green
`PASSED / rootfs signature valid` only when both are real keys. The re-sign tools update these classes
when they change keys (`luckfox_release.rework_initramfs`). Unfused boards show nothing about key
classes (the orange *SECURE BOOT not enabled* screen already covers that).

**Fuse detection.** The same signed image must boot both fused and unfused boards, so `/init` decides
per-board whether verification applies — and it does **not** read the OTP itself
([§4.5](#45-otp-what-linux-can-and-cannot-see)). It parses U-Boot's own verdict off the kernel command
line: `fuse.programmed=1/0`, which `param_parse_pubkey_fuse_programmed()`
(`arch/arm/mach-rockchip/param.c`) appends to `bootargs` from the preloader's `ATAG_PUB_KEY` — i.e. the
BootROM's direct read of the secure-boot fuses, passed through U-Boot (which on a fused board is itself
signature-verified before that line runs). The rule is **verify by default**: only an explicit
`fuse.programmed=0` with no `fuse.programmed=1` anywhere skips the check. That direction matters —
`=1` can only come from the ROM atag (never from env), so an attacker who can write the env partition
cannot forge fusion, and on a fused board the genuine `=1` survives any injected `=0`. A missing flag (a
different U-Boot build) verifies too: checking when unneeded costs ~15 s of boot; skipping on a locked
device defeats the feature. On an unfused board `/init` shows an orange
`SHIELDSIGNER / SECURE BOOT not enabled` screen held for 5 s, then boots without verifying.

**Forced verification on unfused boards (opt-in).** If the initramfs contains `/force-rootfs-verify`,
an unfused board verifies the rootfs anyway. The build adds it with
`SEEDSIGNER_ROOTFS_VERIFY_UNFUSED=1` (workflow input `rootfs_verify_unfused`, default off); the app's
*Luckfox Build Tools → Force Rootfs Check* adds or removes it on an existing release and re-signs
`boot.img` (refused on the Pico Mini, where it crashes); 
`tools/airgap-sign.py force <bundle> --card <mount>` (or `--off`) is the PC-side counterpart ([§2.4](#24-air-gapped-signing)). A pass shows an
**orange** `PASSED / rootfs valid / SECURE BOOT / not enabled` panel (held 5 s), never the green one; a
failure is the usual red screen with its escape key. It gives **no real protection** — without the fuse
nothing checks the initramfs either, so anyone who can rewrite the rootfs can rewrite the checker — but
it proves the flashed image is intact and exercises the verifier before a board is ever fused. It is a
marker file rather than a baked-in value, so a tool can set it without editing `/init`; releases whose
`/init` predates it do not mention the path, and the tools refuse to set it there. (Not yet bench-run.)

**Keys.** The default keypair in [`secure-boot/dev-keys-rootfs/`](../../opt/luckfox/secure-boot/dev-keys-rootfs/)
is **public and committed** — no protection, but reproducible builds and a recoverable failure mode,
mirroring the FIT dev-key pattern. A real key is `SEEDSIGNER_ROOTFS_KEY_DIR` +
`SEEDSIGNER_ROOTFS_KEY_PASSPHRASE` at build time ([§2.1](#21-build-it-signed-on-a-pc)), or any of the
re-sign methods afterwards. The public key ships *inside the signed initramfs*, so "pin an authority,
not a value" holds: rootfs updates only need re-signing with the same key, no OTP or loader work.

**Known limits.** Verification is a full-volume read per power-on (dm-verity is impossible on UBI,
§5.1). The env-partition residual in [§4.6](#46-the-kernel-command-line-envf-and-autoboot)
(`mtdparts`/`blkdevparts`) can redefine the MTD layout and, since the value is appended unfiltered,
smuggle trailing parameters; it cannot make verification pass (an unsigned volume still fails minisign),
but `CONFIG_CMDLINE_FORCE` remains the outstanding piece for full lockdown. The escape hatch is a
deliberate, physical-access-gated exception to fail-closed behaviour — it exists so a bad flash does not
lock out the only recovery path on a fused board.

---

## 6. Possible future work

Secure boot as implemented answers one question: *is the firmware on this board signed by the key it
was fused to?* Several related protections are **not implemented yet**. They are collected here with
what exists today, what the platform offers, and where the details are, so nobody mistakes a design
note elsewhere in this document for a shipped feature.

| Protection | Status today | Section |
|---|---|---|
| Recognising the physical device (anti-phishing words, device PIN) | **Not implemented.** A look-alike running its own correctly signed firmware is not detected | [§6.1](#61-device-identity-pin-and-anti-phishing-words) |
| Anti-rollback (refusing an older genuine release) | **Not implemented at any stage.** A fused board boots any release signed with its key, including an old one | [§6.2](#62-anti-rollback) |
| OP-TEE (on-die secret, `boot.img` rollback) | **Not shipped.** The blob is in the SDK; nothing packs or enables it | [§6.3](#63-op-tee) |
| Full kernel command-line lockdown | **Partial.** `root=` is signed; `mtdparts`/`blkdevparts` are still importable from the env partition | [§6.4](#64-full-kernel-command-line-lockdown) |
| Locking the U-Boot console | **Not done.** `CONFIG_BOOTDELAY=0` is interruptible from the UART | [§6.5](#65-locking-the-u-boot-console) |
| Hardening removable media (`sd_update.txt`) | **Not done.** The update script still auto-runs unsigned | [§6.6](#66-hardening-removable-media) |
| Hardware-held signing keys (HSM/PKCS#11) | **Untested.** The air-gapped SeedSigner signer is the supported custody path | [§6.7](#67-hardware-held-signing-keys) |
| Recording the OTP hash when arming | **Not done.** Only the burn-time UART log and the NAND idblock record it | [§6.8](#68-recording-the-otp-hash-at-arm-time) |
| Rootfs signatures independent of `boot.img` (key slots + quorum) | **Not implemented.** One key and one expected signature are baked into the signed `boot.img`, so every rootfs change means rebuilding and reflashing `boot.img` | [§6.9](#69-decoupling-the-rootfs-from-bootimg-key-slots-and-a-signing-quorum) |
| Disabling the maskrom (USB download) interface | **Not implemented or tested** — per Rockchip's release notes the shipped DDR blob predates support. The BOOT button still enters maskrom on a fused board | [§6.10](#610-disabling-the-maskrom-download-interface) |

### 6.1 Device identity: PIN and anti-phishing words

**Status: design only — nothing in the app or OS implements this.** Nothing today lets a user tell
their own SeedSigner from a look-alike built by someone else and running that person's own, correctly
signed firmware. The design below is how it could be done on this hardware.

#### The gap they close

Secure boot answers "is the firmware on *this* device genuine?". It can't answer "is this the device I
set up?", because, as V1.9 puts it, it verifies software, not hardware. Suppose someone swaps your
SeedSigner for a look-alike: their own board and firmware inside your case. That device verifies its
*own* boot chain perfectly well, so nothing in §1.2 notices. It can capture a seed as you enter or scan
it, or show a doctored transaction summary, and leak data later through a QR code.

Anti-phishing words would close that gap. The genuine device would show words only it can compute; a
look-alike couldn't produce them. The two mechanisms depend on each other:

| Attack | Stopped by |
|---|---|
| Tampered firmware on *your* device | Secure boot |
| A look-alike device swapped in for yours | Anti-phishing words (not implemented) |

Without secure boot the attacker doesn't need a look-alike. They reflash *your* device with firmware
that reads the real secret, shows the real words, then steals the seed.

You set the words up the first time you use the device, so they protect every use after that. They
can't catch a device that was swapped before you ever set it up.

#### How it works

The PIN is split into a **prefix** and a **suffix**, the same flow as Coldcard's anti-phishing words.

1. **Setup, once.** The device generates a 32-byte `device_secret` from the hardware RNG
   ([`docs/hwrng.md`](../hwrng.md)) and stores it (see *Where the device secret lives*). The user picks
   a PIN, for example a 6-digit prefix plus a 4-digit suffix. The device shows the two words for that
   prefix, the user memorises them, and the device stores a verifier for the full PIN.
2. **Every boot.** Enter the prefix and the device shows two words. **If they're wrong, stop:** don't
   enter the rest, and don't use the device. If they're right, enter the suffix; the device checks the
   full PIN and unlocks.

The PIN is split because the words have to appear *before* you've typed the whole PIN into what might
be a fake. A fake only learns the prefix, and the prefix can't produce the words without the device
secret.

The device shows words for *any* prefix. If it rejected wrong prefixes, it would reveal which one is
correct. So there is no "wrong prefix", only a different pair of words.

#### Deriving the words

```
k0    = HMAC-SHA256(key = device_secret,
                    msg = "seedsigner/anti-phishing/v1" || board_id || prefix)
k     = PBKDF2-HMAC-SHA256(password = k0, salt = "seedsigner/anti-phishing/v1",
                           iterations = N)            # tune N to ~1 s on the device
words = BIP39_WORDLIST[bits 0-10 of k], BIP39_WORDLIST[bits 11-21 of k]
```

- **Key the HMAC with the secret first.** This is what defeats a fake: without `device_secret` it can't
  compute `k0`, even after watching you type the prefix. A plain `hash(prefix)` would be useless,
  because a fake could compute it too.
- **Then slow it down.** Anyone wanting to map *every* prefix to its words has to do it on the genuine
  device, at about a second each. For a 6-digit prefix that's roughly 11 days of continuous entry. This
  only helps while the secret can't be copied off the device; with a copied secret, the enumeration
  runs offline on fast hardware.
- **`board_id`** should be the per-device value the kernel already derives into the `Serial` line of
  `/proc/cpuinfo` (a 64-bit id; `d6d9fb7e70873741` on the test board). **Bench-checked correction:**
  this is *not* the raw `otp_id` cell. `otp_id` at OTP offset `0x0a` reads `M4T961...`, a wafer/lot
  marking that may not be unique per die; the kernel hashes it (with `cpu_code`/`cpu_version`, per the
  `rockchip,cpuinfo` node) into the `Serial` (bench row A2). Use the derived `Serial`. It isn't secret,
  but mixing it in ties the words to this SoC, so a copied SD card in someone else's board gives
  different words. Matters most on SD boards, where the card is the easy part to copy.
- **Two BIP39 words give 22 bits**, so a fake guessing blindly is right about once in 4 million. Label
  them clearly on screen so they can't be mistaken for seed words.
- **Full-PIN verifier:** store
  `PBKDF2(full_pin, salt = HMAC(device_secret, "seedsigner/pin-verifier/v1"), iterations = N)` and
  compare in constant time. Because the salt is keyed with the secret, a stolen verifier can't be
  brute-forced offline without the secret too.

The domain-separation strings stop one derived value being substituted for the other. The app already
runs PBKDF2 for BIP-39 seeds, so the primitives are in place. This belongs in the app repo and runs
before the main menu (or inside a trusted app once OP-TEE is in).

Anyone who sees your prefix and later has your device for a moment can learn your words. Guard the
prefix like the rest of the PIN.

#### Where the device secret lives

Everything above depends on the secret staying on the device, and RV1106 makes that hard:

| Storage | Copyable by someone who had the device briefly? | Available without OP-TEE? |
|---|---|---|
| File on a writable partition (e.g. `userdata`) | **Yes.** On SD boards: pull the card. On NAND boards: dump the flash, or use `sd_update.txt` while it's enabled | Yes |
| On-die OTP, written from Linux | n/a | **No.** RV1106's nvmem driver is read-only (`rv1106_data` in `drivers/nvmem/rockchip-otp.c` has no `.reg_write`) and its 128 bytes hold factory cells. The OEM write path (`rv1126_otp_oem_write`) exists only for RV1126 |
| Secure OTP Protected OEM Zone | **No.** On-die, and readable only by trusted apps the TEE accepts (OTP guide §3.1) | **No, needs OP-TEE.** The Non-Protected zone and the OEM Cipher Key are reached through OP-TEE too; "Non-Protected" only means normal-world code may *read* it via the TEE |
| Secure OTP via a custom SPL patch | No | **Possibly.** SPL already reads and writes secure OTP directly (`misc_otp_read`/`misc_otp_write` on `OTP_S`, as the rollback counter does), but it needs a spare region and none is documented (Q15) |
| Smartcard | No | **Doesn't close the gap.** A secret on the card authenticates the *card*: your genuine card in a look-alike still computes the right words. It's the right tool for protecting keys *on* the card, not for recognising the device |

**Recommendation:**

1. **Ship v1 with the secret in a file, bound to `board_id`.** It needs no fuse and no OP-TEE, and it
   defeats a pre-built look-alike from someone who never had your device, which is the common swap. It
   doesn't defeat someone who had your device long enough to copy the secret. Say so plainly in the UI
   and the docs.
2. **Then move the secret into OP-TEE's Protected OEM Zone** ([§6.3](#63-op-tee)).
   This is the documented route to an on-die secret that normal-world code can never read. Compute the
   words inside a trusted app (TA), so the secret never enters Linux memory and the TA enforces the slow
   derivation itself. The same integration delivers `boot.img` rollback protection
   ([§4.7](#47-removable-media-sd_updatetxt-signed-images-and-rollback)). If OP-TEE is ever dropped, the
   SPL patch is the fallback.
3. **Either way, none of this means anything without secure boot** stopping the firmware on your own
   device being replaced.

#### What the PIN itself protects

SeedSigner stores no seed at rest, so in this design the full PIN would mainly gate the UI and carry
the anti-phishing check. A failure counter needs storage that can only count upward. A counter on a writable partition
can be reset by anyone who can write that storage, so it deters a casual finder, not a determined
attacker. OP-TEE doesn't fully fix this on NAND or SD boards (§6.3). If encrypted persistent settings
are added later, derive their key from the full PIN and `device_secret`; then the PIN protects real
data.

To slow down prefix enumeration without a persistent counter, cap prefix attempts per boot (say
three), then force a reboot. At ~15 s per reboot, trying all 10^6 prefixes takes about two months.
That helps whenever the secret can't be copied off the device.

### 6.2 Anti-rollback

**Status: not implemented at any stage.** A fused board boots any release signed with its key —
including a genuine but older one with known bugs. Anyone who can flash the device (maskrom, or
`sd_update.txt`, §6.6) can downgrade it to such a release. Nothing in the build sets a rollback index.

What the platform offers, per stage:

- **SPL → `uboot.img`: supported by the SDK, unused.** The SPL can enforce a rollback index read
  directly from secure OTP (the counter at `0xe0`, `OTP_UBOOT_ROLLBACK_OFFSET`, 8 bytes), and
  `fit-sign.sh --rollback-index uboot.img <n>` writes `rollback-index = <n>` into the ITS (Q11). The
  counter is a one-way fuse with 64 increments: raising it is irreversible, and every older
  `uboot.img` is refused afterwards — so the recovery images you keep must be kept current too.
- **U-Boot → `boot.img`: needs OP-TEE or a patch.** `CONFIG_FIT_ROLLBACK_PROTECT` exists, but U-Boot
  proper reads the index through an OP-TEE client call, and `fit-sign.sh` refuses a `boot.img` index
  without `CONFIG_OPTEE_CLIENT` ([§4.7](#47-removable-media-sd_updatetxt-signed-images-and-rollback)).
  Options: adopt OP-TEE ([§6.3](#63-op-tee)), or patch U-Boot to compare the FIT index against a floor
  compiled into a rollback-protected `uboot.img` (Q14).
- **initramfs → rootfs: nothing yet.** The verifier accepts any rootfs signed with the pinned key. A
  version floor could live in the signed initramfs and be compared against a version carried in the
  minisign trusted comment (which the signature covers) — an unexplored idea.

Whatever is chosen, the re-sign tools ([§2](#2-signing-a-release)) would need to carry the indexes
through, and a device-side check should refuse to arm a release whose index would lock out the
recovery images.

### 6.3 OP-TEE

**Status: not shipped.** Nothing packs, enables or uses it today; this is a design for adopting it.


Earlier revisions recorded OP-TEE as considered and rejected. It is **now worth adopting**, because it
does two jobs nothing else on this chip does as well:

- **An on-die device secret for anti-phishing words** that normal-world code can never read: the
  Protected OEM Zone (§6.1). Without OP-TEE, Linux can't write any RV1106 OTP region at all.
- **`boot.img` rollback protection**, which stock U-Boot enforces only through OP-TEE (§4.7, §6.2).

The trade-off hasn't gone away: this puts a **closed-source secure-OS blob, running at higher privilege
than the kernel,** on a device whose selling point is auditability. It would be accepted knowingly, for
those two uses.

#### What is already there

The blob is in the SDK: `rkbin/bin/rv11/rv1106_tee_ta_v1.11.bin`, a build that can run trusted apps.
Upstream rkbin has moved on to `rv1106_tee_ta_v1.14.bin`, and its release notes say v1.12 added "OTP
hardware lock, allowing secure and non secure OTP access simultaneously". Linux reads the chip ID from
non-secure OTP while the TEE uses secure OTP, so the newer blob is probably worth using. Check its
release notes before switching. `RKTRUST/RV1106TOS.ini` points at it
(`TOSTA=bin/rv11/rv1106_tee_ta_v1.11.bin`, `ADDR=0x03000000`), and the U-Boot FIT generator is
`make_fit_optee.sh`. **None of it ships today.** Checked against a built image:

- the `uboot.img` FIT's `/images` holds only `uboot` and `fdt`, even though its description string reads
  "FIT Image with ATF/OP-TEE/U-Boot/MCU"
- the kernel has no `CONFIG_TEE` / `CONFIG_OPTEE`
- the shipped DTB has no `optee` node (`rv1106.dtsi` defines one with `status = "disabled"`)

#### Integration work

1. Pack `rv1106_tee_ta_v1.11.bin` into `uboot.img`. On RV1106 the TEE lives in `uboot.img`; there is no
   separate `trust.img` (TEE SDK §3.3).
2. Kernel: set `CONFIG_TEE=y` and `CONFIG_OPTEE=y`, and set the DT `optee` node to `okay` (TEE SDK
   §3.5.2). `/dev/tee0` and `/dev/teepriv0` should then appear.
3. Userspace: `tee-supplicant` and `libteec.so` from the SDK's own `media/security/bin/optee_v2/` (TEE
   SDK §3.6), not upstream Buildroot's `optee-client`, so that they match the TEE binary. There is a
   `uclibc_lib/` variant, which matters because the Luckfox rootfs is uClibc. The SDK warns that
   mismatched U-Boot/TEE/library versions fail with API-revision errors.
4. A trusted app that keeps the device secret in the Protected OEM Zone and computes the words
   internally.
5. **Replace the TA signing key before shipping** (TEE SDK §5). The TEE binary holds an RSA-2048 public
   key and runs only TAs signed with the matching private key, and only TAs it accepts can reach the
   Protected OEM Zone. **The default private key is public:** it's committed in the SDK at
   `media/security/rk_tee_user/v2/export-ta_arm32/keys/oem_privkey.pem`. While it stays in place, anyone
   can sign a TA your device will run, and that TA can read the secret. To replace it:
   1. Run `media/security/rk_tee_user/v2/tools/change_puk_tool-release --teebin <TEE binary>` (TEE SDK
      §5.2 calls it `change_puk`). It generates a new key and patches the public half into the TEE
      binary.
   2. Rename the key to `oem_privkey.pem` and put it in `rk_tee_user`'s keys directory.
   3. Rebuild the TAs. Prebuilt TAs signed with the old key, such as the one in
      `media/security/bin/optee_v2/ta/`, will stop loading. Re-sign any you still need with
      `ta_resign_tool-release`, which is in the same `tools/` directory.
   4. Rebuild `uboot.img` (RV1106 has no `trust.img`).

   That makes a third key to guard, alongside the boot-chain RSA key and the rootfs key, and the patched
   TEE binary becomes a build input.
6. U-Boot: `CONFIG_OPTEE_CLIENT`, which also unlocks `boot.img` rollback via
   `fit-sign.sh --rollback-index boot.img <n>`.

#### Limits worth knowing

- **Memory:** TEE_RAM 1M + TA_RAM 1M + SHMEM 512K (TEE SDK §10.2), about 2.5MB of the Mini's 64MB,
  where DRAM is already tight.
- **NAND and SD boards have no RPMB.** Secure storage there sits in a `security` partition on ordinary
  flash (TEE SDK §3.2, §11.1). It's encrypted, but an old copy can be written back, so a PIN failure
  counter kept there can still be reset. A counter that truly can't go backwards needs RPMB (eMMC, so
  only the Pico Pi) or OTP bits.
- **How strongly secure storage is tied to the chip isn't documented for RV1106.** TEE SDK §12
  (chip-bound storage keys) is scoped to RK3588/RK3528/RK3562. rkbin's RV1106 release notes do say TEE
  v1.10 added "security level" support with derived secure storage keys, so some binding probably
  exists, but it's undocumented — one more reason to keep the device secret in the Protected OEM Zone.
- **Trusted UI is still unavailable** for the SPI display. The TEE protects the secret, not what the
  screen shows.

### 6.4 Full kernel command-line lockdown

**Status: partial.** On signed builds `root=` and the rootfs arguments are baked into the signed DTB and
the env partition cannot set `sys_bootargs`, but `mtdparts`/`blkdevparts` are still imported from the
unsigned env partition and merged into the command line. A redefined layout cannot make an unsigned
rootfs verify, but the residual is not zero. The full fix is `CONFIG_CMDLINE_FORCE=y` (untested on the
5.10 kernel), or stripping those names from `CONFIG_ENVF_LIST` — mitigations and history in
[§4.6](#46-the-kernel-command-line-envf-and-autoboot); open question Q13.

### 6.5 Locking the U-Boot console

**Status: not done.** The build sets `CONFIG_BOOTDELAY=0` (`opt/luckfox/uboot-recovery-config.sh`),
which is still interruptible: holding CTRL+C on the UART at power-on reaches a U-Boot prompt, even on a
fused board (bench row B1), and that prompt can read and write memory. A locked-down build needs
`CONFIG_BOOTDELAY=-2` and `CONFIG_CONSOLE_DISABLE_CLI=y`
([§4.6](#46-the-kernel-command-line-envf-and-autoboot)), checked on hardware against the recovery
failover that `uboot-recovery-config.sh` configures.

### 6.6 Hardening removable media

**Status: not done.** U-Boot still auto-runs `sd_update.txt` from any inserted card before the kernel
loads. It is how *Provision MicroSD* updates work, and it is unsigned code execution: on a fused board it
cannot make unsigned firmware boot, but it can erase or overwrite any partition. A hardened build would
drop the auto-run, or require a signed script, and only ever load, verify and then write signed images —
never the env partition ([§4.7](#47-removable-media-sd_updatetxt-signed-images-and-rollback)).

### 6.7 Hardware-held signing keys

**Status: untested.** The supported way to keep the key off a networked machine is the air-gapped
SeedSigner signer ([§2.4](#24-air-gapped-signing)). Other routes the tools allow but nobody has
exercised: `rk_sign_tool`'s native HSM settings (Q8b), upstream `mkimage -N pkcs11` for the FITs (Q6),
a PIV/PKCS#11 token exposing raw RSA through the digest boundary
([airgapped-signing.md](airgapped-signing.md#smartcards)), and `rk_sign_tool`'s secondary certificates
for a root/delegate key hierarchy (Q10).

### 6.8 Recording the OTP hash at arm time

**Status: not done.** Once a board is fused, the key hash it expects can only be recovered from the
burning idblock on NAND or found by trial ([§3.5](#35-which-key-is-a-fused-board-expecting)). The app's
Arm eFuse Burn could write the "SPL burns" hash next to the release (for example `otp-key-hash.txt`) and
show it on screen, so every fused board has a record of the key it expects.

### 6.9 Decoupling the rootfs from `boot.img`: key slots and a signing quorum

**Status: not implemented.** Today the rootfs trust is a single key and a single expected signature,
both baked into the signed `boot.img` ([§5.2](#52-rootfs-verification-implementation)): the
initramfs carries `/pubkey`, `/rootfs.sig` and the signed size (`ROOTFS_SIGNED_SIZE` in `/init`), and
`rootfs.img` carries no signature at all. Consequences:

- **Any rootfs change means a new `boot.img`.** Even with the rootfs key unchanged, the new signature
  and size have to go into the initramfs, so `boot.img` is rebuilt, RSA re-signed (tier B) and
  reflashed alongside `rootfs.img`. A rootfs-only update is impossible.
- **The RSA key is needed for every release**, not just for kernel or bootloader changes.
- **One key is a single point of failure.** Whoever holds the rootfs key alone decides what rootfs a
  fused board runs; there is no way to require agreement between several signers.

**The goal:** `boot.img` pins a *policy*, not a signature. The rootfs carries its own signatures, and
it can be replaced without touching `boot.img`, as long as it is signed by a valid quorum under that
policy. This extends "pin a key, not a hash" ([§5.1](#51-rootfs-verification-design)) from one key to
a set of keys.

**Sketch:**

1. **Key slots and a threshold in `boot.img`.** The signed initramfs carries *N* public-key slots and a
   threshold *M* (e.g. 2-of-3), instead of one `/pubkey`. The slots and threshold are covered by the
   `boot.img` signature, so changing the policy itself still needs the RSA key and a new `boot.img` —
   that is the point. Empty slots allow keys to be added later by the same route.
2. **Signatures travel with the rootfs.** A small signature block stored next to the rootfs holds up to
   *N* signatures, each naming its key. Where it lives depends on the medium:
   - on MicroSD/eMMC, a trailer after the signed squashfs prefix inside the rootfs partition, which is
     padding today;
   - on NAND, a second small UBI volume, or a trailer inside the rootfs volume after the signed length.

   Either way, `rootfs.img` becomes self-contained.
3. **What each signature covers.** A small manifest, not just the image digest: the image digest
   (BLAKE2b-512, as today), the signed size (which today comes from `/init`), a version number (for
   anti-rollback, [§6.2](#62-anti-rollback)), and a domain tag, so a signature can't be replayed
   elsewhere. Everything the verifier trusts about the rootfs then comes from signed data, not from
   `boot.img`.
4. **Verification.** `/init` streams the rootfs once (as today) to get the digest, reads the
   manifest, and checks every signature against the slots. It counts **distinct keys** with a valid
   signature over *this* manifest and boots only if the count reaches the threshold. The failure
   policy stays the same: red screen, halt, physical escape key.
5. **Tooling.** Re-signing a rootfs becomes: compute the manifest, have each quorum member sign it
   (air-gapped SeedSigners are a natural fit — each signer is one Sign Digest round-trip), and splice
   the signatures into the block. `boot.img` and the RSA key are not involved. `check` reports how many
   valid signatures are present against the threshold.

**Things to get right:**

- **Pre-boot attack surface.** The signature block is parsed before the rootfs is verified, so the
  format must be trivial and fixed-size (no general-purpose container parser), in keeping with the
  minisign-over-GnuPG reasoning in [§5.1](#51-rootfs-verification-design).
- **Scheme choice.** Several minisign/Ed25519 signatures are the smallest change from today. Bitcoin
  signed messages were the other candidate in §5.1 and make m-of-n natural for this audience.
- **Anti-rollback.** A quorum does not stop an *old* quorum-signed rootfs from being flashed. The
  version in the manifest only helps once there is a floor to compare it with ([§6.2](#62-anti-rollback)).
- **Key rotation and revocation.** Rotating a quorum member still needs a new `boot.img`, since the
  slots live there. Keeping spare slots and a threshold below *N* lets a lost key be tolerated
  without re-signing `boot.img` immediately.
- **The dev-key indicator** (yellow/green PASSED) and the re-sign tools, which rewrite `/pubkey` and
  `/rootfs.sig` today, would move to per-slot key classes and to editing the signature block.
- **Compatibility.** It changes the on-device format, so the verifier would have to handle (or clearly
  refuse) releases in the current single-signature layout, and it needs a fresh bench run on fused
  and unfused boards.

### 6.10 Disabling the maskrom (download) interface

**Status: not implemented or tested — and, per Rockchip's release notes, the DDR blob the build ships
predates support for it.** The BOOT button
enters maskrom on every board, fused or not (bench row C6), and maskrom accepts a USB download
(`upgrade_tool db`) of any loader whose header matches the fused key.

- **The mechanism.** Rockchip added *"Support disabling download function through OTP"* in
  `rv1106_ddr` **v1.16** (`rkbin/doc/release/RV1106_EN.md`) — a separate, irreversible fuse. The
  SeedSigner build ships the SDK's pinned DDR blob, **v1.15** (`fwver: v1.15` in every boot log),
  which predates it according to those notes (not verified on hardware). Using it would mean moving
  to v1.16 (rkbin has `rv1106_ddr_924MHz_v1.16.bin`), validating that blob on every board, and then
  finding out how the fuse is armed and burned — none of which has been tried.
- **What it would buy.** On a fused board maskrom already refuses loaders signed with any other key,
  so disabling it mainly removes a way to flash an *older, correctly signed* release (see
  [§6.2](#62-anti-rollback)) and closes the BootROM's USB stack as an attack surface.
- **What it would cost.** Maskrom is the only recovery path once a fused board's NAND idblock is
  broken ([§3.4](#34-recovery)) — the 2026-09-21 recovery ([§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21))
  relied on it entirely. With download disabled, any bad flash or firmware bug on a fused board is a
  dead board, and it also removes the failover `uboot-recovery-config.sh` configures. That is why
  [§3.6](#36-the-download-disable-fuse) recommends leaving it alone. If it is ever adopted, it should
  come after anti-rollback and a proven signed update path that never needs maskrom.

**Notes on the loader blobs (checked 2026-09-22):**

- **The DDR blob is not factory-provisioned.** Only the BootROM (mask ROM) and the OTP fuses are fixed
  in the SoC. The DDR init blob is the first component of the loader we build: the pinned SDK's
  `rkbin/RKBOOT/RV1106MINIALL.ini` uses `rv1106_ddr_924MHz_v1.15.bin` both as `CODE471` (loaded into
  RAM by maskrom during `db`) and as `FlashData` (the first component of the NAND idblock, which prints
  the `DDR 306b9977f5 … fwver: v1.15` banner at every boot). It sits inside the loader's first signed
  component, so on a fused board an updated blob just means rebuilding the loader and re-signing it
  with the fused key.
- **v1.16 is the newest RV1106 DDR blob** (upstream `rockchip-linux/rkbin` and the `3rdIteration/rkbin`
  fork both at `3e288fe`, 2026-06-26; the blob was dated 2026-05-11 and committed upstream 2026-05-19).
  **Its only change is the download-disable support** — no DRAM or stability fixes. v1.15 (2023-12-21)
  already has the low-temperature stability fix, the large-SPL fix and the suspend/resume timer change.
  So v1.16 is only worth testing for this feature.
- **v1.16 has run on a fused Mini, in RAM only:** the clean rkbin loader used in the 2026-09-21
  recovery (built by `boot_merger RKBOOT/RV1106MINIALL.ini` from rkbin master: DDR v1.16, usbplug v1.09,
  SPL v1.03) was accepted by `db` and initialised the DRAM. It has never been written to NAND or booted
  from it.
- **Prebuilt SPL v1.03 does not apply** (2026-03-02; the SDK pins v1.02; it fixes *"SPL hw
  decompression of uboot failed"*). Confirmed from the SDK's `u-boot/make.sh`: `pack_spl_loader_image`
  runs the SPL packer with `--spl ${SRCTREE}/…`, which puts the **source-built** SPL (carrying our key,
  `burn-key-hash` and the FIT-signature config) into the loader in place of the prebuilt
  `rv1106_spl_v1.0x.bin` named in the ini.
- **Wiring v1.16 into the build is a small change; validating it is the work.** The build scripts
  never touch rkbin: the SDK's `make.sh` `select_ini_file()` takes `rkbin/RKBOOT/RV1106MINIALL.ini`
  (overridable with `CONFIG_LOADER_INI` or `--ini`) and `boot_merger` packs `download.bin` and
  `idblock.img` from it. Two ways to move to v1.16:
  - **in the SDK fork** (`3rdIteration/luckfox-pico`) — add the v1.16 blobs to
    `sysdrv/source/uboot/rkbin/bin/rv11/`, point the ini's `CODE471 Path1` and `FlashData` at
    `rv1106_ddr_924MHz_v1.16.bin`, and bump `opt/luckfox/SDK_COMMIT`. One change, picked up by all
    three build paths. Preferred.
  - **in this repo** — vendor the blob with a SHA-256 pin (as the initramfs binaries are) and patch
    the ini during the SDK patch step, in `build-luckfox.yml`, `os-build.sh` and `build-local.sh`.

  Then validate NAND boot, SD boot and `db` on the Mini, Pro Max and Pico Pi (the DDR blob is what
  brings up each board's DRAM), and a signed build's `check`.
- **How to actually disable download is undocumented.** The only mention anywhere in rkbin is the
  one-line v1.16 release note. There is no doc, tool, script or ini option for it. The blob's strings
  give nothing away: v1.15 and v1.16 carry the same OTP-read strings (`OTP rd FAIL`, `OTP null`,
  `Unk OTP data`), and v1.16 adds only its version banner and an `LPDDR5X` entry. None of the public
  material reviewed covers it: the Secure Boot Application Note V1.9, the RV1106 datasheet and TRM,
  the Rockusb wiki, or community secure-boot write-ups ([§8](#8-links-and-resources)). Options: ask
  Rockchip or Luckfox for the OTP guide section and burn procedure; look for an SDK SPL/U-Boot or
  `rk_sign_tool` option that writes the bit; or reverse-engineer the DDR blob's OTP check. Testing any
  of them is irreversible, and a mistake leaves the board without maskrom recovery.

---

## 7. Findings, open questions and history

Everything learned along the way, kept so the reasoning behind the current design is not lost.
Question numbers (Q1–Q17) are the original ones from when this document was a feasibility report;
other docs and commits refer to them.

### 7.1 Open questions

- **Q4.** Is the OTP public-key-hash region on RV1106 write-locked independently, and does burning it
  affect the OTP regions the `cpuinfo` driver reads?
- **Q6.** Can `uboot.img` / `boot.img` be signed with upstream `mkimage -N pkcs11` against a hardware
  token, and does the resulting FIT still satisfy Rockchip's SPL verification? (The pure-Python
  `fitsign.py` signs a bare digest, so any token that does raw RSA-PSS already works through the
  air-gap boundary.)
- **Q8 (remainder).** The exact file name/location `rk_sign_tool ss --inject` expects — injection was
  not completed with the vendor tool (moot for our tooling, which splices directly).
- **Q8b.** The correct `hsm_engine_id` / `hsm_private_key_id` values for a PKCS#11 token in
  `rk_sign_tool`'s native HSM mode.
- **Q10.** What do `mcr` (secondary cert) and `ss --cert` enable? If they support a root/delegate key
  hierarchy, the root key could stay permanently offline.
- **Q13 (remainder).** Full command-line lockdown: `CONFIG_CMDLINE_FORCE=y` (untested on this 5.10
  kernel; must carry the *complete* line) or stripping `mtdparts`/`blkdevparts` from
  `CONFIG_ENVF_LIST` ([§4.6](#46-the-kernel-command-line-envf-and-autoboot)).
- **Q14.** How should `boot.img` rollback be enforced without OP-TEE? Either patch U-Boot to compare the
  FIT `rollback-index` against a floor compiled into `uboot.img` (SPL protects `uboot.img` from rollback
  via OTP, so that floor can't be rolled back either), or accept that raising the `boot.img` floor means
  re-signing `uboot.img` with a higher SPL index, which spends one of the 64 OTP increments each time.
- **Q15.** Is there a spare region in RV1106 secure OTP that an SPL patch could use for an on-die device
  secret (only relevant if OP-TEE is dropped)? None of the documents reviewed has the RV1106 OTP map;
  the only known allocation is the rollback counter at `0xe0`.
- **New (2026-09-21).** Why does a fused board refuse a `download.bin` whose LDR `releaseTime` is
  1970-01-01? The field is outside every signature; only the effect is known
  ([§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21)). And does `upgrade_tool rsm` report the
  secure-boot state?
- **New.** Should the app record the OTP hash at arm time (e.g. an `otp-key-hash.txt` next to the
  release), so every fused board carries a record of which key it expects
  ([§3.5](#35-which-key-is-a-fused-board-expecting))?

### 7.2 Answered questions

- **Q1 — the `rk_sign_tool` chip identifier.** `1106`. Plain `1103` is rejected by v1.49; the Mini signs
  as `1106` because it builds with the RV1106 U-Boot defconfig ([§4.3](#43-rk_sign_tool-field-notes)).
- **Q2 — does RV1106 use the `sign_flag=0x20` flow? NO (hardware-confirmed, 2026-09).** Flashing a loader
  signed with `ss --flag 0x20` on an RV1103 Mini produced no OTP write (`Verified-boot` stayed `0`, no
  `otp write key success`, board unfused). RV1106 burns the key hash only via the FIT `--burn-key-hash`
  mechanism, confirmed via the in-build `make.sh` FIT flow (`arm_fit_burn_key_hash`). The legacy loader
  `sign_flag` path does nothing on this SoC.
- **Q3 — does enabling `CONFIG_FIT_SIGNATURE` / `CONFIG_SPL_FIT_SIGNATURE` work without further
  patching?** Yes, with three non-obvious requirements the opt-in build handles: (a) in-build signing
  aborts with `ERROR: No keys/dev.key` unless `keys/dev.{key,pubkey,crt}` are present in the U-Boot tree;
  (b) **`boot.img` is NOT signed by the SDK build** — `mk-fitimage.sh` packs it with the `dev` signature
  *template* and no `-k`, and nothing in `project/build.sh` signs it, so an enforcing U-Boot rejects it
  (`Failed to verify required signature 'key-dev'`); `sign_boot_image` signs it with the SDK's own
  `scripts/fit.sh --boot_img`; (c) a signed FIT means the kernel command line must be **baked into the
  signed DTB**, because U-Boot won't rewrite a signed FIT's `/chosen` at runtime. Separately, the
  standalone `rkbin/fit-sign.sh` *re-sign* flow is **not usable on this SDK** — it needs a
  `fit_signcfg/sign.readonly_config` (SPL/uboot checksums + `MINIALL.ini`) that this SDK never generates.
- **Q5 — can a fused board still enter Maskrom, and what does it accept? (2026-09-12, fused Mini).**
  The BOOT button still enters Maskrom on a fused board; an **unsigned** (wrong-key) image is
  **rejected** (won't boot or flash); a correctly signed image flashes and boots. So recovery survives,
  but only with an image signed by the fused key. Refined 2026-09-21: the loader must also have a correct
  header key block and a post-1970 `releaseTime` ([§7.8](#78-bench-first-fuse-to-a-re-signed-key-2026-09-21)).
- **Q7 — does signing run before or after `normalise_boot_images()`, and does that invalidate a
  signature?** `boot.img` is signed after the firmware build but **before** `normalise_boot_images()`,
  which only rewrites `download.bin` and `update.img` (their `releaseTime` and trailers, outside the
  signatures) and never touches the signed FITs.
- **Q8 — what does `ss --extract` emit?** Two bare 32-byte SHA-256 digests (`si_usb_head.bin`,
  `si_flash_head.bin`), signed with **RSA-PSS**. Example values from a real `download.bin`:
  `si_usb_head.bin 6251fac916b0291f06e7aec99f8dd1ee4bc93e5dc613cdf21a819b56c6bbf0a1`,
  `si_flash_head.bin e73153ec45740feffd77587b4396ac33add7f35ad1acfe4f3629b4d1cb58e9f6`. Two digests
  because the loader carries separate USB-boot and flash-boot headers — the second is the flashhead.
- **Q9 / Q17 — RSA-4096?** **2048-only, and it fails in software before the BootROM question arises**
  ([§7.6](#76-bench-rsa-4096-probe-2026-09-12-unfused-board)). The SPL HW-crypto verify hardcodes
  `key_len != RSA2048_BYTES → -EINVAL`. **Do not fuse a 4096 hash.**
- **Q11 — does `ss --version` drive the rollback index?** No — `fit-sign.sh` takes a separate
  `--rollback-index <img> <n>`, writes `rollback-index = <n>` into the ITS, and reads it back with
  `fdtget` to verify. It *errors out* if `CONFIG_SPL_FIT_ROLLBACK_PROTECT=y` and no index is given.
  `--version` is a distinct, non-OTP field.
- **Q12 — are the ENVF partition's contents imported?** Yes, but only the names in `CONFIG_ENVF_LIST`;
  `bootdelay` and `cli` aren't on it. On signed builds `sys_bootargs` is ignored too, leaving
  `mtdparts`/`blkdevparts` ([§4.6](#46-the-kernel-command-line-envf-and-autoboot)).
- **Q13 — is the kernel command line trusted on signed builds?** Partly: `root=` (plus `ubi.mtd`,
  `rootfstype`, `rk_dma_heap_cma`) is baked into the signed DTB `/chosen` by
  `apply_signed_nand_bootargs`, found the hard way when the first fused build hung at
  `Waiting for root device /dev/mmcblk1p7` with 32M CMA (bench row C7). Remainder in §7.1.
- **Q16 — the loader/idblock signature format (2026-09-17), which made `rk_sign_tool` unnecessary.**
  Recovered directly from shipped artifacts: scan a signed image for a 256-byte window that RSA-verifies
  (under the committed dev pubkey) to a *structurally valid* PSS block — trailer `0xbc`, and after MGF1
  unmasking a DB of the form `0x00...0x01 || salt`. Exactly one window matches per file, which yields the
  salt, and solving `H = sha256(0x00^8 || mHash || salt)` for `mHash` gives the hashed region
  ([§4.4](#44-loader-and-idblock-format)). Verified on all four locally built profiles (mini/max NAND,
  mini production, pi eMMC) and implemented in `rkloader.py` (pure stdlib), tested by
  `tests/test_rkloader.py`. **The other header fields are now characterised too (2026-09-21):** the key
  block N‖E‖C, of which C (the PKA Barrett constant) must be rewritten on a re-key, and the component
  hashes; plus `download.bin`'s flashhead (RC4, key recovered from `rk_sign_tool`) and LDR trailer
  ([airgapped-signing.md](airgapped-signing.md)).

### 7.3 Corrections log

Things this document once stated that turned out to be wrong — kept because the wrong turns are
instructive.

| Once believed | Actually | Found |
|---|---|---|
| `rk_sign_tool` cannot keep the key in hardware | It has native HSM/PKCS#11 settings in `setting.ini` ([§4.3](#43-rk_sign_tool-field-notes)) | reading `setting.ini` |
| The smartcard is the best home for the anti-phishing secret | It authenticates the *card*, not the device (§6.1) | design review |
| The Non-Protected OTP zone is reachable from Linux today | It is reached through OP-TEE; Linux cannot write any RV1106 OTP (§6.1) | OTP guide §3.1 |
| Sign a dm-verity root hash for lazy rootfs checks | dm-verity cannot work on UBI (§5.1) | 2026-09-13 |
| `CONFIG_CRYPTO_DEV_ROCKCHIP=y` gives hardware crypto | The driver isn't built (§4.9) | bench |
| The nvmem OTP blob shows the secure-boot fuse | It is a non-secure view; byte 0x80 is the chip id on every board (§4.5) | bench row E4 |
| RV1106 arms the burn with `sign_flag=0x20` | Only the FIT `burn-key-hash` path burns (Q2) | 2026-09 bench |
| `sys_bootargs` is still merged after the baked `/chosen` on signed builds | `envf.c` ignores it when `CONFIG_FIT_SIGNATURE=y` (§4.6) | 2026-09-14 source read |
| `rkloader.py setkey` rewrites fields "not fully characterised"; test unfused | An unfused board cannot catch a bad key block at all; the stale C bricked a fused board (§7.8) | 2026-09-21 |
| `otp --loader --hash` output cannot be compared after the burn | Still true for reading OTP, but the burned value equals the burning idblock's `hash@np`, so it can be recovered from NAND (§3.5) | 2026-09-22 |
| `fit-sign.sh --burn-key-hash` is how to arm on RV1106 | Its re-sign flow is unusable on this SDK; arm in-build, with `setburn`, or from the app (§3.2) | Q3 |
| The chain stops at `boot.img`; the rootfs is unsigned | Implemented on signed builds (§5.2) | 2026-09-14 |

### 7.4 Bench: unsigned baseline (stock image)

Run over ADB (Linux) and UART @ 115200 (U-Boot) on the stock `Luckfox_Pico_Mini_Flash_250607` image.

| # | Test | Result | Bearing |
|---|---|---|---|
| A1 | Read `/sys/bus/nvmem/.../rockchip-otp0/nvmem` | 128 B, readable | OTP present |
| A1 | Write same node (`dd`) | **Permission denied** | Read-only from Linux, confirming §4.5 / §6.1 |
| A2 | `otp_id@0x0a` vs `/proc/cpuinfo` Serial | `M4T961...` vs `d6d9fb7e70873741` — **differ** | Serial is *derived*, not the raw cell (§6.1 corrected) |
| A3 | `hw_random/rng_current` | `rockchip` | Hardware TRNG bound |
| A3 | `[hwrng]` kthread | **running (pid 41)** | Kernel credits TRNG entropy — confirms `docs/hwrng.md` for Luckfox |
| A3 | `rngd` | **not running** | Stock image only; the SeedSigner build adds `rng-tools` |
| A4 | `mtd0` = "env" (256K), contains `sys_bootargs= ... root=ubi0:rootfs ...` | that string appears verbatim in `/proc/cmdline` | §4.6 confirmed: the unsigned env partition sets the kernel command line (unsigned builds) |
| B1 | Flood CTRL+C on UART during power-on (`bootdelay=0`) | **dropped to `=>` prompt** | §4.6 confirmed: `bootdelay=0` is interruptible; needs `-2` |
| B2 | `printenv` | `bootdelay=0`, `bootcmd=boot_fit;boot_android ...`, `sys_bootargs=...`; **no `cli`** | env carries `sys_bootargs`; `cli` absent (ENVF whitelist holds) |
| — | SPL/U-Boot log | `Verified-boot: 0`, `FIT: no signed, no conf required`, `sha256+ OK` | Baseline: the `sha256+ OK` lines are **hash integrity checks, not signature checks** — they pass on any self-consistent image, an attacker's included |

The before-state an unsigned, unfused Mini prints:

```
U-Boot SPL 2017.09 ...
## Verified-boot: 0                                   <- SPL: no signature verification
## Checking uboot 0x00200000 (lzma @0x00400000) ... sha256(b3bbbb7c43...) + sha256(caa241d3e1...) + OK
...
Model: Rockchip RV1106 EVB Board                      <- the RV1103 Mini *is* an RV1106 to U-Boot
FIT: no signed, no conf required                      <- U-Boot: FIT signature not required
## Verified-boot: 0
   Verifying Hash Integrity ... sha256+ OK            <- integrity only, not authenticity
```

**Note on the boot medium:** this is a NAND Mini (`root=ubi0:rootfs`, `ubi.mtd=6`), not the SD layout
shown in §1.5. The `mtd0`→cmdline path is identical in mechanism.

### 7.5 Bench: signed + fused run (2026-09-12, committed public dev key)

The full signed/fused chain was exercised on a sacrificial Mini, built with
`SEEDSIGNER_FIT_SIGNATURE=1` (+ `SEEDSIGNER_FIT_BURN_KEY_HASH=1` for the burn). All confirmed on UART:

| # | Test | Result | Bearing |
|---|---|---|---|
| C1 | Signed build, unfused, first boot | SPL: `sha256,rsa2048:dev … OK`; U-Boot: `FIT: signed, conf required`, `sha256,rsa2048:dev+ OK` | Whole chain (loader→`uboot.img`→`boot.img`) verifies; enforcement is live in software even before the fuse |
| C2 | `boot.img` **without** the extra sign step | `conf: sha256,rsa2048:dev- error! Failed to verify required signature 'key-dev'` → maskrom | The SDK does **not** sign `boot.img`; it must be signed in-build (Q3). Fixed by `sign_boot_image` |
| C3 | Burn (armed loader, first boot) | `## spl…dtb: burn-key-hash=1` at build; `RSA: Write RSA key hash successfully.` at SPL | The OTP fuse is written via the FIT `--burn-key-hash` path — RV1106 secure boot confirmed |
| C4 | Fused board, unsigned/old image | **rejected** — won't boot or flash | Enforcement confirmed: BootROM checks the loader against the burned hash |
| C5 | Fused board, dev-key-signed image | flashes and boots | The fused key accepts correctly signed images |
| C6 | Fused board, BOOT button | enters **Maskrom** | Recovery path survives the fuse (Q5) |
| C7 | First signed NAND build to userspace | hung at `Waiting for root device /dev/mmcblk1p7`, 32M CMA | Signed FIT uses the DTB's baked `/chosen` (SD default); NAND rootfs args must be baked in (Q13). Fixed by `apply_signed_nand_bootargs` |
| C8 | SPI display on the fused board | first black (`Opening SPI device: No such file or directory`), then working after fix | Same root cause as C7 generalized (below): a signed FIT stops `luckfox-config`'s runtime DT overlay from enabling `&spi0`. Fixed by enabling SPI statically (`apply_spi_display_dts`). Screen + camera confirmed working. |
| C9 | Reflash the fused board | works in SocToolKit **partition (Download) mode** with the signed `download.bin`, and via **Firmware → `update.img` → Upgrade** | Recovery is straightforward as long as the loader in the list is the signed one |

> **Generalizable finding — a signed FIT disables *all* runtime DTB modification.** U-Boot will not
> rewrite a signed, conf-required FIT's device tree at boot (that would break verification). Two things
> that silently relied on that rewrite therefore broke on the first fused build and had to be **baked into
> the signed DTB at build time** instead: the NAND kernel command line (C7, `apply_signed_nand_bootargs`)
> and the SPI display, which `luckfox-config` normally enables via a runtime configfs overlay (C8,
> `apply_spi_display_dts`; the overlay `dtc`-core-dumps because the DTB has no `__symbols__` to resolve
> `&spi0`). Anticipate this for anything else that depends on a boot-time DTB fixup or overlay — on a
> signed build it must be static.

The staged rehearsal this run followed originally used Rockchip's V1.9 stage names: A (enable
verification, sign, verify offline with `rk_sign_tool vi`), B (the negative test), C (sign the loader
unarmed), D (burn), E (confirm enforcement). They are now §3.1–3.3 and the bench procedure.

### 7.6 Bench: RSA-4096 probe (2026-09-12, unfused board)

To answer Q9/Q17, a `SEEDSIGNER_FIT_BITS=4096` build (a secondary committed public 4096 dev key; the knob
was added for this probe and **reverted after the result**) was flashed to an *unfused* Mini — the
reversible test, since an unfused BootROM never checks the loader:

| # | Test | Result | Bearing |
|---|---|---|---|
| D1 | 4096-signed build, unfused board, first boot | SPL prints `sha256,rsa4096:dev` — **no `OK`** (the 2048 path prints `sha256,rsa2048:dev OK`) — then a reset loop ending in `spl_early_init() failed: -22` | The SPL *software* verify of an rsa4096 image fails on this SoC **before any fuse**. A 4096 fuse is a NO-GO: if the more capable SPL cannot verify it, the mask ROM almost certainly cannot either — and fusing would be the only (irreversible) way to find out |

**Root cause, from the pinned SDK source** (`3rdIteration/luckfox-pico` @ `0b5c1f30`, U-Boot
2017.09-based): RSA-2048 is the *only* key size this boot chain supports — in software, before we ever
reach the untestable BootROM link:

1. `common/image-sig.c`'s `crypto_algos[]` has exactly two RSA entries (`rsa2048`, `rsa4096`) and
   `include/u-boot/rsa.h` defines only `RSA2048_BYTES` / `RSA4096_BYTES` — there is **no 3072** anywhere,
   so `mkimage` would reject `sha256,rsa3072` at sign time.
2. `lib/rsa/rsa-verify.c`'s `rsa_mod_exp_hw()` is a hardcoded 2048-or-4096 `#ifdef`, not a size
   parameter: any other modulus length returns `-EINVAL`.
3. **Decisive:** the SPL secure-boot path (`CONFIG_SPL_BUILD && CONFIG_SPL_FIT_HW_CRYPTO`) contains,
   *outside* the 4096 ifdef:

   ```c
   if (info->crypto->key_len != RSA2048_BYTES)
       return -EINVAL;
   ```

   The SPL hardware-crypto verify is **hardcoded to RSA-2048 only** — that `-EINVAL` is the `-22` in D1.
   A 4096-signed `uboot.img` can therefore never pass SPL on this SDK, regardless of config.

**Conclusion:** stay on RSA-2048. Getting >2048 to work would mean patching U-Boot C *and* the Rockchip
HW-crypto driver — against a PKA silicon and mask ROM that may not physically support it; not worth it
for a device whose real trust anchor is the seed. `CONFIG_RSA_N_SIZE=0x200` only sizes the key-block
field. RSA-2048 + SHA-256 is the supported key size on this platform, full stop.

### 7.7 Bench: rootfs verifier (2026-09-14)

The initramfs verifier was exercised on both a fused and an unfused Mini (dev variant, app ref
`eabace45`, `SEEDSIGNER_FIT_SIGNATURE=1`). All confirmed on UART + LCD:

| # | Test | Result | Bearing |
|---|---|---|---|
| E1 | Fused board, signed build with verifier initramfs | SPL/U-Boot `Verified-boot: 1`; `/init`: orange *Verifying rootfs Signature* → green *PASSED / rootfs signature valid*; app boots | The chain extends past `boot.img` to the rootfs volume on a fused device, hardware-validated |
| E2 | Unfused board, **same** image | `Verified-boot: 0`; `/init`: orange *SECURE BOOT not enabled* (held ~5 s) → boots without verifying | One signed image serves both board states; the panel tells the user this board has no rootfs-integrity protection |
| E3 | Dev build, rootfs volume modified after flashing | red *FAILED / rootfs signature mismatch / press KEY_DOWN*; verification fails closed on the tampered volume | The verifier catches offline NAND tampering (the attack it exists for) |
| E4 | First fuse-detection implementation (nvmem byte read), fused board | `/init` logged *secure boot NOT fused* and **skipped** verification on a fused board | Caught by E1's absence of the PASSED screen. Root cause: the kernel `rockchip-otp` nvmem driver exposes a non-secure OTP view that does not contain the secure-boot enable flag (SPL reads it via the separate `rv1106_spl_rockchip_otp_start/stop` path); byte 0x80 of the blob is the chip ID `"RV\x11\x03"` on both boards. Fixed by trusting U-Boot's `fuse.programmed` cmdline flag instead (§5.2 **Fuse detection**) |

The rootfs link works end-to-end (E1), degrades gracefully on unfused hardware (E2), and fails closed
against tampering (E3). The nvmem approach is retired; no kernel patch for OTP readability ships with
signed builds.

### 7.8 Bench: first fuse to a re-signed key (2026-09-21)

A CI production bundle was re-signed on-device to a BIP85-derived key (Resign Release), armed (Arm
eFuse Burn), and flashed to a Mini through SocToolkit's Download mode. The SPL printed
`RSA: Write RSA key hash successfully.` and the board booted to the kernel. From the next power-on it
went **straight to maskrom with only `RKUART` on UART**. After that, every `download.bin` was refused
at Download Boot: the re-signed one, a vendor-signed one for the same key, the dev-key CI build and the
original pre-re-sign build.

| # | Finding | Evidence | Fix |
|---|---|---|---|
| F1 | The re-keyed loader header kept the **old key's PKA constant C** (`hdr+0x410`). BootROM hashes `hdr[0x200:0x430]` (N‖E‖C) against OTP, so the NAND idblock no longer matched the hash the SPL had just burned from its (correct) DTB | `rk_sign_tool otp --loader --hash`: the flashed loader needed a different OTP value from the one the SPL burned; a loader with C corrected needed exactly the burned value | `rkloader.write_key_block()` / `set_pubkey()`; `fused_boot_problems()` in `verify`, `check_release`, and the app's arm gate |
| F2 | Every CI `download.bin` was dated **1970-01-01** (reproducibility pin). A fused board refused it at `db` even when correctly signed for the fused key | Changing only `releaseTime` (+ CRC) turned "Download boot failed!" into "Download boot ok."; 2025-01-01 00:00:00 also passes. A clean rkbin loader built by `boot_merger` and signed by `rk_sign_tool` passed first time | `ss-fs-normalise.sh` floors the date at 2025-01-01; `rkloader.prepare_for_signing()` does the same on re-sign |
| F3 | `set_pubkey()` never re-keyed the **flashhead's SPL DTB** (the idblock copy inside `download.bin` that `upgrade_tool ul` / `update.img` upgrades write). This did not affect this recovery, which wrote `idblock.img` | the recovered loader's flashhead still held the dev modulus and `hash@np` | `set_pubkey()` re-keys the flashhead's DTB and rehashes its components |
| F4 | After a failed `db`, a known-good loader also failed until the board was power-cycled | a clean vendor loader failed right after a rejected one, then passed from a clean power-on | [soctoolkit-cli.md](soctoolkit-cli.md#troubleshooting) |

**Recovered** without any hardware tool: `db` with the corrected loader, then `wl` of the corrected
(un-armed) `idblock.img` plus the existing re-signed images, then `rd`. The next boot showed
`## Verified-boot: 1` through to the kernel, so the fuse holds the intended key and enforces it.

**Follow-up (2026-09-22).** A fresh air-gapped re-sign of the fixed CI build failed the same way,
because `airgap-sign.py rekey` ran from an older checkout without the fix; it also showed the air-gap
`splice` never signed `download.bin`'s flashhead. Both are now handled: `splice` signs the flashhead
with `idblock.sig`, `verify`/`check` fail an unsigned flashhead, and §2 warns about the checkout.

**Lessons.** Nothing tested before the fuse could see F1 or F2: signature verification passes, and an
unfused BootROM checks neither. Both are now checked in software, and arming refuses an image that
fails. Keep rehearsing on a sacrificial board. When a fused board sits in maskrom, work from SocToolkit's
own log, `rk_sign_tool otp`, and a clean rkbin loader before concluding it is dead.

### 7.9 Provenance

This work started as a feasibility study because **no public Rockchip secure boot document covers
RV1103/RV1106**. Three were reviewed:

| Document | Version / date | Platforms it claims to cover |
|---|---|---|
| Rockchip Secure Boot Application Note | V1.9, 2018-06 | RK3126, RK3128, RK3228, RK3229, RK3288, RK3368, RK3399, RK3228H, RK3328, RK3326, RK3308, PX30 |
| Rockchip Secure Boot for U-Boot Next Dev | V2.3.0, 2021-04 | RK3568, RK3566, RK3399, RK3368, RK3328, RK3326, RK3308, RK3288, RK3229, RK3126, RK3128 |
| `rkbin/doc/release/RV1106_EN.md` | current | RV1106 — but contains **no** secure boot or signing section |

RV1106 launched after both guides; their flows were treated as *the mechanism*, not as an RV1106
procedure, then confirmed or corrected on hardware (§7.4–7.8). Facts in this document were **verified
directly** against the pinned SDK (`opt/luckfox/SDK_COMMIT` =
`0b5c1f30ca6333b7ec5af70d26511da9ef8d39af`), shipped build artifacts, `rk_sign_tool` v1.49's own help
output, and sacrificial hardware.

The documents and sources used are listed in [§8](#8-links-and-resources).

---

## 8. Links and resources

**In this repository**

| What | Where |
|---|---|
| Signature formats and the pure-Python signers (reference) | [airgapped-signing.md](airgapped-signing.md) |
| Staged bench procedure for signing, flashing and burning the fuse | [secure-boot-bench-procedure.md](secure-boot-bench-procedure.md) |
| Checking a distributed release (authenticity, reproducibility) | [verifying-a-release.md](verifying-a-release.md) |
| Flashing and recovering boards with SocToolkit's `upgrade_tool` | [soctoolkit-cli.md](soctoolkit-cli.md) |
| Luckfox build process, read-only rootfs, boot recovery, MicroSD | [README.md](README.md) |
| How hardware entropy reaches the app | [`docs/hwrng.md`](../hwrng.md) |
| Loader/idblock signer (`rkloader.py`), FIT signer (`fitsign.py`), rootfs signer (`minisign.py`), release check (`luckfox_release.py`) | [`opt/luckfox/secure-boot/`](../../opt/luckfox/secure-boot/) and its [README](../../opt/luckfox/secure-boot/README.md) |
| PC half of air-gapped signing | [`tools/airgap-sign.py`](../../tools/airgap-sign.py) |
| Build-time signing, rootfs verifier, `releaseTime` pin | [`opt/luckfox/os-build.sh`](../../opt/luckfox/os-build.sh), [`build-local.sh`](../../opt/luckfox/build-local.sh), [`deterministic-sign.sh`](../../opt/luckfox/deterministic-sign.sh), [`ss-fs-normalise.sh`](../../opt/luckfox/ss-fs-normalise.sh) |
| Committed public dev keys (no protection) | [`secure-boot/dev-keys/`](../../opt/luckfox/secure-boot/dev-keys/README.md), [`secure-boot/dev-keys-rootfs/`](../../opt/luckfox/secure-boot/dev-keys-rootfs/README.md) |
| Tests | [`tests/test_rkloader.py`](../../tests/test_rkloader.py), [`test_fitsign.py`](../../tests/test_fitsign.py), [`test_minisign.py`](../../tests/test_minisign.py), [`test_luckfox_release.py`](../../tests/test_luckfox_release.py), [`test_airgap_sign.py`](../../tests/test_airgap_sign.py) |
| Device-side tools (Resign Release, Sign Digest, Air-Gap Re-Key, Arm eFuse Burn) | the SeedSigner app, `src/seedsigner/helpers/resign_release.py` and `src/seedsigner/views/resign_views.py` in [3rdIteration/seedsigner](https://github.com/3rdIteration/seedsigner) |

**SDK and vendor binaries**

- [`3rdIteration/luckfox-pico`](https://github.com/3rdIteration/luckfox-pico) — the Luckfox SDK fork
  this build pins (`opt/luckfox/SDK_COMMIT`); upstream is
  [`LuckfoxTECH/luckfox-pico`](https://github.com/LuckfoxTECH/luckfox-pico). U-Boot, SPL and the
  pinned rkbin live under `sysdrv/source/uboot/`.
- [`rockchip-linux/rkbin`](https://github.com/rockchip-linux/rkbin) (fork:
  [`3rdIteration/rkbin`](https://github.com/3rdIteration/rkbin)) — `tools/rk_sign_tool`,
  `tools/boot_merger`, `tools/fit-sign.sh`, `tools/upgrade_tool`, `RKBOOT/RV1106MINIALL.ini`,
  `bin/rv11/` (DDR, SPL, usbplug, TEE blobs), and the release notes in
  [`doc/release/RV1106_EN.md`](https://github.com/rockchip-linux/rkbin/blob/master/doc/release/RV1106_EN.md).
- [Luckfox wiki](https://wiki.luckfox.com/) — board documentation and SocToolkit downloads.

**Rockchip documentation**

- [Rockchip Secure Boot Application Note V1.9](http://resource.milesight-iot.com/files/Rockchip-Secure-Boot-Application-Note-V1.9.pdf)
  (2018-06) — the BootROM → loader → U-Boot model, key handling, OTP burn flow; predates RV1106.
- Rockchip Secure Boot for U-Boot Next Dev V2.3.0 (2021-04) — FIT signing, `fit-sign.sh`,
  rollback indexes; predates RV1106. Distributed with Rockchip SDKs.
- Rockchip OTP Developer Guide V1.4.0 — §3 Secure OTP zones. Distributed with Rockchip SDKs.
- Rockchip TEE SDK Developer Guide V1.10.0 — §3.3 TEE firmware, §10.2 memory, §13 OTP. Distributed
  with Rockchip SDKs.
- Rockchip Crypto/HWRNG Developer Guide V1.2.1 — §2.2 HWRNG, §2.3 hardware crypto.
- [Rockchip RV1106 datasheet](https://rockchip.fr/RV1106%20datasheet%20V1.9.pdf) and
  [TRM V0.3 Part 1](https://rockchip.fr/Rockchip%20RV1106%20TRM%20V0.3%20Part1.pdf).
- [Rockusb (maskrom) — Rockchip open source wiki](https://opensource.rock-chips.com/wiki_Rockusb).

**Standards and upstream projects**

- [U-Boot FIT signature verification](https://docs.u-boot.org/en/latest/usage/fit/signature.html) —
  the mechanism `uboot.img` / `boot.img` signing is built on.
- [RFC 8017](https://www.rfc-editor.org/rfc/rfc8017) — RSA-PSS (EMSA-PSS), used by every RSA tier.
- [minisign](https://jedisct1.github.io/minisign/) — the rootfs signature format (Ed25519,
  pre-hashed BLAKE2b-512).
- [BIP85](https://github.com/bitcoin/bips/blob/master/bip-0085.mediawiki) — deterministic entropy
  from a BIP39 seed, used to derive the signing keys.

**Community write-ups on Rockchip secure boot** (other SoCs, useful background)

- [Enabling Secure Boot on RockChip SoCs](https://blog.3mdeb.com/2021/2021-12-03-rockchip-secure-boot/) — 3mdeb.
- [Secure Boot on Rock 5B](https://forum.radxa.com/t/secure-boot-on-rock-5b/14498) — Radxa forum,
  including whether maskrom survives the fuse.
- [`DualTachyon/rk3588-secure-boot`](https://github.com/DualTachyon/rk3588-secure-boot) — enabling
  secure boot on the RK3588 family.
- [Overview of Secure Boot state in the ARM-based SoCs](https://archive.fosdem.org/2023/schedule/event/arm_secure_boot_2/)
  — FOSDEM 2023.
