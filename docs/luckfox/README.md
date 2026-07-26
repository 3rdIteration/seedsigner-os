# Luckfox Pico — build & development

SeedSigner OS supports the Luckfox Pico board family (Rockchip **RV1103 / RV1106**) alongside the Raspberry
Pi / La Frite targets. Unlike the Pi builds (mainline Buildroot via the `opt/buildroot` submodule), the
Luckfox build drives the **Rockchip Luckfox Pico vendor SDK** (cloned at build time) and injects the
SeedSigner packages, defconfig, rootfs files and patches into it. Everything Luckfox-specific lives under
**`opt/luckfox/`**.

> Some deeper docs in this folder (e.g. [`OS-build-instructions.md`](OS-build-instructions.md),
> [`TOOLCHAIN_ANALYSIS.md`](TOOLCHAIN_ANALYSIS.md)) were carried over from the original standalone
> `seedsigner-luckfox-pico` repo and may still describe the old `buildroot/` layout. The commands below are
> the current ones for this repo.

## Hardware targets

| Model | SoC | Boot media |
|---|---|---|
| Luckfox Pico Mini | RV1103 | `SD_CARD`, `SPI_NAND` |
| Luckfox Pico Pro Max | RV1106 | `SD_CARD`, `SPI_NAND` |
| Luckfox Pico Pi | RV1106 | `EMMC` |

## Building

### GitHub Actions (recommended)

`.github/workflows/build-luckfox.yml` — **"Build SeedSigner OS (Luckfox Pico)"**. Run it from the Actions tab
(or `gh workflow run`) choosing `hardware_type`, `boot_medium`, and `seedsigner_branch` (the app branch to
build). Specific inputs build a single combo; a push builds the full matrix. It is also a **reusable
workflow** — the seedsigner app repo's "Build Luckfox" workflow calls it to build an image from an app branch.

### Local — Docker

From a checkout, use the repo-root dispatcher:

```bash
./build.sh --luckfox build --microsd --model mini    # or --nand ; --model max|both
```

(equivalently `opt/luckfox/build.sh build --microsd`). Artifacts land in `opt/luckfox/build-output/`.

### Local — no Docker (Ubuntu 22.04)

```bash
opt/luckfox/build-local.sh --check-deps                 # first time: install deps
opt/luckfox/build-local.sh --hardware mini --boot nand
```

## How the build works (dev process)

1. Clone the Rockchip **Luckfox Pico SDK** (`3rdIteration/luckfox-pico`) — brings U-Boot, the kernel, and its
   own Buildroot.
2. Apply SDK patches (partition tables, UART2 console, HWRNG/crypto, Rust-on-uClibc) — mostly in-line
   `sed`/append fragments against the SDK's board configs, DTS and kernel defconfig.
3. Inject SeedSigner packages: copy `opt/external-packages/*` into the SDK Buildroot's `package/` and append a
   `menu "SeedSigner"` block that `source`s each custom package's `Config.in`. **Two-place rule:** a custom
   package needs *both* the menu `source` line *and* a `BR2_PACKAGE_*=y` in
   `opt/luckfox/configs/luckfox_pico_defconfig`. See the canonical package set in
   [`AGENTS.md`](../../AGENTS.md#seedsigner-package-set-per-platform).
4. Copy the SeedSigner app source + rootfs files (`opt/luckfox/files/*`), set the hostname to `seedsigner-os`,
   and generate the identity/provenance marker **`/etc/seedsigner-os-release`** (repo/branch/commit/date for
   both seedsigner-os and the app — surfaced in the app's System Info screen).
5. Build and package the SD / NAND / eMMC images.

**Three build implementations duplicate this logic and must be kept in sync:**
`.github/workflows/build-luckfox.yml` (authoritative), `opt/luckfox/os-build.sh` (in the Docker build), and
`opt/luckfox/build-local.sh` (no-Docker). The toolchain is uClibc
(`arm-rockchip830-linux-uclibcgnueabihf`, ARMv7); note `python-numpy` is not buildable there (the app
tolerates its absence).

## Flashing & recovery — Loader / Maskrom mode

To re-flash with the Rockchip **SocToolKit** or `rkdeveloptool` you normally hold the **BOOT** button while
powering on to enter a download mode. You can instead trigger it from the running device over the shell.

**Loader (rockusb) mode** — sufficient to re-flash a device whose U-Boot still boots:

```bash
rk-reboot loader
```

`rk-reboot` (in `/usr/bin`) issues the real `reboot(2)` `RESTART2` syscall. Busybox's own `reboot loader` is a
**no-op** because it ignores the mode argument. After this the device reboots and enumerates on the host as a
Rockchip **Loader** device, ready for flashing.

On an **older image that predates `rk-reboot`**, run the same syscall inline (python3 is always present):

```bash
python3 -c 'import ctypes; ctypes.CDLL(None).syscall(88, 0xfee1dead, 0x28121969, 0xa1b2c3d4, b"loader")'
```

Pure-shell fallback (write the loader magic to the GRF OS_REG, then warm-reset):

```bash
busybox devmem 0xFF020200 32 0x5242C301 && reboot -f
```

Notes:
- A **cold power-cycle clears the flag**, so entering Loader mode is safe to try — just unplug/replug to boot
  normally if you change your mind.
- **Maskrom** (BootROM USB download — needed only for a bricked/blank device or to rewrite the loader itself)
  is **not enabled yet**: it requires adding a device-tree `mode-maskrom = <0xef08a53c>` entry to the board DTS
  plus a firmware rebuild. The physical **BOOT button remains the guaranteed fallback** for maskrom.

## Other reference docs in this folder

- [OS-build-instructions.md](OS-build-instructions.md) — detailed manual SDK build steps (original standalone layout).
- [LUCKFOX_STARTUP_WORKFLOW.md](LUCKFOX_STARTUP_WORKFLOW.md) — on-device startup / camera sequencing.
- [BUILD_REFERENCE.md](BUILD_REFERENCE.md), [TOOLCHAIN_ANALYSIS.md](TOOLCHAIN_ANALYSIS.md),
  [SMARTCARD_PACKAGES.md](SMARTCARD_PACKAGES.md), [CAMERA_SERVICE_PLANNING.md](CAMERA_SERVICE_PLANNING.md).
