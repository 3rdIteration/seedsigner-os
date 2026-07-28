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

## Build variants — dev vs non-dev

The `build_variant` workflow input (choice; `non-dev` or `dev`) selects a hardened production image vs a
debuggable one. **Automatic push/PR CI always builds `dev`** (it validates the full debuggable stack); a
manual "Run workflow" defaults to `non-dev` (pick `dev` to override). Local builds set the same thing via
`SEEDSIGNER_BUILD_VARIANT=dev|non-dev` (default `non-dev`).

For the serial console specifically, the `disable_uart2_console_debug` input defaults to `auto` (follow the
variant: non-dev strips it, dev keeps it); force it with `true`/`false`.

The Luckfox implementation differs from the Pi / La Frite profiles (which have parallel `-dev`/non-dev profile
directories). Luckfox is the Rockchip SDK with a single defconfig + an SDK-provided rootfs, so **non-dev is a
set of build-time hardening steps gated on the flag**, not a second profile tree. It maps to the AGENTS.md
[non-dev leak-vector table](../../AGENTS.md#non-dev-hardening-no-information-leakage) like so (Luckfox has no
HDMI; its "networking" vector is the USB gadget, not Ethernet/WiFi):

| Vector | non-dev closes it via | Where |
|---|---|---|
| Kernel serial console | strip `console=ttyFIQ0`/`earlycon`/`user_debug` bootargs (forced on for non-dev; the `disable_uart2_console_debug` input is the dev override) | build-luckfox.yml "Configure UART2 console debug" |
| Serial **login** (getty) | `# BR2_TARGET_GENERIC_GETTY is not set` in the defconfig **and** comment console/tty getty/login/shell `respawn` lines in the rootfs `/etc/inittab` | defconfig sed + `harden-nondev.sh` |
| **Networking** (USB ADB + RNDIS) | remove `adbd`/`usbdevice` binaries, `/etc/init.d/S*usb*`, and comment gadget/adb invocations in `RkLunch.sh` → no `adb shell`, no `usb0` | `harden-nondev.sh` |
| Logging daemons | remove `syslogd`/`klogd` autostart | `harden-nondev.sh` |
| Dev / network CLI tools | drop `python-pip`, `wget`, `libcurl`/curl from the target | defconfig sed |

The rootfs surgery lives in **`opt/luckfox/harden-nondev.sh <ROOTFS_DIR>`** (called from all three build
implementations). Because the SDK rootfs layout varies by version, every step is **guarded/no-op if the
target is absent** and logs each file it did/didn't touch. **A green build does not prove the vectors were
closed** — review the `[harden]` log lines, and verify on hardware / a serial capture (no console output or
login prompt; `adb devices` and `usb0` absent; no `syslogd`/`klogd`; `which pip curl wget` empty; the app
still works). The reboot-to-Loader Power option / `rk-reboot` is retained in **both** variants.

### Non-dev size / boot optimizations

Non-dev images also get size and boot tweaks (dev keeps SDK defaults). Companion script
**`opt/luckfox/optimize-nondev.sh <ROOTFS_DIR>`** runs right after `harden-nondev.sh`:

| Tweak | What / where | Notes |
|---|---|---|
| Optimize for size | defconfig `BR2_OPTIMIZE_3=y` → `BR2_OPTIMIZE_S=y` | smaller binaries, marginally slower |
| Prune test/metadata | remove `tests/`, `*.dist-info`/`*.egg-info` under site-packages + `/opt/src`, and `/opt/tools` | `optimize-nondev.sh` |
| Prune camera iqfiles | keep only the board's sensor (`IQFILES_KEEP`), remove the rest from `/oem` | `optimize-nondev.sh`; **verify camera** |
| Quiet boot | append `quiet loglevel=3` to the DTS `bootargs` | marginal once console is stripped |
| U-Boot bootdelay | zero any non-zero `CONFIG_BOOTDELAY`/`bootdelay=` in the SDK U-Boot | best-effort, guarded |
| UI-first camera | `optimize-nondev.sh` drops `/etc/seedsigner-nondev`; `start-seedsigner.sh` then backgrounds the ~4s camera-graph bootstrap so the UI comes up first | **experimental — verify camera on hardware** |

Same discipline as hardening: everything keys off `build_variant=non-dev`, is guarded/no-op when the SDK
target isn't present, and logs under `[optimize]`. **iqfiles pruning and the UI-first camera reorder must be
verified on real hardware** (scan a QR) — a green build proves nothing about the camera. Both are trivially
revertible (widen `IQFILES_KEEP`; the reorder only triggers when the `/etc/seedsigner-nondev` marker exists).

## Boot recovery & auto-failover to Loader

So a bad image self-heals into a flashable state without the BOOT button:
- **KEY3 very-long-press on Home** (both variants, Luckfox only): hold KEY3 ~5 s on the home screen to reboot
  into rockusb Loader mode — same action as the Power menu's "Reboot to flash mode". A short KEY3 tap still
  selects. Implemented in the app (`MainMenuScreen`/`RebootToLoaderView`).
- **Startup watchdog** (`start-seedsigner.sh`, both variants): the app writes `/tmp/seedsigner-ready` when it
  reaches Home; if that never appears within ~120 s, or the launch retry loop is exhausted, the device reboots
  into Loader mode. Covers the app-crash and app-hang cases.
- **`panic=5`** (non-dev bootargs): a kernel panic reboots instead of hanging, giving the failover another
  shot. Dev keeps panics visible for debugging.
- **ADB for debugging:** ADB is **left enabled on non-dev** for now (`adb shell` → read `/tmp/startup.log`).
  Re-harden later by building the non-dev image with `HARDEN_DISABLE_ADB=1`.

**U-Boot boot-counter (follow-up, needs device info).** For kernel/init failures the userspace watchdog can't
catch, the plan is a U-Boot bootcount: `CONFIG_BOOTCOUNT_LIMIT` + `altbootcmd` that enters rockusb after
`bootlimit` failed boots, reset from userspace once the app is up. The app already calls
`fw_setenv bootcount 0` on ready and `u-boot-tools` is installed; what remains is `/etc/fw_env.config` with the
**actual env-partition offset** (read it from the device now that ADB is back:
`cat /proc/mtd`, and the SDK U-Boot `env` offset) plus verifying the SDK U-Boot supports bootcount. Left
disabled until verified so it can never break normal boot.

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
