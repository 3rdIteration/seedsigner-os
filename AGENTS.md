# SeedSigner OS — Agent Guidelines

## Deterministic & Reproducible Builds (Non-Dev Configs)

Non-dev builds (`pi0-smartcard`, `pi2-smartcard`, `pi4-smartcard`, etc.) are designed to be **deterministic and reproducible**. This means:

* Every build from the same commit must produce byte-identical output images.
* All external assets (firmware, pre-built OS images, tool archives) are downloaded by URL and verified against a hardcoded SHA-256 checksum.
* Never introduce non-deterministic behaviour into post-image or post-build scripts: no timestamps embedded in files, no random data, no host-dependent paths leaking into the image.
* When adding new downloads to a script, always include both the download step **and** a `sha256sum` verification (use the existing `download_and_verify()` helper where available).
* If a change affects only `-dev` configs, keep it out of non-dev scripts entirely.

## Local Testing of Scripts

Wherever possible, validate script changes locally before pushing to CI. The full buildroot build takes 1–2 hours per board; many failures can be caught in seconds with synthetic test data.

### Post-Image / Post-Build Scripts

These scripts operate on disk images produced by `genimage`. You can reproduce their environment without a full build:

1. **Create a synthetic disk image** matching the genimage layout (MBR + FAT32 partition):
   ```bash
   dd if=/dev/zero of=test.img bs=1M count=256 status=none
   sfdisk test.img <<EOF
   label: dos
   unit: sectors
   test.img1 : start=2048, size=204800, type=c
   EOF
   # Format the partition in-place at the correct offset
   dd if=/dev/zero of=boot.vfat bs=512 count=204800 status=none
   mkfs.vfat -n "SEEDSIGNDEV" boot.vfat >/dev/null 2>&1
   dd if=boot.vfat of=test.img bs=512 seek=2048 conv=notrunc status=none
   ```

2. **Extract the partition offset** from the MBR (byte 454, little-endian uint32):
   ```bash
   python3 -c "import struct; print(struct.unpack('<I', open('test.img','rb').read()[454:458])[0] * 512)"
   # → 1048576 (sector 2048 × 512)
   ```

3. **Run the mtools commands** from the script against the synthetic image and verify they succeed or fail as expected:
   ```bash
   MTOOLS_SKIP_CHECK=1 mmd -i "test.img@@1048576" ::javacard-cap
   MTOOLS_SKIP_CHECK=1 mdir -i "test.img@@1048576" ::/
   ```

4. **Negative tests** are equally important — verify that known-bad syntaxes (`::1`, `:p1`, bare image) fail as expected, so regressions are caught early.

See `tests/test_post_image_mtools.sh` for a working example that exercises all five post-image scripts against a synthetic image in under a second.

### Custom Module Downloads & Hash Checks

When a script downloads external assets:
* Verify the SHA-256 checksum matches what you expect by downloading the file locally first and running `sha256sum`.
* If the upstream changes the hash (e.g., a new release), update the constant in the script — never skip verification.

### Buildroot Post-Build / Post-Install Scripts

These run inside the buildroot container with `$TARGET_DIR`, `$STAGING_DIR`, etc. set. To test locally:
* Set the variables to local paths pointing at a minimal rootfs or empty directory.
* Source the script and step through it, checking that file operations target the right locations.

> **Commit scripts as executable (mode `100755`).** Buildroot invokes `BR2_ROOTFS_POST_BUILD_SCRIPT` and `BR2_ROOTFS_POST_IMAGE_SCRIPT` directly (not via `sh <script>`), so a script committed non-executable (`100644`) fails `target-finalize` with exit code **126**. This is easy to miss when authoring on Windows, where the working tree doesn't carry a Unix exec bit. Set it explicitly and verify what git recorded:
> ```sh
> git update-index --chmod=+x opt/<profile>/board/post-build.sh opt/<profile>/board/post-image-seedsigner.sh
> git ls-files -s opt/<profile>/board/*.sh   # each must show mode 100755
> ```

### General Principles

* **Fail fast**: if a tool is missing (e.g., `mtools`, `sfdisk`), skip with a clear message rather than silently passing.
* **Clean up**: use `trap cleanup EXIT` to remove temp directories on failure.
* **Pin versions**: when tests depend on external tools, note the expected version or behaviour so changes in tooling don't silently break things.

## Build Profile Conventions

Profiles are located under `opt/{profile-name}/`. Full documentation is in [docs/build_profiles.md](docs/build_profiles.md).

### Naming Pattern

`{board}[-smartcard][-dev]` — e.g. `pi0-smartcard`, `lafrite-smartcard-dev`.

