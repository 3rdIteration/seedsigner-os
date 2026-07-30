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
- **ADB for debugging:** non-dev images **disable ADB by default** (air-gapped). For a debuggable non-dev
  build, dispatch with the **`disable_adb=false`** input (or set `HARDEN_DISABLE_ADB=0` for a local build) —
  then `adb shell` → read `/tmp/startup.log`. Dev builds always keep ADB. Removing ADB does **not** weaken
  recovery: rockusb **Loader mode is a U-Boot/maskrom USB mode, independent of the Linux adbd gadget**, so the
  KEY3→Loader gesture and the U-Boot bootcount failover still enumerate the device for re-flashing.

**U-Boot boot-counter → loader (non-dev).** This is the deepest layer — for failures the userspace watchdog
can't catch because they reboot *before* `start-seedsigner.sh` even runs (kernel panic, rootfs-mount or init
failure). The non-dev build enables a U-Boot boot counter that auto-enters rockusb Loader after `bootlimit`
consecutive such boots — no BOOT button, ADB, or working app required.

- **Why a *memory-backed* counter (not the usual env one):** this Rockchip U-Boot **2017.09** fork's
  `drivers/bootcount/Kconfig` only defines `CONFIG_BOOTCOUNT` / `CONFIG_BOOTCOUNT_EXT` — there is **no
  `CONFIG_BOOTCOUNT_LIMIT` / `CONFIG_BOOTCOUNT_ENV` symbol**, so putting those in a defconfig is silently
  dropped by Kconfig (verified on-device: the compiled U-Boot had zero bootcount code). The always-built
  generic backend `drivers/bootcount/bootcount.c` is used instead, pointed at a hardware register.
- **U-Boot** (`build-luckfox.yml` recovery step): patches the U-Boot board header
  `include/configs/rv1106_common.h` with `#define CONFIG_BOOTCOUNT_LIMIT`,
  `#define CONFIG_SYS_BOOTCOUNT_SINGLEWORD`, and `#define CONFIG_SYS_BOOTCOUNT_ADDR 0xFF020218`. `autoboot.c`'s
  `bootdelay_process()` — which runs on **every** boot to pick `bootcmd` — then increments the counter and,
  once `bootcount > bootlimit`, runs `altbootcmd` instead of the normal boot. (No Kconfig/Makefile change and
  no new source files: `bootcount.c` is `obj-y` and reads the `#define`s; `BOOTCOUNT_MAGIC 0xB001C041` comes
  from `include/common.h`.)
- **Register semantics (hardware-verified on a live Pico Pro Max):** the counter lives in a **free GRF `OS_REG`
  scratch register `0xFF020218`** (`0xFF020210/214/218/21C` all read 0 = unused) — **not flash, so there is no
  per-boot NAND wear**. The register **survives a warm reset**, so a kernel-panic reboot loop keeps counting,
  and is cleared by a **cold power-cycle**, so simply unplugging the device resets the counter. Singleword
  encoding stores `(0xB0010000 | count)`. Proven on hardware: forcing the register to `0xB0010006` and
  rebooting, U-Boot read count 6 and stored `0xB0010007` — the increment path runs. The adjacent `0xFF020200`
  is the reboot-mode register (`0x5242C301` = Loader).
- **`bootlimit` + `altbootcmd` are baked into the COMPILED DEFAULT ENV — not the mtd0 env.** This U-Boot is
  built **`ENV_IS_NOWHERE`** (no `CONFIG_ENV_IS_*` in any Luckfox defconfig): it uses only its compiled-in
  default environment and **never reads the mtd0 env that `fw_setenv` writes**. Proven on hardware: with the
  counter forced to 7 and mtd0 `bootlimit=5`, U-Boot used its built-in default (`10`) and booted normally.
  So the recovery step also injects into `CONFIG_EXTRA_ENV_SETTINGS`:
  `bootlimit=5` and `altbootcmd='mw.l 0xFF020218 0; mw.l 0xff020200 0x5242c301; reset'` — zero the counter
  register, then enter Loader via the **proven** reboot-mode magic (`0x5242C301`, same as `rk-reboot loader`;
  `mw`/`reset` both exist in this U-Boot). No `fw_setenv`, `/etc/fw_env.config`, or `u-boot-tools` is needed
  for the failover (they remain installed only for env inspection/debugging).
- **Cleared on a healthy boot:** `start-seedsigner.sh` runs `devmem 0xFF020218 32 0` as soon as userspace is
  up, and the app (`MainMenuView`) clears it again on reaching Home. So only boots that never reach userspace
  accumulate toward the limit; a device that boots normally never approaches it.

**Hardware-verify** on a non-dev image via ADB:
- **Clear works:** shortly after a normal boot, `devmem 0xFF020218` reads `0x00000000` (userspace cleared it).
- **Loader path:** force the counter over the limit and reboot once —
  `devmem 0xFF020218 32 0xB0010006 && reboot -f` (0xB0010006 = magic | count 6, and 6 > bootlimit 5). U-Boot
  should skip the normal boot and the device should enumerate as a Rockchip **Loader** device
  (`rkdeveloptool ld`). A cold power-cycle clears the register and returns to normal boot.
- **Healthy device never triggers:** repeatedly reaching Home must always keep the counter at/near 0.

Note: because `bootlimit`/`altbootcmd` are compiled in (not env), disabling the policy requires a rebuild — it
cannot be turned off with `fw_setenv`. The failover is inert on any boot that reaches userspace (the counter is
cleared), so a healthy device never enters Loader on its own.

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
