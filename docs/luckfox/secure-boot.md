# Luckfox Pico — secure boot feasibility report

**Status: confirmed working end-to-end on a sacrificial RV1103 Pico Mini (2026-09-12), with the
committed *public* dev key.** A normal build is still completely unaffected and burns nothing. The
signing, enforcement and OTP-burn path is **opt-in**, gated behind `SEEDSIGNER_FIT_SIGNATURE=1`
(sign the whole chain) and, only for the irreversible fuse, `SEEDSIGNER_FIT_BURN_KEY_HASH=1` — both
off by default. See [§13](#13-bench-test-results-rv1103-pico-mini) for what was confirmed on silicon
and [`secure-boot-bench-procedure.md`](secure-boot-bench-procedure.md) for the runnable steps.

This document records what the hardware and vendor SDK support, what the opt-in tooling now does,
what was confirmed on hardware, and what remains unknown — so the next attempt (especially a **real
secret key** and a **signed rootfs**, neither of which is done) starts from evidence.

Read [§7 Consequences](#7-consequences-decide-these-before-touching-a-fuse) before acting on any of
it. Enabling secure boot burns one-time fuses. It cannot be undone, and a mistake bricks the board —
though a board fused to the *public* dev key stays recoverable, because anyone can sign for it.

---

## 1. Summary

| Question | Answer |
|---|---|
| Does RV1103/RV1106 support secure boot? | **Yes — confirmed on silicon.** BootROM verifies the loader against a public-key hash in OTP; the burn and enforcement were observed on a fused Mini (§13). |
| Is the plumbing already present? | Yes. The SDK's U-Boot compiles in secure-OTP access and RSA; `uboot.img` and `boot.img` are signature-shaped FITs. The opt-in build now enables verification and signs the whole chain. |
| What was missing, and is it now done? | Verification is enabled by `SEEDSIGNER_FIT_SIGNATURE=1`; the whole chain (loader→`uboot.img`→`boot.img`) is signed at build time; the fuse is armed by `SEEDSIGNER_FIT_BURN_KEY_HASH=1`. **Still a placeholder:** the key is the committed *public* dev key — a real secret key is the production step. |
| Is the signing tool available? | Yes — `rk_sign_tool` is vendored. Note: on this SDK the whole chain is signed by the in-build `make.sh`/`fit.sh` FIT flow; the standalone `rkbin/fit-sign.sh` **re-sign** flow is *not usable here* (§13). |
| Is there RV1106 documentation? | **No.** No public Rockchip secure boot document covers RV1103/RV1106. This report was extrapolated, then **confirmed on hardware**. |
| Does it cover the rootfs? | **No — still unsigned.** The chain stops at `boot.img`; the rootfs partition is unverified. Extending it is unimplemented design work — see [§6](#6-extending-the-chain-to-the-rootfs). |
| Does it work on SD-boot boards with no NAND? | Yes, identically — the fuse is in the SoC, not the storage. But the unverified rootfs matters far more there; see [§4.1](#41-boot-media-sd-card-boot-works-the-same-way). |
| Can it be tested without burning a fuse? | **Yes — confirmed.** A signed build boots unfused (`Verified-boot: 0`) with the software checks live, so keys, signing and boot are all rehearsed before the fuse — see [§5.4](#54-staged-rollout--rehearse-everything-before-the-fuse). |
| Can the private key stay offline / in hardware? | The tool has native HSM/PKCS#11 config and a partly-cracked extract/inject path (still open, §10 Q16). **Not yet exercised** — the confirmed run used a key file. |
| Does it stop someone swapping in a look-alike device? | **No.** Secure boot verifies software, not hardware. Anti-phishing words close that gap; see [§8](#8-device-pin-and-anti-phishing-words). |
| Is the kernel command line trusted? | **Now partly.** On a *signed* build `root=` is baked into the signed DTB (u-boot can't rewrite a signed FIT's bootargs at runtime), closing the accidental/default case. But `sys_bootargs` from the unsigned env partition is still merged *after* it, so full lockdown still needs `CONFIG_CMDLINE_FORCE=y` or stripping `sys_bootargs` from `CONFIG_ENVF_LIST` — see [§6.6](#66-the-kernel-command-line-is-attacker-controlled). |

---

## 2. Scope, provenance, and what is *not* verified

Three Rockchip documents were reviewed. **None covers RV1103/RV1106:**

| Document | Version / date | Platforms it claims to cover |
|---|---|---|
| Rockchip Secure Boot Application Note | V1.9, 2018-06 | RK3126, RK3128, RK3228, RK3229, RK3288, RK3368, RK3399, RK3228H, RK3328, RK3326, RK3308, PX30 |
| Rockchip Secure Boot for U-Boot Next Dev | V2.3.0, 2021-04 | RK3568, RK3566, RK3399, RK3368, RK3328, RK3326, RK3308, RK3288, RK3229, RK3126, RK3128 |
| `rkbin/doc/release/RV1106_EN.md` | current | RV1106 — but contains **no** secure boot or signing section |

RV1106 launched after both guides. Treat their flows as *the mechanism*, not as an RV1106 procedure.

**Verified directly** against the pinned SDK (`opt/luckfox/SDK_COMMIT` =
`0b5c1f30ca6333b7ec5af70d26511da9ef8d39af`) and shipped build artifacts — everything in
[§3](#3-what-is-already-in-place) and [§6](#6-extending-the-chain-to-the-rootfs).

**Confirmed on the tool itself** (`rk_sign_tool` v1.49): RV1106 is a supported chip
(`cc --chip 1106` → "setting chip ok"), and the verb set in [§5.3](#53-signing) is taken from
its own help output rather than from the guides.

**Confirmed on sacrificial hardware (2026-09-12)** — the OTP burn flow in
[§5.4](#54-staged-rollout--rehearse-everything-before-the-fuse) is no longer extrapolated: on a
fused RV1103 Mini the SPL wrote the key hash (`RSA: Write RSA key hash successfully`), a wrong-key
(unsigned) image was then rejected, the correctly signed image booted, and Maskrom recovery still
worked. What was extrapolated is now observed. See [§13](#13-bench-test-results-rv1103-pico-mini).
The remaining unknowns are a **real** (non-public) key and RSA-4096 in silicon.

---

## 3. What is already in place

### 3.1 U-Boot is built with the required pieces

`sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig` already contains:

```
CONFIG_SPL_ROCKCHIP_SECURE_OTP=y     # SPL can reach secure OTP
CONFIG_ROCKCHIP_OTP=y
CONFIG_RSA=y                         # RSA verify in U-Boot
CONFIG_SPL_RSA=y                     # ...and in SPL
CONFIG_RSA_N_SIZE=0x200              # modulus up to 4096-bit
CONFIG_RSA_E_SIZE=0x10
CONFIG_FIT_HW_CRYPTO=y               # FIT hashing via the crypto block
CONFIG_SPL_FIT_HW_CRYPTO=y
CONFIG_SPL_FIT_GENERATOR="arch/arm/mach-rockchip/make_fit_optee.sh"
```

**`CONFIG_FIT_SIGNATURE` and `CONFIG_SPL_FIT_SIGNATURE` are absent.** That is the most important
gap: the verification code is compiled in, but nothing requires a valid signature.

### 3.2 The shipped images are already signature-shaped

Parsed from a real build (`opt/luckfox/out-all-*/seedsigner-luckfox-pico-mini-nand-files-*/`):

`uboot.img`

```
/                              description   = FIT Image with ATF/OP-TEE/U-Boot/MCU
/images/uboot                  compression   = lzma
/images/uboot/digest           algo          = sha256
/images/fdt                    type          = flat_dt
/configurations/conf/signature algo          = sha256,rsa2048
/configurations/conf/signature sign-images   = loadables fdt
/configurations/conf/signature key-name-hint = dev          <-- Rockchip placeholder key
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

Both carry a `signature` node bound to the **development key**. The structure is real; the trust is
not. Note `boot.img` has **no ramdisk slot today** — relevant to
[§6](#6-extending-the-chain-to-the-rootfs).

### 3.3 The signing tool is vendored

`sysdrv/source/uboot/rkbin/tools/rk_sign_tool` ships inside the SDK the build already clones.
Upstream `rockchip-linux/rkbin/tools/` additionally carries `fit-sign.sh`, `fit_check_sign` and
`boot_merger`. No closed Windows-only tool is required for the Linux flow.

### 3.4 OTP is live and already read

The shipped DTB has `otp@ff3d0000` (`rockchip,rv1106-otp`) enabled and the kernel sets
`CONFIG_ROCKCHIP_OTP=y`. It is currently used only for chip identity — `cpu_code`, `otp_id`,
`cpu_leakage` — surfaced as the `Serial` line in `/proc/cpuinfo`. The Linux driver for this OTP is **read-only on RV1106**: `rv1106_data` in `drivers/nvmem/rockchip-otp.c` sets `.size = 0x80` and has no `.reg_write`, so nothing can be written to it from Linux, and those 128 bytes already hold factory cells (see [§8.4](#84-where-the-device-secret-lives)).

---

## 4. The boot chain

From Application Note V1.9 §1.3–1.4:

1. **BootROM → loader.** Reads the public key from the loader partition, SHA256s it, compares
   against the hash in OTP. Mismatch → boot fails. Then verifies an RSA-2048 signature over the
   loader binary. On success it **passes the public key up to U-Boot**.
2. **U-Boot → boot.img.** The same two steps against `boot.img` (kernel + DTB + resource).
3. **Stop.** Nothing verifies the rootfs.

```
BootROM ──verify──> loader/idblock ──verify──> uboot.img ──verify──> boot.img ──?──> rootfs
    ▲                                                                                  ▲
hash in OTP                                                                     NOT COVERED
```

RV1106 boots via SPL (`rkbin/bin/rv11/rv1106_spl_*.bin`), so the SPL variant of step 1 applies. The
Next Dev guide defers SPL specifics to the U-Boot Nextdev FIT chapter.

**The AVB half of the Next Dev guide does not apply here.** `vbmeta.img`,
`fastboot oem fuse at-perm-attr` and dm-verity-via-`fs_mgr` are Android mechanisms; this is a
Buildroot system with no fastboot and no `fs_mgr`.

### 4.1 Boot media: SD-card boot works the same way

Some Luckfox Pico revisions have no SPI NAND and boot from microSD. **Secure boot applies to them
identically**, because the fuse lives in the SoC, not in the storage: the BootROM verifies whatever
loader it loads, from whichever medium it loads it.

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
  the entire firmware — no soldering, no NAND programmer. This is the weakest link in the current
  SD-boot story, and the BootROM check is precisely what closes it.
- **But the rootfs gap ([§6](#6-extending-the-chain-to-the-rootfs)) is far more serious on SD.** The
  chain stops at `boot.img`, and on SD the unverified 6G rootfs sits on that same removable card.
  On NAND, modifying the rootfs needs hardware; on SD it needs a card reader. **On SD-only devices,
  rootfs verification is not optional polish — it is most of the actual protection.**

For testing, SD is the *better* medium: Stages A–C in [§5.4](#54-staged-rollout--rehearse-everything-before-the-fuse)
can be re-run by rewriting the card, with no rockusb/maskrom dance. Note that this convenience stops
at the fuse — after Stage D an unsigned card will not boot, so a rewritable card does not rescue a
botched key setup.

> **`sd_update.txt` is unsigned code execution, and secure boot does not cover it.** On every boot
> U-Boot looks for a card and runs its `sd_update.txt`; the boot log shows
> `## retrieving sd_update.txt ...` before the kernel loads. That file is a **U-Boot command
> script** (`mw.b`, `fatload`, `mtd erase`, `mtd write`, ... see
> [`opt/luckfox/patch-sd-update-scripts.sh`](../../opt/luckfox/patch-sd-update-scripts.sh)), and
> nothing signs or verifies it. On a fused board it cannot make unsigned firmware *boot*, but anyone
> who can insert a card gets arbitrary U-Boot commands before the kernel: erase or overwrite any NAND
> partition, brick the device, or write to memory. A secure-boot build must disable the `sd_update`
> auto-run or require a signed script. It is an intentional convenience today and becomes an attack
> surface the moment the rest of the chain is locked.
>
> Secondary effect: with secure boot enabled, images written through this path must be signed, or
> the flash reports success and the device then refuses to boot.

### 4.2 Signed images on microSD: the model that replaces `sd_update.txt`

Once verification is enabled, booting from (or updating from) signed images on a microSD card, and
refusing anything unsigned, is mostly native behaviour. Every stage above the BootROM checks the FIT
signature against the pinned key **regardless of which medium the image came from**. SPL also
already prefers the card; the Mini's boot log shows it trying `MMC2` before it falls back to `MTD1`
(SPI NAND):

```
Trying to boot from MMC2
MMC: no card present
...
Trying to boot from MTD1
```

On an unfused board that ordering is itself the attack, because any card carrying a `uboot.img`
replaces the bootloader. Enforce `CONFIG_SPL_FIT_SIGNATURE` and `CONFIG_FIT_SIGNATURE` and the same
ordering becomes a feature: a card image is used only if it carries a valid signature.

"Only boot it if it's signed" holds only when four things are true:

1. **The command line has to be inside the signature.** Start a signed `boot.img` with a hostile
   `sys_bootargs` and the genuine kernel boots into the attacker's rootfs. On SD boards the env
   partition sits on the same card, so this is easy to arrange. Fix: `CONFIG_CMDLINE_FORCE`
   ([§6.6](#66-the-kernel-command-line-is-attacker-controlled)).
2. **The rootfs has to be verified too.** A signed kernel says nothing about the rootfs partition
   next to it on the card. That's the job of the §6 initramfs, carried inside the signed `boot.img`.
3. **Removable media supplies data, never code.** `sd_update.txt` is a script U-Boot *executes*; a
   signed image is data U-Boot *verifies*. A secure-boot build should drop the script auto-run and
   only ever load, verify and then use images from the card. If flashing NAND from a card has to
   stay, verify each image's signature before writing it, and never write the env partition.
   (`rk_sign_tool sf`/`vf` also sign and verify whole `update.img` packages.)
4. **Old signed images have to be refused, and for `boot.img` that currently needs OP-TEE.** A
   genuine but outdated `boot.img` on a card passes the signature check. U-Boot proper does have
   `CONFIG_FIT_ROLLBACK_PROTECT` (enforced in `common/image-fit.c`), but `fit-sign.sh` refuses a
   `boot.img` rollback index unless `CONFIG_OPTEE_CLIENT` is enabled too: *"Don't support
   --rollback-index ... due to CONFIG_FIT_ROLLBACK_PROTECT=y but CONFIG_OPTEE_CLIENT=n"*. Only the
   SPL → `uboot.img` step is rollback-protected directly from secure OTP. The source shows why. In U-Boot proper, `fit_read_otp_rollback_index()` (`arch/arm/mach-rockchip/board.c`) calls `trusty_read_rollback_index()`, which is an OP-TEE client call despite the name. SPL's function of the same name reads secure OTP directly. Without OP-TEE, a
   `boot.img` floor has to be anchored in the rollback-protected `uboot.img` instead (see question
   14 in [§10](#10-open-questions-for-a-future-attempt)).

With all four in place, a card holding a signed `uboot.img` and `boot.img` (initramfs included),
plus `rootfs.img` and its detached signature, is a complete, verifiable firmware medium. That works
the same on SD-only boards and as an update path for NAND boards.

---

## 5. Keys, signing, and a staged rollout

The single most important property of this process: **almost all of it can be rehearsed without
burning anything.** Signature *verification* above the BootROM is controlled by U-Boot config that
we own, so the whole pipeline — key handling, signing, verification, and the negative tests — can be
validated on an unfused board and reverted by reflashing. Only the BootROM→loader step needs the
fuse, and that is the last thing you should do.

### 5.1 Generating the key

**RV1106 is supported by `rk_sign_tool` — confirmed on v1.49:**

```
$ ./rk_sign_tool cc --chip 1106
set chip is 1106
setting chip ok.
```

> **`1103` is rejected; the RV1103 entry is `1103b`.** The authoritative list is not compiled in —
> it lives in `rkbin/tools/setting.ini`:
>
> ```ini
> support_chip= 3506|3572|3576|3562|3528|3538|3588|3566|3568|3308|3326|3399|3229|3228h|
>               3368|3228|3288|px30|3328|1808|3228P|1109|1126|2206|1106|1103b|1106b|1126b
> ```
>
> Plain `1103` and `1108` are absent and rejected with *"is not in the support list"*. The
> validation is real, not permissive — `zzzz`, `9999`, `hello` and `0000` are rejected too.
>
> The same file classifies the signing behaviour per chip. **`1106` and `1103b` both appear under
> `hard_sign_pss`, `new_crypto` and `new_idb`** — i.e. RSA-PSS padding, the newer crypto block, and
> the new (RKNS) idblock format. This is why `rk_sign_tool vb --idb` on a shipped `idblock.img`
> reports *"invalid idblock tag"* against the older format expectations.
>
> This is not a problem in practice: the SDK has **no RV1103 U-Boot defconfig** — the Mini builds
> with `luckfox_rv1106_uboot_defconfig`, and `fit-sign.sh` derives the id from the chip name as
> `${CHIP_NAME: 2: 6}`, so an RV1106-configured build signs as `1106` regardless of the board.
> **Sign the RV1103 Mini as `1106`.** (`1103b` is also accepted and may be the true RV1103B entry;
> untested against hardware.)

The tool generates keys itself, and accepts 2048 / 3072 / 4096 bits (all three verified to produce
`private_key.pem` + `public_key.pem`):

```bash
rk_sign_tool cc --chip 1106
rk_sign_tool kk --bits 4096 --out .
```

> **Key size caveat.** `kk --bits 4096` succeeding only proves the *tool* will generate it. The
> BootROM's accepted key size is fixed in silicon and V1.9 documents **RSA-2048** for loader
> verification; the shipped FITs are `sha256,rsa2048` (§3.2). The U-Boot side is sized for more —
> `CONFIG_RSA_N_SIZE=0x200` is 4096-bit (§3.1) — so a larger key may work for the FIT tier while the
> loader tier stays 2048. **Do not assume 4096 end-to-end without testing**, and note that a
> mismatch here is only discovered after the fuse is burned.

`rk_sign_tool kk` also offers `--sm2` and `--ec`. SM2 is Chinese national crypto and not relevant
here; neither is on the documented BootROM path. Stay with RSA.

**Prefer generating it offline with OpenSSL instead.** V1.9 §5.4 explicitly supports loading a
backup key in "`.pem` file format generated by openssl", and `rk_sign_tool lk` takes an existing
keypair. That keeps key generation on a machine of your choosing, with entropy and storage you
control, rather than inside a closed-source vendor tool:

```bash
# On an air-gapped machine
openssl genrsa -out privateKey.pem 2048
openssl rsa -in privateKey.pem -pubout -out publicKey.pem
```

Then load it on the signing machine:

```bash
rk_sign_tool lk --key privateKey.pem --pubkey publicKey.pem
```

> A step-by-step bench walkthrough — key, sign, flash, watch the fuse enable over UART — is in
> [secure-boot-bench-procedure.md](secure-boot-bench-procedure.md), including generating the key from
> a SeedSigner via **BIP85** (validated: `bip85_rsa_from_root` → PyCryptodome `export_key('PEM')` →
> `rk_sign_tool`), so the signing key is reproducible from a BIP39 seed.
>
> Back this key up before it is ever used. V1.9 §5.2: *"Once you lost it or leak it, your product
> will be exposed in high risk, also the old device will be unable to be updated anymore."* A lost
> key means every fused device is permanently un-upgradable.

### 5.2 Can the private key stay on a smartcard / HSM?

**Yes — and better than expected: the tool has native HSM support.** (An earlier revision of this
document said no; that was wrong, and the correction removes the main key-custody objection to the
Rockchip tier.)

### First choice: native HSM / PKCS#11

`rkbin/tools/setting.ini` — the tool's persistent config — carries these keys:

```ini
using_hsm=
hsm_engine_id=
hsm_private_key_id=
hsm_public_key_id=
```

That is first-class OpenSSL-engine signing: point it at a PKCS#11 token and the private key never
leaves the device, with no manual digest shuffling. **This is the path to try first.** Untested here
(no token to hand); the exact engine id and key-id syntax needs establishing.

### Second choice: extract / inject — verified working

`rk_sign_tool` v1.49 exposes a two-phase "sign state":

```
sign_tool ss <--extract>   // extract data to sign from external
sign_tool ss <--inject>    // write signed data back into source
sign_tool ss <--out>       // location for saving and reading that data
```

So the flow is: **extract** the digest/payload → sign it on an HSM, PKCS#11 token, or air-gapped
machine → **inject** the signature back into the image. The private key never has to exist on the
build machine, for *any* tier including the loader.

| What is being signed | Private key can stay off the build host? |
|---|---|
| Loader / idblock (BootROM-verified) | **Yes** — via `ss --extract` / `ss --inject` |
| `uboot.img` / `boot.img` (FIT) | **Yes** — same mechanism; upstream `mkimage -N pkcs11` is an alternative |
| Rootfs (secondary tier, §6) | **Yes** — entirely our design; a hardware wallet or another SeedSigner |

**Still not possible:** handing the tool only a public key and expecting it to sign. Signing needs
the private key *somewhere* — the point of `--extract`/`--inject` is that "somewhere" can be a
device that never exports it.

**Run and confirmed working.** Extracting from a real `download.bin`:

```
$ rk_sign_tool ss --out=<dir>
$ rk_sign_tool ss --extract
$ rk_sign_tool sl --loader download.bin
extract data into si_usb_head.bin...
extract data into si_flash_head.bin...
```

Both files are **exactly 32 bytes — bare SHA-256 digests**, not padded blocks:

```
si_usb_head.bin    6251fac916b0291f06e7aec99f8dd1ee4bc93e5dc613cdf21a819b56c6bbf0a1
si_flash_head.bin  e73153ec45740feffd77587b4396ac33add7f35ad1acfe4f3629b4d1cb58e9f6
```

This is the good outcome: signing a bare digest is within reach of essentially any HSM or PKCS#11
token. Two digests because the loader carries separate USB-boot and flash-boot headers. The
equivalents for other targets are `si_idb_head.bin` and `si_update_hash.bin` (strings in the
binary).

> **The padding is RSA-PSS, not PKCS#1 v1.5.** `setting.ini` lists `1106` and `1103b` under
> `hard_sign_pss` (and under `new_crypto` / `new_idb`). An external signer must therefore produce a
> **PSS** signature over the extracted digest. Signing these digests with
> `openssl pkeyutl -pkeyopt rsa_padding_mode:pkcs1` produces a well-formed 256-byte blob that the
> tool then rejects — the injection step was not completed here, and the exact file name/location it
> expects for signed data still needs establishing (see §10).

**Two operational gotchas, both discovered the hard way:**

- **`ss --out=<path>` requires the `=` form.** Space-separated (`ss --out <path>`) fails with
  `setting sign argument failed, ... is not existed` and silently leaves the previous value.
- **The tool is stateful.** `sign_state`, `select_chip`, key paths and `sign_out` all persist in
  `setting.ini` between invocations, so a tool left in `extract` or `inject` mode will keep behaving
  that way in a later, apparently unrelated run. Reset `sign_state=` before normal signing — this is
  an easy way to produce an unsigned image while believing you signed it.

Note also `rk_sign_tool mcr <--key> <--pubkey>` ("create secondary cert") and `ss --cert`, which
suggest a two-level key hierarchy is supported — potentially a way to keep a root key fully offline
and delegate to a signing key. Undocumented in the guides reviewed; worth investigating if key
hierarchy matters.

Note the practical asymmetry, which is the main argument for the two-tier design in
[§6](#6-extending-the-chain-to-the-rootfs): the Rockchip RSA key is needed only when the loader or
`boot.img` changes, whereas the **rootfs key is used for every release** — and that is precisely the
one that can be hardware-backed. GPG/OpenPGP cards are a poor fit for the Rockchip tier (no raw
PKCS#1 signing path); a PIV/PKCS#11 token is the realistic option.

### 5.3 Signing

**Use `fit-sign.sh`, not raw `rk_sign_tool si`.** This was established empirically: running
`rk_sign_tool vi --img uboot.img` against a shipped image returns *"the image did not support to
sign"*, because on FIT-era platforms like RV1106 the `uboot.img` / `boot.img` FITs are signed by
U-Boot's own `mkimage`, and only the loader and idblock go through `rk_sign_tool`.
`rkbin/tools/fit-sign.sh` orchestrates both halves.

```
Usage:
    ./fit-sign.sh [args]

Args:
    --key-dir                  <dir>                         | Mandatory
    --src-dir                  <dir>                         | Mandatory
    --out-dir                  <dir>                         | Mandatory
    --burn-key-hash                                          | Optional
    --rollback-index           <image1 n1> <image2 n2> ...   | Optional
    --version                  <image1 n1> <image2 n2> ...   | Optional

Example:
    ./fit-sign.sh --key-dir keys/ --src-dir src/ --out-dir output/ \
                  --version uboot.img 1 boot.img 3 --rollback-index uboot.img 3 boot.img 5
```

What it does internally (read from the script):

- **FITs** — `mkimage -f image.its -k <key-dir> -K u-boot-spl.dtb -E -p 0x1200 -r image.itb -v <version>`.
  Standard U-Boot FIT signing; `-K` injects the public key into the SPL DTB. Because this is genuine
  `mkimage`, the `-N pkcs11` engine route for hardware-held keys is plausible here (§5.2).
- **Loader / idblock** — `rk_sign_tool cc --chip <id>`, `lk --key ... --pubkey ...`, then
  `sl --loader <download|loader|MiniLoaderAll>.bin` and `sb --idb <idblock>.img`.
- **Chip id** is derived as a bash substring, `${CHIP_NAME: 2: 6}` — i.e. `RV1106` → `1106`. See the
  note in §5.1 about RV1103.
- **Config coupling** — it reads the U-Boot config from
  `<src-dir>/fit_signcfg/sign.readonly_config` and changes behaviour based on it. Signing is
  therefore **not** a pure post-process of shipped artifacts: it needs the SPL DTB and the U-Boot
  build config alongside the images. Budget integration work for this.

`rk_sign_tool`'s own verb set is still useful for verification and inspection:

| Verb | Purpose |
|---|---|
| `sl` / `vl` | sign / **verify** loader |
| `si` / `vi` | sign / **verify** image (uboot, boot, trust) |
| `sb` / `vb` | sign / **verify** idblock binary |
| `sf` / `vf` | sign / **verify** update firmware (`update.img`) |
| `sd` / `vd` | sign / verify DDR test config |
| `otp --loader [--hash]` | **extract the OTP data from a signed loader** |
| `ss --flag <hex>` | set sign flag (this is V1.9 §6.6's `sign_flag`) |
| `ss --version <hex>` | set sign version — feeds the SPL rollback index |
| `ss --nonce`, `ss --cert` | signing nonce; secure cert |
| `mcr` | create secondary cert |

Two of these are worth calling out because they materially de-risk the process:

- **`vl` / `vi` / `vb` / `vf` verify offline.** You can confirm a signature is well-formed before
  ever flashing it, and confirm the key you loaded is the key that signed.
- **`otp --loader <signed loader> --hash`** extracts exactly the OTP payload that would be burned.
  **Inspect and record this before Stage D** — it lets you see the public-key hash destined for the
  fuse rather than discovering it afterwards. There is no way to read it back out and compare later.

Signing must happen **after** the images are built and after any post-processing that rewrites them
— including this repo's reproducibility normalisation in `normalise_boot_images()`
([`opt/luckfox/os-build.sh`](../../opt/luckfox/os-build.sh)), which rewrites `download.bin`'s
`releaseTime` and repairs its trailer checksum. Signing before that would invalidate the signature.

Signing must happen **after** the images are built and after any post-processing that rewrites them
— including this repo's reproducibility normalisation in `normalise_boot_images()`
([`opt/luckfox/os-build.sh`](../../opt/luckfox/os-build.sh)), which rewrites `download.bin`'s
`releaseTime` and repairs its trailer checksum. Signing before that would invalidate the signature.

### 5.4 Staged rollout — rehearse everything before the fuse

Each stage is reversible until Stage D. Do all of them on a sacrificial board first.

> **These stages were run end-to-end on 2026-09-12** (RV1103 Mini, committed public dev key) and all
> passed — see [§13.1](#131-signed--fused-run-2026-09-12-committed-public-dev-key). Two practical
> notes from that run: signing is done **in-build** (`SEEDSIGNER_FIT_SIGNATURE=1` signs the whole
> chain; `boot.img` needs the extra `sign_boot_image` step because the SDK doesn't sign it), and the
> burn is armed with `SEEDSIGNER_FIT_BURN_KEY_HASH=1` rather than a manual `rk_sign_tool` step. The
> `rk_sign_tool vi` offline checks below still work for inspection. Substitute your real secret key
> for the dev key in a real deployment.

**What to watch in the boot log.** An unfused, unsigned RV1103 Mini (SeedSigner build, booting from
SPI NAND) prints these today. They are the before-state every stage should be compared against:

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

The `sha256+ OK` lines are **hash integrity checks, not signature checks**: they pass on any
self-consistent image, an attacker's included. The lines that must change are `Verified-boot: 0`
(expect `1`) and `FIT: no signed, no conf required`. After Stage A both should report signed /
required. If either still reads as above, verification is not actually enabled, whatever the build
config says.

One more line in that log matters for a locked-down build: `Hit key to stop autoboot('CTRL+C'):  0`.
**`CONFIG_BOOTDELAY=0` does not prevent interruption.** The SDK's `common/autoboot.c` runs the abort
check whenever `bootdelay >= 0`, and the Kconfig help says so directly: *"set to 0 to autoboot with no
delay, but you can stop it by key input ... set to -2 to autoboot with no delay and not check for
abort."* Holding CTRL+C on the UART at power-on reaches a U-Boot prompt, and on a fused board that
still means memory read/write and control of the environment. Rockchip also extended the abort test
with `|| env_get("cli")`, so a `cli` environment variable reaches the prompt with no keypress at all.
A secure-boot build needs `CONFIG_BOOTDELAY=-2`, which skips the abort check entirely. The env
partition can't undo that, because ENVF imports only a whitelist that excludes `bootdelay` and `cli`
([§6.6](#66-the-kernel-command-line-is-attacker-controlled)). Upstream U-Boot still drops into its
CLI when `bootcmd` fails, though, so also set `CONFIG_CONSOLE_DISABLE_CLI=y` and check on hardware
what a failed boot actually does.

**Stage A — validate the signing pipeline with no fuse at all.**

Enable verification in the Luckfox U-Boot defconfig
(`sysdrv/source/uboot/u-boot/configs/luckfox_rv1106_uboot_defconfig`):

```
CONFIG_FIT_SIGNATURE=y
CONFIG_SPL_FIT_SIGNATURE=y
```

Sign `uboot.img` and `boot.img` with the real key, replace the `key-name-hint = dev` placeholder
(§3.2) with the real key name, then **verify offline before flashing**:

```bash
rk_sign_tool vi --img uboot.img
rk_sign_tool vi --img boot.img
```

Flash and confirm the board boots.

This exercises key loading, signing, and U-Boot/SPL verification end to end. **No OTP is touched**;
if anything is wrong the board still boots unsigned images and you revert by reflashing.

**Stage B — the negative test. Do not skip this.**

Corrupt one byte of the kernel payload inside a signed `boot.img`, reflash, and confirm U-Boot
**refuses to boot it**. A verification step that has never rejected anything has not been shown to
work — up to this point a misconfiguration is indistinguishable from success, because an
unverified image boots fine either way.

Repeat with a `boot.img` signed by a *different* key. It must also be rejected.

**Stage C — validate loader signing without enabling enforcement.**

Sign the loader **without** `sign_flag=0x20`, so no OTP write is armed, and flash it. An unfused
board ignores loader signatures entirely, so it should boot exactly as before. This confirms the
loader signing and repacking path still produces a bootable image — the step most likely to go
wrong silently, and the one you cannot retry after Stage D.

Before proceeding, confirm you have: a known-good unsigned image, a **proven** rockusb/maskrom
recovery path exercised on this exact board, and an answer to open question 5 in
[§10](#10-open-questions-for-a-future-attempt).

**Stage D — the point of no return.**

Per V1.9 §6.6, newer platforms self-program rather than needing an external eFuse power rig:

1. Arm the OTP write with **`fit-sign.sh --burn-key-hash`**. This supersedes V1.9 §6.6's
   `sign_flag=0x20` `config.ini` edit — the script sets `burn-key-hash 0x1` on the
   `/signature/key-dev` node of the SPL DTB, and **hard-requires `CONFIG_SPL_FIT_HW_CRYPTO=y`**
   (already set in the Luckfox defconfig, §3.1) or it refuses to run.
2. Re-sign with that flag set, then record the OTP payload that is about to be burned:
   `rk_sign_tool otp --loader <signed loader> --hash`.
3. Flash and reboot. **The loader itself** computes the public key hash, writes it to OTP, and
   enables secure boot.
4. Serial prints `otp write key success!!!`, or `otp write error: !!!` on failure.

Verification (V1.9 §8.1) — the boot log shows:

```
Secure Boot Mode: 0x1
SecureBootEn = 1, SecureBootLock = 1
```

**Stage E — confirm enforcement is real.** On the fused board, attempt to flash an unsigned image.
It must fail. If an unsigned image still boots, the fuse did not take and the device is in the worst
possible state: it looks protected and is not.

> **What cannot be rehearsed.** BootROM enforcement itself. Stages A–C prove the keys, the tooling
> and the images are correct, which removes most of the risk — but the BootROM's behaviour on a
> fused RV1106 is only observable after the fuse is burned.

> **This is the step with no RV1106 documentation.** The self-programming flow is described for
> RK3228H / RK3328 / RK3308 / PX30. Whether RV1106 uses the same `sign_flag` mechanism, the same
> serial markers, or something else entirely is **unknown, and must be established on a board you
> are willing to destroy.**

### 5.5 A separate fuse worth knowing about

`rkbin/doc/release/RV1106_EN.md` notes that `rv1106_ddr` v1.16 adds *"Support disabling download
function through OTP"* — an independent, irreversible fuse that disables the rockusb download path. (The SeedSigner build currently ships DDR blob **v1.15**, per `fwver: v1.15` in the boot log, which predates that feature.)

Burning it would remove the recovery failover configured by
[`opt/luckfox/uboot-recovery-config.sh`](../../opt/luckfox/uboot-recovery-config.sh) and described
in [README.md](README.md). **Recommend leaving it alone** even if secure boot is adopted: it turns
every future firmware bug into a dead board.

---

## 6. Extending the chain to the rootfs

The vendor chain stops at `boot.img`. The rootfs is a separate squashfs partition (103M on the Mini,
per `opt/luckfox/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch`) and is not
covered. Closing that gap is where the interesting design choices are.

### 6.1 Where verification logic can run

| Layer | What is possible | Verdict |
|---|---|---|
| **SPL / U-Boot** | RSA-2048 only (already compiled in). Anything more means porting crypto into U-Boot C. OpenPGP parsing is not realistic here. | **Do not put policy at this layer.** |
| **initramfs inside `boot.img`** | Full userspace before pivoting to the real rootfs. Arbitrary logic: signature schemes, m-of-n thresholds, key rotation, revocation. | **This is the right layer.** |

`boot.img` is a FIT. It has no ramdisk slot today, but FIT supports one and the existing
`sign-images = fdt kernel multi` list simply gains `ramdisk`. **An initramfs is therefore covered by
the same RSA signature that already protects the kernel** — no new cryptographic machinery needed.

### 6.2 Space budget

- boot partition: **4M**
- current `boot.img`: **2.65MB**
- headroom: **~1.3MB**

That fits busybox plus a compact verifier. It does **not** fit GnuPG2, which is already in the
rootfs at ~2MB (`opt/luckfox/configs/luckfox_pico_defconfig:490-491`). The partition layout is ours
to change if GPG is genuinely wanted — the rootfs has room to give.

### 6.3 Pin a key, not a hash

There is an existing in-repo precedent for hash pinning:
[`opt/rootfs-overlay/etc/mdev/mdev.sh`](../../opt/rootfs-overlay/etc/mdev/mdev.sh) refuses to mount
`diy-tools.squashfs` on a SHA256 mismatch (`REFUSED_HASH_MISMATCH`, see
[`docs/diy_tools.md`](../diy_tools.md)). That model works, but it is rigid.

**Pinning a public key instead of a hash is strictly better here.** A pinned hash authorises exactly
one rootfs, so every update requires re-signing `boot.img` — and therefore everything above it in
the chain. A pinned *public key* inside the signed `boot.img` can authorise many future rootfs
images, giving **rootfs updates without re-burning OTP or re-signing the loader.**

This does not escape having a pinned trust root. It upgrades it from a value to an authority.

### 6.4 Candidate signature schemes

| Scheme | Approx. size | Notes |
|---|---|---|
| Bitcoin signed message | ~200–300KB | Signing key can live on a hardware wallet or another SeedSigner; familiar UX for this audience; m-of-n is natural |
| minisign / signify (Ed25519) | ~50KB | Smallest and simplest parser |
| Full GnuPG | ~2MB | Matches existing release-signing practice; largest pre-boot attack surface |

> **Attack-surface caveat.** Anything in the initramfs runs *before* the rootfs is verified and is
> itself protected only by the `boot.img` signature. A large, historically CVE-prone format parser
> (OpenPGP especially) is a poor thing to expose pre-boot. This argues for the Bitcoin-message or
> minisign route over full GPG independently of size.

### 6.5 Verify lazily, not all at once

Do **not** hash the whole 103MB squashfs at boot — that is seconds of added boot time on every
power-on. Sign the **dm-verity root hash** instead: a small verification at boot, then lazy
per-block verification on access.

dm-verity would use the kernel's software SHA — **not** the Rockchip crypto engine, because that
driver is not actually built (see the note below). If hardware acceleration were ever wanted for
this, it would first have to be made to build.

> **Correction (bench-confirmed):** `opt/luckfox/os-build.sh` sets `CONFIG_CRYPTO_DEV_ROCKCHIP=y`
> and asserts it, but the hardware crypto driver is **absent from the running kernel** — `/proc/crypto`
> has no `rk` algorithms and `ff440000.crypto` is unbound. The umbrella symbol needs
> `CONFIG_CRYPTO_DEV_ROCKCHIP_V3=y` (the RV1106 sub-option) to compile any code, and the build's
> assertion only greps the defconfig text, so it reports success regardless. Harmless — SeedSigner
> uses software crypto — but it means the hardware engine is not available, and pinning `&crypto` in
> the DTS is currently a no-op (nothing binds it). The `&rng` pin, by contrast, is real and working.

### 6.6 The kernel command line is attacker-controlled

This finding is the one most likely to defeat a rootfs-verification design, so it gets its own
section.

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

Whatever `sys_bootargs` the env partition holds is merged into the kernel command line. The SD image
carries `sys_bootargs= root=/dev/mmcblk1p7 rootfstype=squashfs rk_dma_heap_cma=1M` at sector 0, and
no signature covers any of it.

**What this means for §6:** take a fully fused board with a genuine, signed `boot.img`. An attacker
who can write the env partition adds `rdinit=`, `init=` and `root=`, and the signed kernel boots into
their own root filesystem without ever running the initramfs verifier. `blkdevparts` and `mtdparts`
are in the same list, so the partition layout can be redefined as well. Writing the env partition is
trivial on SD boards, where it sits on the removable card. On NAND boards `sd_update.txt`'s
`mtd write` reaches it ([§4.1](#41-boot-media-sd-card-boot-works-the-same-way)). Secure boot doesn't
notice, because no unsigned firmware ever runs.

> **Update (2026-09-12): a signed FIT changes the runtime picture, and the opt-in build now bakes
> `root=` into the signed DTB.** When `boot.img` is a signed, conf-required FIT, u-boot no longer
> rewrites the kernel DTB's `/chosen/bootargs` at runtime — the fused Mini booted with exactly the
> `/chosen` string baked into the DTB. This was first seen as a *failure* (the SDK's shared
> `ipc.dtsi` hardcodes the SD default `root=/dev/mmcblk1p7`, so the NAND board hung; `apply_signed_nand_bootargs`
> now bakes `root=ubi0:rootfs ubi.mtd=6 rootfstype=ubifs rk_dma_heap_cma=<size>` in for signed NAND).
> The security upshot: `root` is now pinned inside the signed image rather than taken from the
> unsigned env. **This is a real improvement but not a full fix** — `sys_bootargs` is still merged
> *after* the baked `/chosen`, so an attacker who writes the env partition can still append a later
> `root=`/`rdinit=` that wins. Mitigations 1–3 below still stand for full lockdown.

**The same code has good news:** the import is filtered by that list, so the partition **cannot**
set `bootdelay` or Rockchip's `cli` variable. Neither is whitelisted, which means
`CONFIG_BOOTDELAY=-2` holds against the env partition (see the autoboot note in §5.4).

Mitigations for a secure-boot build, in order of preference:

1. **Kernel `CONFIG_CMDLINE` with `CONFIG_CMDLINE_FORCE=y`.** The command line is compiled into the
   kernel, which lives in the signed `boot.img`, and the kernel ignores whatever the bootloader
   passes. That holds whatever U-Boot or ENVF do, which is why it comes first. `root=`,
   `rootfstype=`, `rk_dma_heap_cma=` and the MTD partition layout then have to be baked in for each
   board/medium variant. Untested on the SDK's 5.10 kernel.
2. **Remove `sys_bootargs`, `blkdevparts` and `mtdparts` from `CONFIG_ENVF_LIST`** (or disable
   `CONFIG_ENVF`) and carry those values in the compiled-in default environment inside the signed
   `uboot.img`. This repo currently delivers its partition layout through `RK_PARTITION_CMD_IN_ENV`
   (see `opt/luckfox/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch`), which ends
   up in the env partition, so that path has to move.
3. **Pin the rootfs device inside the initramfs** instead of reading `root=`. Then even a hostile
   command line can't redirect what gets verified.

Only (1) closes the whole class. (2) and (3) are worth keeping as defence in depth.

---

## 7. Consequences (decide these before touching a fuse)

- **Key custody.** V1.9 §5.2, verbatim: *"Once you lost it or leak it, your product will be exposed
  in high risk, also the old device will be unable to be updated anymore."* Whoever holds the key
  becomes a permanent central point of trust and failure for every device ever fused.
- **It verifies software, not hardware.** V1.9 intro: *"Secure boot will verify the validity of
  software, but not hardware."* Signed firmware boots on any board of the same platform, so this
  does **not** defend against a substituted or cloned device — a significant part of the evil-maid
  threat model is untouched.
- **Reproducible builds survive.** Signing is a final step over an otherwise byte-reproducible
  image, so users can still reproduce and verify the unsigned payload. Worth stating explicitly,
  because it is the main tension with this project's build model.
- **Recovery disappears.** A fused device cannot be rescued by flashing an unsigned image. Combined
  with §5.5 it is possible to build a device with no recovery path at all.
- **Who holds the key?** A project-held key contradicts "build and flash your own image". The
  alternative — **each user fuses their own key** — preserves that property at the cost of an
  irreversible, brick-capable step in the user's hands. This is the central open question, and it is
  a policy decision rather than a technical one.

---

## 8. Device PIN and anti-phishing words

### 8.1 The gap they close

Secure boot answers "is the firmware on *this* device genuine?". It can't answer "is this the device
I set up?", because, as V1.9 puts it, it verifies software, not hardware. Suppose someone swaps your
SeedSigner for a look-alike: their own board and firmware inside your case. That device verifies its
*own* boot chain perfectly well, so nothing in §4–§6 notices. It can capture a seed as you enter or
scan it, or show a doctored transaction summary, and leak data later through a QR code.

Anti-phishing words close that gap. The genuine device shows words only it can compute; a
look-alike can't produce them. The two mechanisms depend on each other:

| Attack | Stopped by |
|---|---|
| Tampered firmware on *your* device | Secure boot (§4–§6) |
| A look-alike device swapped in for yours | Anti-phishing words |

Without secure boot the attacker doesn't need a look-alike. They reflash *your* device with
firmware that reads the real secret, shows the real words, then steals the seed.

You set the words up the first time you use the device, so they protect every use after that. They
can't catch a device that was swapped before you ever set it up.

### 8.2 How it works

The PIN is split into a **prefix** and a **suffix**, the same flow as Coldcard's anti-phishing
words.

1. **Setup, once.** The device generates a 32-byte `device_secret` from the hardware RNG
   ([`docs/hwrng.md`](../hwrng.md)) and stores it (§8.4). The user picks a PIN, for example a
   6-digit prefix plus a 4-digit suffix. The device shows the two words for that prefix, the user
   memorises them, and the device stores a verifier for the full PIN.
2. **Every boot.** Enter the prefix and the device shows two words. **If they're wrong, stop:** don't
   enter the rest, and don't use the device. If they're right, enter the suffix; the device checks
   the full PIN and unlocks.

The PIN is split because the words have to appear *before* you've typed the whole PIN into what
might be a fake. A fake only learns the prefix, and the prefix can't produce the words without the
device secret.

The device shows words for *any* prefix. If it rejected wrong prefixes, it would reveal which one is
correct. So there is no "wrong prefix", only a different pair of words.

### 8.3 Deriving the words

```
k0    = HMAC-SHA256(key = device_secret,
                    msg = "seedsigner/anti-phishing/v1" || board_id || prefix)
k     = PBKDF2-HMAC-SHA256(password = k0, salt = "seedsigner/anti-phishing/v1",
                           iterations = N)            # tune N to ~1 s on the device
words = BIP39_WORDLIST[bits 0-10 of k], BIP39_WORDLIST[bits 11-21 of k]
```

- **Key the HMAC with the secret first.** This is what defeats a fake: without `device_secret` it
  can't compute `k0`, even after watching you type the prefix. A plain `hash(prefix)` would be
  useless, because a fake could compute it too.
- **Then slow it down.** Anyone wanting to map *every* prefix to its words has to do it on the
  genuine device, at about a second each. For a 6-digit prefix that's roughly 11 days of continuous
  entry. This only helps while the secret can't be copied off the device (§8.4); with a copied
  secret, the enumeration runs offline on fast hardware.
- **`board_id`** should be the per-device value the kernel already derives into the `Serial` line of
  `/proc/cpuinfo` (a 64-bit id; `d6d9fb7e70873741` on the test board). **Bench-checked correction:**
  this is *not* the raw `otp_id` cell. `otp_id` at OTP offset `0x0a` reads `M4T961...`, a wafer/lot
  marking that may not be unique per die; the kernel hashes it (with `cpu_code`/`cpu_version`, per the
  `rockchip,cpuinfo` node) into the `Serial`. Use the derived `Serial`, not the raw cell. It isn't
  secret, but mixing it in ties the words to this SoC, so a copied SD card in someone else's board
  gives different words. Matters most on SD boards, where the card is the easy part to copy.
- **Two BIP39 words give 22 bits**, so a fake guessing blindly is right about once in 4 million.
  Label them clearly on screen so they can't be mistaken for seed words.
- **Full-PIN verifier:** store
  `PBKDF2(full_pin, salt = HMAC(device_secret, "seedsigner/pin-verifier/v1"), iterations = N)` and
  compare in constant time. Because the salt is keyed with the secret, a stolen verifier can't be
  brute-forced offline without the secret too.

The domain-separation strings stop one derived value being substituted for the other. The app
already runs PBKDF2 for BIP-39 seeds, so the primitives are in place. This belongs in the app repo
and runs before the main menu (or inside a trusted app once OP-TEE is in, §8.4).

Anyone who sees your prefix and later has your device for a moment can learn your words. Guard the
prefix like the rest of the PIN.

### 8.4 Where the device secret lives

Everything above depends on the secret staying on the device, and RV1106 makes that hard:

| Storage | Copyable by someone who had the device briefly? | Available without OP-TEE? |
|---|---|---|
| File on a writable partition (e.g. `userdata`) | **Yes.** On SD boards: pull the card. On NAND boards: dump the flash, or use `sd_update.txt` while it's enabled | Yes |
| On-die OTP, written from Linux | n/a | **No.** RV1106's nvmem driver is read-only (`rv1106_data` in `drivers/nvmem/rockchip-otp.c` has no `.reg_write`) and its 128 bytes hold factory cells. The OEM write path (`rv1126_otp_oem_write`) exists only for RV1126 |
| Secure OTP Protected OEM Zone | **No.** On-die, and readable only by trusted apps the TEE accepts (OTP guide §3.1) | **No, needs OP-TEE.** The Non-Protected zone and the OEM Cipher Key are reached through OP-TEE too; "Non-Protected" only means normal-world code may *read* it via the TEE |
| Secure OTP via a custom SPL patch | No | **Possibly.** SPL already reads and writes secure OTP directly (`misc_otp_read`/`misc_otp_write` on `OTP_S`, as the rollback counter does), but it needs a spare region and none is documented |
| Smartcard | No | **Doesn't close the gap.** A secret on the card authenticates the *card*: your genuine card in a look-alike still computes the right words. It's the right tool for protecting keys *on* the card, not for recognising the device |

An earlier revision of this section said the smartcard was the best home for the secret and that
the Non-Protected OTP zone was reachable today. Both were wrong, for the reasons in the table.

**Recommendation:**

1. **Ship v1 with the secret in a file, bound to `board_id`.** It needs no fuse and no OP-TEE, and it
   defeats a pre-built look-alike from someone who never had your device, which is the common swap.
   It doesn't defeat someone who had your device long enough to copy the secret. Say so plainly in
   the UI and the docs.
2. **Then move the secret into OP-TEE's Protected OEM Zone** ([§9](#9-op-tee)). This is the
   documented route to an on-die secret that normal-world code can never read. Compute the §8.3
   words inside a trusted app (TA), so the secret never enters Linux memory and the TA enforces the
   slow derivation itself. The same integration delivers `boot.img` rollback protection
   ([§4.2](#42-signed-images-on-microsd-the-model-that-replaces-sd_updatetxt)). If OP-TEE is ever
   dropped, the SPL patch is the fallback.
3. **Either way, none of this means anything until secure boot** (§4–§6) stops the firmware on your
   own device being replaced.

### 8.5 What the PIN itself protects

SeedSigner stores no seed at rest, so the full PIN mainly gates the UI and carries the
anti-phishing check. A failure counter needs storage that can only count upward. A counter on a
writable partition can be reset by anyone who can write that storage, so it deters a casual finder,
not a determined attacker. OP-TEE doesn't fully fix this on NAND or SD boards ([§9](#9-op-tee)). If
encrypted persistent settings are added later, derive their key from the full PIN and
`device_secret`; then the PIN protects real data.

To slow down prefix enumeration without a persistent counter, cap prefix attempts per boot (say
three), then force a reboot. At ~15 s per reboot, trying all 10^6 prefixes takes about two months.
That helps whenever the secret can't be copied off the device.

---

## 9. OP-TEE

Earlier revisions recorded OP-TEE as considered and rejected. It is **now worth adopting**, because
two findings since then give it jobs that nothing else on this chip does as well:

- **An on-die device secret for anti-phishing words** that normal-world code can never read: the
  Protected OEM Zone ([§8.4](#84-where-the-device-secret-lives)). Without OP-TEE, Linux can't write
  any RV1106 OTP region at all.
- **`boot.img` rollback protection**, which stock U-Boot enforces only through OP-TEE
  ([§4.2](#42-signed-images-on-microsd-the-model-that-replaces-sd_updatetxt)).

The trade-off hasn't gone away: this puts a **closed-source secure-OS blob, running at higher
privilege than the kernel,** on a device whose selling point is auditability. It is being accepted
knowingly, for those two uses.

### What is already there

The blob is in the SDK: `rkbin/bin/rv11/rv1106_tee_ta_v1.11.bin`, a build that can run trusted apps.
Upstream rkbin has moved on to `rv1106_tee_ta_v1.14.bin`, and its release notes say v1.12 added "OTP
hardware lock, allowing secure and non secure OTP access simultaneously". Linux reads the chip ID
from non-secure OTP while the TEE uses secure OTP, so the newer blob is probably worth using. Check
its release notes before switching.
`RKTRUST/RV1106TOS.ini` points at it (`TOSTA=bin/rv11/rv1106_tee_ta_v1.11.bin`,
`ADDR=0x03000000`), and the U-Boot FIT generator is `make_fit_optee.sh`. **None of it ships today.**
Checked against a built image:

- the `uboot.img` FIT's `/images` holds only `uboot` and `fdt`, even though its description string
  reads "FIT Image with ATF/OP-TEE/U-Boot/MCU"
- the kernel has no `CONFIG_TEE` / `CONFIG_OPTEE`
- the shipped DTB has no `optee` node (`rv1106.dtsi` defines one with `status = "disabled"`)

### Integration work

1. Pack `rv1106_tee_ta_v1.11.bin` into `uboot.img`. On RV1106 the TEE lives in `uboot.img`; there is
   no separate `trust.img` (TEE SDK §3.3).
2. Kernel: set `CONFIG_TEE=y` and `CONFIG_OPTEE=y`, and set the DT `optee` node to `okay` (TEE SDK
   §3.5.2). `/dev/tee0` and `/dev/teepriv0` should then appear.
3. Userspace: `tee-supplicant` and `libteec.so` from the SDK's own `media/security/bin/optee_v2/`
   (TEE SDK §3.6), not upstream Buildroot's `optee-client`, so that they match the TEE binary. There
   is a `uclibc_lib/` variant, which matters because the Luckfox rootfs is uClibc. The SDK warns that
   mismatched U-Boot/TEE/library versions fail with API-revision errors.
4. A trusted app that keeps the device secret in the Protected OEM Zone and computes the §8.3 words
   internally.
5. **Replace the TA signing key before shipping** (TEE SDK §5). The TEE binary holds an RSA-2048
   public key and runs only TAs signed with the matching private key, and only TAs it accepts can
   reach the Protected OEM Zone. **The default private key is public:** it's committed in the SDK at
   `media/security/rk_tee_user/v2/export-ta_arm32/keys/oem_privkey.pem`. While it stays in place,
   anyone can sign a TA your device will run, and that TA can read the secret. To replace it:
   1. Run `media/security/rk_tee_user/v2/tools/change_puk_tool-release --teebin <TEE binary>`
      (TEE SDK §5.2 calls it `change_puk`). It generates a new key and patches the public half into
      the TEE binary.
   2. Rename the key to `oem_privkey.pem` and put it in `rk_tee_user`'s keys directory.
   3. Rebuild the TAs. Prebuilt TAs signed with the old key, such as the one in
      `media/security/bin/optee_v2/ta/`, will stop loading. Re-sign any you still need with
      `ta_resign_tool-release`, which is in the same `tools/` directory.
   4. Rebuild `uboot.img` (RV1106 has no `trust.img`).

   That makes a third key to guard, alongside the boot-chain RSA key and the rootfs Bitcoin key, and
   the patched TEE binary becomes a build input.
6. U-Boot: `CONFIG_OPTEE_CLIENT`, which also unlocks `boot.img` rollback via
   `fit-sign.sh --rollback-index boot.img <n>`.

### Limits worth knowing

- **Memory:** TEE_RAM 1M + TA_RAM 1M + SHMEM 512K (TEE SDK §10.2), about 2.5MB of the Mini's 64MB,
  where DRAM is already tight.
- **NAND and SD boards have no RPMB.** Secure storage there sits in a `security` partition on
  ordinary flash (TEE SDK §3.2, §11.1). It's encrypted, but an old copy can be written back, so a
  PIN failure counter kept there can still be reset. A counter that truly can't go backwards needs
  RPMB (eMMC, so only the Pico Pi) or OTP bits.
- **How strongly secure storage is tied to the chip isn't documented for RV1106.** TEE SDK §12
  (chip-bound storage keys) is scoped to RK3588/RK3528/RK3562. rkbin's RV1106 release notes do say
  TEE v1.10 added "security level" support with derived secure storage keys, so some binding probably
  exists, but it's undocumented. That's one more reason to keep the device secret in the Protected
  OEM Zone, which is on-die OTP, rather than in secure storage.
- **Trusted UI is still unavailable** for the SPI display. The TEE protects the secret, not what the
  screen shows.

---

## 10. Open questions for a future attempt

1. ~~What is the correct `rk_sign_tool` chip identifier?~~ **Answered:** `1106`. Plain `1103` is
   rejected by v1.49; the Mini signs as `1106` because it builds with the RV1106 U-Boot defconfig.
2. ~~Does RV1106 use the `sign_flag=0x20` flow?~~ **Answered NO (hardware-confirmed, 2026-09).**
   Flashing a loader signed with `ss --flag 0x20` on an RV1103 Mini produced no OTP write
   (`Verified-boot` stayed `0`, no `otp write key success`, board unfused). RV1106 burns the key
   hash only via the FIT `--burn-key-hash` mechanism, confirmed via the in-build `make.sh` FIT flow
   (`arm_fit_burn_key_hash`). The legacy loader `sign_flag` path does nothing on this SoC.
3. ~~Does enabling `CONFIG_FIT_SIGNATURE` / `CONFIG_SPL_FIT_SIGNATURE` in the Luckfox U-Boot
   defconfig work without further patching?~~ **Answered (2026-09):** it works, but with three
   non-obvious requirements the opt-in build now handles: (a) the in-build signing aborts with
   `ERROR: No keys/dev.key` unless `keys/dev.{key,pubkey,crt}` are present in the U-Boot tree —
   `SEEDSIGNER_FIT_SIGNATURE=1` drops the committed dev key there; (b) **`boot.img` is NOT signed
   by the SDK build** — `mk-fitimage.sh` packs it with the `dev` signature *template* and no `-k`,
   and nothing in `project/build.sh` signs it, so an enforcing U-Boot rejects it
   (`Failed to verify required signature 'key-dev'`). The build now signs it in place with the SDK's
   own `scripts/fit.sh --boot_img` (`sign_boot_image`); (c) a signed FIT means the kernel command
   line must be **baked into the signed DTB** (§6.6), because u-boot won't rewrite a signed FIT's
   `/chosen` at runtime. Separately, the standalone `rkbin/fit-sign.sh` *re-sign* flow is **not
   usable on this SDK** — it needs a `fit_signcfg/sign.readonly_config` (SPL/uboot checksums +
   `MINIALL.ini`) that this SDK never generates. Sign in-build instead.
4. Is the OTP public-key-hash region on RV1106 write-locked independently, and does burning it
   affect the OTP regions the `cpuinfo` driver reads?
5. ~~Can a fused board still enter Maskrom via the BOOT button, and does Maskrom accept an unsigned
   loader afterwards?~~ **Answered (2026-09-12, fused Mini):** the BOOT button still enters Maskrom
   on a fused board; an **unsigned** (wrong-key) image is **rejected** (won't boot or flash); a
   correctly **dev-key-signed** image flashes and boots. So recovery survives, but only with an
   image signed by the fused key — which, for the public dev key, anyone can produce.
6. Can `uboot.img` / `boot.img` be signed with upstream `mkimage -N pkcs11` against a hardware token
   instead of `rk_sign_tool si`, and does the resulting FIT still satisfy Rockchip's SPL
   verification? ([§5.2](#52-can-the-private-key-stay-on-a-smartcard--hsm))
7. ~~Does signing need to run before or after this repo's `normalise_boot_images()` pass, and does
   that pass invalidate a signature?~~ **Answered:** `boot.img` is signed after the firmware build
   but **before** `normalise_boot_images()`, which only rewrites `download.bin` and `update.img`
   (the live-clock stamps) and never touches the signed `uboot.img`/`boot.img` FITs — so it does not
   invalidate them. The loader/`uboot.img` are signed by the in-build `make.sh` FIT flow.
8. ~~What does `ss --extract` emit?~~ **Answered:** two bare 32-byte SHA-256 digests
   (`si_usb_head.bin`, `si_flash_head.bin`), signed with **RSA-PSS**. Still open: the exact file
   name and location `ss --inject` expects the signed data in — injection was not completed here
   ([§5.2](#52-can-the-private-key-stay-on-a-smartcard--hsm)).
8b. What are the correct `hsm_engine_id` / `hsm_private_key_id` values for a PKCS#11 token? Native
   HSM support exists in `setting.ini` and is the preferred route over extract/inject.
9. Is RSA-4096 accepted by the RV1106 BootROM for the loader, or is it 2048-only? `kk --bits 4096`
   generates a key, but that says nothing about what the ROM will verify ([§5.1](#51-generating-the-key)).
10. What do `mcr` (secondary cert) and `ss --cert` enable? If they support a root/delegate key
    hierarchy, that would allow the root key to stay permanently offline.
11. ~~Does `ss --version` drive the rollback index?~~ **Answered:** no — `fit-sign.sh` takes a
    separate `--rollback-index <img> <n>`, writes `rollback-index = <n>` into the ITS, and reads it
    back with `fdtget` to verify. It *errors out* if `CONFIG_SPL_FIT_ROLLBACK_PROTECT=y` and no
    index is given. `--version` is a distinct, non-OTP field.
12. ~~Are the ENVF partition's contents imported into the U-Boot environment?~~ **Answered: yes,
    but only the names in `CONFIG_ENVF_LIST`.** `bootdelay` and `cli` aren't on the list, so the CLI
    stays closed under `CONFIG_BOOTDELAY=-2`. `sys_bootargs`, `blkdevparts` and `mtdparts` are, and
    `sys_bootargs` gets merged into the kernel command line. Treat the env partition as
    attacker-controlled ([§6.6](#66-the-kernel-command-line-is-attacker-controlled)).
13. **Partly addressed.** On a *signed* build the kernel command line's `root=` (plus `ubi.mtd`,
    `rootfstype`, `rk_dma_heap_cma`) is now **baked into the signed DTB `/chosen`** by
    `apply_signed_nand_bootargs`, because u-boot won't rewrite a signed FIT's bootargs at runtime.
    This was found the hard way: the first fused build hung at `Waiting for root device
    /dev/mmcblk1p7` (the shared `ipc.dtsi` SD default) with 32M CMA, because the SDK's usual runtime
    injection of the NAND rootfs args is dropped for a signed FIT. Baking closes the accidental case
    and pins `root` inside the signed image — but `sys_bootargs` from the unsigned env is still
    merged *after* it, so an attacker could still append a later `root=`/`rdinit=`. Full lockdown
    still needs `CONFIG_CMDLINE_FORCE=y` (untested on this 5.10 kernel; must carry the *complete*
    line) or stripping `sys_bootargs`/`mtdparts` from `CONFIG_ENVF_LIST`.
14. **How should `boot.img` rollback be enforced without OP-TEE?** Stock U-Boot proper enforces a
    `boot.img` rollback index only through OP-TEE, and this build doesn't ship OP-TEE. There are two
    options. One is to patch U-Boot to compare the FIT `rollback-index` against a floor compiled
    into `uboot.img`; SPL protects `uboot.img` from rollback via OTP, so that floor can't be rolled
    back either. The other is to accept that raising the `boot.img` floor means re-signing
    `uboot.img` with a higher SPL index, which spends one of the 64 OTP increments each time. This
    is also one of the two reasons OP-TEE is now worth adopting ([§9](#9-op-tee)).
15. **Is there a spare region in RV1106 secure OTP** that an SPL patch could use for an on-die
    device secret ([§8.4](#84-where-the-device-secret-lives))? This is only relevant if OP-TEE is
    dropped. None of the documents reviewed has the RV1106 OTP map; the only known allocation is
    the rollback counter at `0xe0` (`OTP_UBOOT_ROLLBACK_OFFSET`, 8 bytes).
16. **Finish the air-gapped `.sign.rsa` encoding.** `rk_sign_tool`'s extract/inject flow is wired and
    validated (it emits bare 32-byte SHA-256 digests and reads a `<digest>.sign.rsa` back), but
    externally-produced signatures are still rejected as invalid. Evidence: the loader stores the
    pubkey N **little-endian** (offset 0x3bc), so the signature is almost certainly little-endian too,
    plus an unconfirmed PSS salt length. Cracking it enables signing on an **air-gapped SeedSigner**
    with a BIP85 key — see the bench doc's airgapped-signing section.
17. Does the RV1106 BootROM accept RSA-4096 for the loader, or is it 2048-only in silicon? The tool
    signs and verifies both; only a fused board settles it.

Questions 1–3, 5, 7, 8, 11, 12 and (partly) 13 are now answered — see the strikethroughs above and
[§13](#13-bench-test-results-rv1103-pico-mini). The open ones that gate a **production** deployment
are: a real (non-public) signing key and its custody (6, 8b, 10, 16), RSA-4096 in silicon (9/17),
rollback without OP-TEE (14), and — the big one — a **signed rootfs** ([§6](#6-extending-the-chain-to-the-rootfs)),
which is designed but unimplemented.

---

## 11. Reproducing the evidence

The FIT and DTB facts above were read out of build artifacts, not configuration. `dtc` is not
required — a FIT header is a flattened device tree and can be parsed with a short script.

```bash
python3 -c 'import re,struct,sys; d=open(sys.argv[1],"rb").read(); [print(m.start(), "totalsize", struct.unpack(">I", d[m.start()+4:m.start()+8])[0]) for m in re.finditer(b"\xd0\x0d\xfe\xed", d)]' boot.img
```

`boot.img` holds the FIT header at offset 0 and the kernel DTB at offset 2048. Walking the FDT
struct block from there yields the `/images/*` and `/configurations/conf/signature` properties
quoted in §3.2.

### 11.1 Reproducibility of a signed release

Examined 2026-09-12 with [`secure-boot/verify-fit-payloads.py`](../../opt/luckfox/secure-boot/verify-fit-payloads.py).
A signed `uboot.img` / `boot.img` is a ~2 KB FDT header (metadata + per-image sha256 + a 256-byte
RSA-PSS `/configurations/conf/signature/value`) followed by the image **data stored externally**
(`data-position` / `data-size`). Confirmed on the signed build: recomputing sha256 over each
external payload matches the stored `hash` node exactly, and the `kernel` payload hash equals the
value seen at boot on UART.

The consequence for reproducible releases: **every payload and all metadata in these two FITs is
key-independent — the only key-dependent bytes are the 256-byte `signature/value`, and the pubkey
isn't even in these FITs (it's in the loader's SPL DTB).** So a signed release can be verified as
"reproducible payloads + a detached signature": rebuild with the same config (the baked NAND
bootargs in the kernel DTB are part of the deterministic payload; the *key* is not), then
`verify-fit-payloads.py compare <release-image> <rebuilt-image>` must report every payload MATCH.
Authenticity (the 256-byte value) is checked separately against the published pubkey.

Two limits: the **loader** (`download.bin` / `idblock.img`) is not a plain FIT — its SPL DTB embeds
the pubkey + `burn-key-hash` + an `rk_sign_tool` signature as binary in a `boot_merger` blob
(pubkey N little-endian near `0x3bc`, §10 Q16), so stripping/comparing it needs the encoding that
question tracks. And **swapping** a FIT signature offline (re-sign the reproducible payload with a
different key, without a rebuild) is feasible for `uboot.img`/`boot.img` — recompute the data-to-sign
from the `hashed-nodes`/`hashed-strings` properties, RSA-PSS sign, splice `value` — but is not
implemented here, and the loader half is blocked on the same Q16 encoding.

---

## 12. References

- Rockchip Secure Boot Application Note V1.9 (2018-06)
- Rockchip Secure Boot for U-Boot Next Dev V2.3.0 (2021-04)
- Rockchip Crypto/HWRNG Developer Guide V1.2.1 — §2.2 HWRNG, §2.3 hardware crypto
- Rockchip OTP Developer Guide V1.4.0 — §3 Secure OTP zones
- Rockchip TEE SDK Developer Guide V1.10.0 — §3.3 TEE firmware, §10.2 memory, §13 OTP
- [`rockchip-linux/rkbin`](https://github.com/rockchip-linux/rkbin) — `tools/rk_sign_tool`,
  `doc/release/RV1106_EN.md`
- [README.md](README.md) — build process, read-only rootfs, boot recovery

---

## 13. Bench test results (RV1103 Pico Mini)

Run over ADB (Linux) and UART @ 115200 (U-Boot). §13 (below) is the unsigned baseline on the stock
`Luckfox_Pico_Mini_Flash_250607` image; [§13.1](#131-signed--fused-run-2026-09-12-committed-public-dev-key)
is the signed + fused run. Together they confirm the analysis above on real hardware.

| # | Test | Result | Bearing |
|---|---|---|---|
| A1 | Read `/sys/bus/nvmem/.../rockchip-otp0/nvmem` | 128 B, readable | OTP present |
| A1 | Write same node (`dd`) | **Permission denied** | Read-only from Linux, confirming §3.4 / §8.4 |
| A2 | `otp_id@0x0a` vs `/proc/cpuinfo` Serial | `M4T961...` vs `d6d9fb7e70873741` — **differ** | Serial is *derived*, not the raw cell (§8.3 corrected) |
| A3 | `hw_random/rng_current` | `rockchip` | Hardware TRNG bound |
| A3 | `[hwrng]` kthread | **running (pid 41)** | Kernel credits TRNG entropy — confirms `docs/hwrng.md` for Luckfox |
| A3 | `rngd` | **not running** | Stock image only; the SeedSigner build adds `rng-tools` |
| A4 | `mtd0` = "env" (256K), contains `sys_bootargs= ... root=ubi0:rootfs ...` | that string appears verbatim in `/proc/cmdline` | **§6.6 confirmed**: the unsigned env partition sets the kernel command line |
| B1 | Flood CTRL+C on UART during power-on (`bootdelay=0`) | **dropped to `=>` prompt** | §5.4 confirmed: `bootdelay=0` is interruptible; needs `-2` |
| B2 | `printenv` | `bootdelay=0`, `bootcmd=boot_fit;boot_android ...`, `sys_bootargs=...`; **no `cli`** | env carries `sys_bootargs`; `cli` absent (ENVF whitelist holds) |
| — | SPL/U-Boot log | `Verified-boot: 0`, `FIT: no signed, no conf required`, `sha256+ OK` | Baseline for Stage A: hashes are integrity-only, no signature enforced |

**Note on the boot medium:** this is a NAND Mini (`root=ubi0:rootfs`, `ubi.mtd=6`), not the SD
layout shown at sector 0 elsewhere in this doc. The `mtd0`→cmdline path is identical in mechanism.

### 13.1 Signed + fused run (2026-09-12, committed *public* dev key)

The full signed/fused chain was then exercised on a sacrificial Mini, built with
`SEEDSIGNER_FIT_SIGNATURE=1` (+ `SEEDSIGNER_FIT_BURN_KEY_HASH=1` for the burn). All confirmed on
UART:

| # | Test | Result | Bearing |
|---|---|---|---|
| C1 | Signed build, unfused, first boot | SPL: `sha256,rsa2048:dev … OK`; U-Boot: `FIT: signed, conf required`, `sha256,rsa2048:dev+ OK` | Whole chain (loader→`uboot.img`→`boot.img`) verifies; enforcement is live in software even before the fuse |
| C2 | `boot.img` **without** the extra sign step | `conf: sha256,rsa2048:dev- error! Failed to verify required signature 'key-dev'` → maskrom | The SDK does **not** sign `boot.img`; it must be signed in-build (§10 Q3). Fixed by `sign_boot_image` |
| C3 | Burn (armed loader, first boot) | `## spl…dtb: burn-key-hash=1` at build; `RSA: Write RSA key hash successfully.` at SPL | The OTP fuse is written via the FIT `--burn-key-hash` path — RV1106 secure boot confirmed |
| C4 | Fused board, unsigned/old image | **rejected** — won't boot or flash | Enforcement confirmed: BootROM checks the loader against the burned hash |
| C5 | Fused board, dev-key-signed image | flashes and boots | The fused key accepts correctly signed images |
| C6 | Fused board, BOOT button | enters **Maskrom** | Recovery path survives the fuse (§10 Q5) |
| C7 | First signed NAND build to userspace | hung at `Waiting for root device /dev/mmcblk1p7`, 32M CMA | Signed FIT uses the DTB's baked `/chosen` (SD default); NAND rootfs args must be baked in (§10 Q13). Fixed by `apply_signed_nand_bootargs` |

**Confirmed answered by this run:** open questions 2, 3, 5, 7 and (partly) 13. RV1106 secure boot
works end-to-end. **Still not done:** a real (non-public) signing key, RSA-4096 in silicon, and a
signed rootfs ([§6](#6-extending-the-chain-to-the-rootfs) — the chain still stops at `boot.img`).
- [`docs/hwrng.md`](../hwrng.md) — how hardware entropy reaches the app on each platform