- **`-smartcard`**: Adds NFC reader stack (`libnfc-pn532-i2c`, `ccid`, `ifdnfc`, `openct`), JavaCard crypto tools (`gnupg2`, `pycryptodome-x`, `pysatochip`), and DIY tools squashfs (Java JDK + Ant + Satochip source) on the boot partition.
- **`-dev`**: Adds networking (SSH via dropbear, git, curl, wget, pip, WiFi tools, DHCP). Uses `genimage` for image creation (non-reproducible). Includes `rootfs-overlay-dev/` for MicroSD source override.

### What Changes Between Dev and Non-Dev

| Level | Dev | Non-Dev |
|-------|-----|---------|
| **defconfig** | +dropbear, git, curl, wget, pip, wifi tools, DHCP, nano, mc | Minimal packages only |
| **busybox.config** | Networking applets enabled (ifconfig, ip, ping, udhcpc, wget) | All networking applets disabled |
| **kernel config** | INET, IPV6, NETDEVICES, DRM, FRAMEBUFFER_CONSOLE enabled | All disabled (air-gapped, no display output) |
| **post-build.sh** | Copies `rootfs-overlay-dev/` into target | No dev overlay copy |
| **post-image script** | Uses `genimage` (non-reproducible) | Manual deterministic: dd + sfdisk + mkfs.vfat --invariant + mcopy, fixed timestamps (`2023/01/01T12:15:05`), pinned bootloader SHA-256 |

### Non-Dev Hardening (no information leakage)

Non-dev (production) images are **air-gapped and headless by design** — they must not emit or accept anything over networking, HDMI, or serial. Every vector below must be closed; a profile can build green with any of them left open, and several only surface on real hardware (or a serial capture), so verify there — not just from a green CI run.

| Leak vector | How it's closed (non-dev) | Where |
|---|---|---|
| **Networking** | `CONFIG_INET`/`IPV6`/`NETDEVICES`/`PACKET` off; no dropbear / wifi / dhcp / curl packages | kernel config + defconfig |
| **HDMI / video console** | `CONFIG_DRM`/`FB`/`FRAMEBUFFER_CONSOLE` off (the UI LCD is SPI/userspace, unaffected) | kernel config |
| **Kernel serial console** | no `console=<serial>`, no `earlyprintk`; route the console to a null sink via `console=ttynull` + `CONFIG_NULL_TTY=y` | cmdline (`boot_cmdline.txt` / `extlinux.conf`) + kernel config |
| **Serial login prompt** | `# BR2_TARGET_GENERIC_GETTY is not set` (no getty on any tty) | defconfig |
| **System logging daemons** | `post-build.sh` removes `S01syslogd` / `S02klogd` | post-build.sh |

**Luckfox Pico closes the same vectors differently** (Rockchip SDK; no HDMI; its extra vectors are the USB
gadget and — on Pro Max / Pico Pi — Ethernet). All of it lives in shared `opt/luckfox/*.sh` scripts called
identically by CI (`build-luckfox.yml`) and both local Docker builds (`os-build.sh`, `build-local.sh`) —
change the script, never one caller.

**Threat model: root-level code execution.** The app runs as root, so *userspace* hardening is not a control
on its own — root can just `ifconfig eth0 up; udhcpc` or `insmod` a driver. Anything that must actually hold
is removed from the **kernel**; the userspace steps remain as defence in depth against accidental exposure
and non-root paths. (Running the app unprivileged is separate, planned work — it shrinks blast radius but
does not replace the kernel controls, since a privesc or any root component such as `pcscd` would restore
them.) **The oem partition is part of the attack surface too** — every built `.ko` is packaged to
`/oem/usr/ko`, and no rootfs hardening touches it.

| Leak vector (Luckfox) | How it's closed (non-dev) | Where |
|---|---|---|
| **Networking (kernel)** | `INET`/`PACKET`/`IPV6`/`NETDEVICES` off, plus the Ethernet MAC+PHY (`STMMAC_ETH`, `RK630_PHY`) and `USB_CONFIGFS_RNDIS`. Root cannot create an interface or open an AF_INET socket — the stack isn't compiled in. Gated on `debug_network=off`; `debug_network=on` keeps Ethernet+telnet for debugging (never ship it) | `strip-kernel-network.sh` (Group A) |
| **WiFi (kernel)** | `WL_ROCKCHIP` (the umbrella that `select`s CFG80211+MAC80211 and sources every vendor WiFi Kconfig) + `RTL8723BS` off, so the 802.11 stack and all 8 vendor drivers are never built and cannot land in `/oem/usr/ko` to be `insmod`ed. Always stripped on non-dev — the debug channel is wired Ethernet | `strip-kernel-network.sh` (Group B) |
| **Networking (userspace, defence in depth)** | No interface bring-up (`S*network*` → loopback-only stub), DHCP neutered, `/etc/network/interfaces` = `lo` only, telnet/ssh/dropbear init scripts removed (`HARDEN_DISABLE_NETWORK`) | `harden-nondev.sh` §4 |
| **USB gadget (adb/RNDIS)** | DTS `&usbdrd_dwc3 { dr_mode = "host"; }` (`usb_mode` auto→host): dwc3 registers host-only, so **`/sys/class/udc/` is empty and a configfs gadget has nothing to bind to** — root cannot re-enable adb at runtime. Plus adb userspace stripped (`HARDEN_DISABLE_ADB=1`) | `configure-usb-mode.sh`, `harden-nondev.sh` §2, `patch-s50usbdevice.sh` |
| **Kernel serial console** | UART2 console stripped from bootargs/DTS (`disable_uart2_console_debug` auto→on) | UART2 strip steps in all three builds |
| **Serial login prompt** | getty/login/sulogin inittab respawn lines commented (console shells left intact — the app boot path uses one) | `harden-nondev.sh` §1 |
| **System logging daemons** | syslogd/klogd init scripts removed + launches commented | `harden-nondev.sh` §3 |
| **Boot recovery** | memory-backed U-Boot bootcount → rockusb Loader failover (no serial/adb needed to recover a brick) | `uboot-recovery-config.sh` |

**Three kernel symbols must never be disabled** (each has bitten us or would break the device):
`CONFIG_NET`/`CONFIG_UNIX` — `pcscd` uses an AF_UNIX socket, so dropping `NET` kills smartcards;
`CONFIG_MODULES` — the camera drivers are `=m`; `CONFIG_USB_GADGET` — it is the *sole* provider of configfs
(`USB_CONFIGFS` → `USB_LIBCOMPOSITE` → `select CONFIGFS_FS`), and without configfs `luckfox-config` cannot
create the device-tree overlays that enable SPI0, so **the display dies**. ADB is blocked by `dr_mode=host`
instead. `strip-kernel-network.sh` refuses to run if any of them is off.

**Verify against the generated `.config`, never the defconfig.** Kconfig silently drops defconfig lines whose
symbol doesn't exist or whose dependencies are unmet — this is exactly how the first U-Boot bootcount attempt
shipped green with zero bootcount code. `assert-kernel-network.sh` re-checks the built kernel config (plus a
`CONFIGFS_FS=y` display canary and the oem `.ko` payload) and fails the build.

**The Luckfox boot watchdog couples the image to the app ref.** `start-seedsigner.sh` reboots into Loader
120 s after app start unless the app writes `/tmp/seedsigner-ready` (`signal_app_alive()`, app commit
`689483af`+, i.e. the `generalized-platform-detection` branch — `dev` and all tags lack it). A signal-less
app builds green, boots looking healthy, and Loader-loops on every boot, so all three build paths run
`assert-app-watchdog-signal.sh` after the app clone/reuse decision and **fail the build** when it's absent
(escape hatch: `SEEDSIGNER_ALLOW_NO_WATCHDOG_SIGNAL=1`). Relatedly, since the read-only rootfs can never
cache `__pycache__` at runtime, all three paths also run `precompile-bytecode.sh` after staging the app
(discovered target-python `compileall.py`, version-matched host interpreter, deterministic flags) over
`/opt/src` and `site-packages` — the same treatment Pi profiles have always given the app in post-build.

**Silencing the serial console differs by platform** — get this right per-board:
- **Pi**: the firmware (`boot_config.txt`) doesn't route the console to the UART, so the cmdline simply omits `console=`. That also frees `/dev/ttyAMA0` (via `dtoverlay=disable-bt`) for the SEC1210 reader, which shares that UART — here serial output would actively break the reader.
- **Lafrite**: the DTS sets `chosen/stdout-path = "serial0"` (`ttyAML0`), so **omitting `console=` is not enough** — the DT still routes the console to serial. Pass `console=ttynull` explicitly (a cmdline `console=` sets `console_set_on_cmdline`, which makes the kernel ignore the DT stdout-path), and provide `ttynull` via `CONFIG_NULL_TTY=y`. The SEC1210 reader is on a *separate* UART (`/dev/ttyAML6`), so console and reader don't collide as on the Pi — but the console is still silenced to meet the no-leak requirement.

### Kernel Config Approaches by Platform

- **Pi profiles**: Full `kernel.config` files. Dev configs add networking/display options at the bottom of an otherwise identical base config. Non-dev configs strip them out.
- **Lafrite profile**: Uses `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` with a kernel fragment (`kernel-fragment.config`). The arm64 arch default builds many drivers as **modules**, and the initramfs has **no on-disk module tree**, so every driver the device needs must be forced `=y` in the fragment: serial, MMC, SPI (the LCD), HW RNG, **and USB host + UVC (`USB_XHCI_HCD`, `USB_DWC3`, `USB_VIDEO_CLASS`, `MEDIA_*`, `VIDEOBUF2_*`) — the La Frite camera is USB (`/dev/video1`)**. Build the non-dev fragment as *dev fragment minus networking*: keep all the hardware `=y` forcing, and only add the non-dev disables (INET, IPV6, NETDEVICES, PACKET, and optionally DRM/FB/FRAMEBUFFER_CONSOLE — the LCD is SPI/userspace and needs none of them). Dropping a required `=y` driver builds fine but leaves that hardware dead at runtime (e.g. no camera).

### Rootfs Overlay Structure

Three distinct overlays — do not confuse them:

- **`opt/rootfs-overlay/`** (top-level, shared by ALL profiles) — the SeedSigner userspace: the app at `/opt/src`, `/etc/init.d/S02seedsigner`, `/etc/fstab`, and **`/start.sh`** (the launcher that `S02seedsigner` runs). **Every profile's `BR2_ROOTFS_OVERLAY` must list this overlay.**
- **`<profile>/board/rootfs-overlay/`** (per-profile) — hardware config only (mdev.conf, reader.conf.d).
- **`opt/rootfs-overlay-dev/`** (dev-only) — networking + a MicroSD-source-override `start.sh` that *overrides* the shared `/start.sh`. Copied by dev profiles' `post-build.sh`; absent in non-dev, so non-dev uses the shared headless `/start.sh`.

> **`BR2_ROOTFS_OVERLAY` must include the shared overlay.** Set it to `"../rootfs-overlay/ ../<profile>/board/rootfs-overlay/"` (shared first, board second), matching `lafrite-smartcard-dev`. If you list only the board overlay, the app, init scripts, and `/start.sh` are all missing — **the build still succeeds, but the booted image never launches SeedSigner (blank screen).** This is only detectable by actually booting the image, so verify it on hardware (or via the serial console) before assuming a green build works.

### Image Creation Methods

- **Dev**: `genimage` with `genimage-seedsigner.cfg`. Fast, but embeds build-time metadata (non-reproducible).
- **Non-dev**: Manual script that creates disk image via dd, partitions with sfdisk (fixed label-id `ba5eba11`), formats FAT32 with `mkfs.vfat --invariant`, copies files via mcopy with normalized timestamps. Produces byte-identical output across builds.

### Adding a New Profile

When creating a new profile (e.g. `lafrite-smartcard` from `lafrite-smartcard-dev`):
1. Copy hardware files unchanged: extlinux.conf, boot.cmd, DTS, genimage-diy-tools.cfg, rootfs-overlay, Config.in, external.mk
2. Create defconfig: remove dev packages, update paths to the new profile name. **`BR2_ROOTFS_OVERLAY` must list the shared overlay AND the board overlay** — `"../rootfs-overlay/ ../<profile>/board/rootfs-overlay/"` (see [Rootfs Overlay Structure](#rootfs-overlay-structure)); omitting `../rootfs-overlay/` produces a blank-screen image that still builds green.
3. Create post-build.sh: adapt from existing non-dev profile for the target architecture (armhf vs aarch64)
4. Create busybox.config: copy from equivalent non-dev profile (minimal networking)
5. Create kernel config or fragment: force `=y` every hardware driver the device needs (serial, MMC, SPI, HW RNG, **and USB + UVC for USB-camera boards** — modules in the arch default won't load with no initramfs module tree), keeping parity with the dev fragment; then add only the non-dev disables (INET, IPV6, NETDEVICES, PACKET, optionally DRM/FB/FRAMEBUFFER_CONSOLE). See [Kernel Config Approaches by Platform](#kernel-config-approaches-by-platform).
6. Create post-image script: deterministic manual approach with pinned bootloader SHA-256
7. Update external.desc: keep buildroot's `key: value` format with a `name:` line (all profiles use `name: RPI_SEEDSIGNER`, referenced by `external.mk` as `BR2_EXTERNAL_RPI_SEEDSIGNER_PATH`); remove "Dev" from the `desc:`. A missing `name:` aborts the build with "external.desc does not define the name".
8. Set the executable bit on `post-build.sh` and the post-image script and confirm it before committing (see the note under [Buildroot Post-Build / Post-Install Scripts](#buildroot-post-build--post-install-scripts)). Non-executable scripts fail at `target-finalize` with exit code 126.
9. Confirm every leak vector is closed for non-dev — networking, HDMI, kernel serial console (`console=ttynull`), serial login getty, logging daemons (see [Non-Dev Hardening](#non-dev-hardening-no-information-leakage)). These build green when left open, so verify on hardware or a serial capture.

## SeedSigner package set (per platform)

This is the canonical list of Buildroot packages a SeedSigner OS image should enable, so a new/updated
platform build does not silently fall behind (this list exists because the Luckfox defconfig had drifted from
the Pi set). Keep it in sync when the app gains a dependency.

**How packages are enabled differs by platform family:**
* **Raspberry Pi / La Frite:** per-board defconfig `opt/<board>/configs/<board>_defconfig` over the
  `opt/buildroot` submodule; custom packages live in `opt/external-packages/` and are wired via each board's
  `Config.in`/`external.mk`.
* **Luckfox Pico:** `opt/luckfox/configs/luckfox_pico_defconfig` copied into the vendor SDK's Buildroot, plus an
  injected `menu "SeedSigner"` block that `source`s each custom package's `Config.in`. **Two-place rule:** a
  custom `opt/external-packages` package needs BOTH a `source "package/<name>/Config.in"` line in that menu
  block (in all three build implementations: `.github/workflows/build-luckfox.yml`, `opt/luckfox/os-build.sh`,
  `opt/luckfox/build-local.sh`) AND a `BR2_PACKAGE_*=y` in the defconfig — the defconfig line alone is silently
  dropped for a package the menu doesn't source.

**Core app — required on every platform:**
`python3` (+`_SSL`, `_BZIP2`), `python-embit`, `python-urtypes`, `python-mnemonic`, `python-shamir-mnemonic`,
`python-ecdsa`, `python-pyaes`, `python-pyasn1`, `python-pycryptodomex`, `python-ndeflib`; QR/imaging:
`python-pyzbar`, `zbar`, `python-qrcode`, `python-pyqrcode`, `python-pillow` (Pi uses `python-pillow-ep`),
`freetype`, `libraqm`, `jpeg`/`jpeg-turbo`, `libpng`.

**Smartcard / hardware-wallet features — all platforms:**
`python-pyscard`, `python-pysatochip`, `python-pgpy`, `python-keycard-py`, `python-specter-card`,
`python-pygp`, `ccid-sec1210`, `pcsc-lite`, `gnupg2`, `pinentry`.

**Single-version rule:** every external package in `opt/external-packages/` pins ONE version for all
toolchains/platforms — never `ifeq (BR2_TOOLCHAIN_USES_UCLIBC…)` version splits in a `.mk` or
`select … if BR2_TOOLCHAIN_USES_UCLIBC` dependency splits in a `Config.in`. Toolchain compatibility is
handled *inside* the package source (e.g. pysatochip's OpenSSL→pycryptodomex fallback). Rationale: the
Luckfox NDEF regression happened because uClibc pinned an older pysatochip (`0.5-alpha-pycryptodome`)
than glibc (`0.6a`), so app code calling `card_get_ndef()` crashed only on Luckfox. `python-cryptography`
(Rust) builds on uClibc now (Tier-3 Rust target patch), so the old reason for the splits is gone. A
version bump requires a rebuild on every platform.

**Optional peripherals:** `python-smbus2` (or `python-smbus-cffi`), `python-periphery`, `python-spidev`
(battery HAT / IO; the app imports these behind `try/except`).

**Platform-specific — do NOT cross-port:**
* Camera — Pi: `libcamera` + `python-picamera2` (+`python-picamera`). Luckfox: Rockchip ISP
  (`rkaiq-service`, `nv12_converter`), **no** libcamera.
* GPIO — Pi: `python-pigpio` / `python-rpi-gpio` / `bcm2835`. Luckfox: `libgpiod`.
* `python-numpy` — glibc (Pi) only; **not buildable on the Luckfox uClibc toolchain** (the app tolerates its
  absence — the numpy preload is guarded).

**Currently excluded on all platforms:** the NFC *reader* hardware stack (`nfc-bindings`, `libnfc`, `ifdnfc`)
and `openct`. (`python-ndeflib` is the pure-Python NDEF *format* library and IS included — it pulls none of
that native stack.)
