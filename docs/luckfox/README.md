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
HDMI; its extra vectors are the USB gadget and Ethernet on Pro Max / Pico Pi).

**Threat model: root-level code execution.** The SeedSigner Python app runs as root, so *userspace* hardening
is not a control by itself — root can simply `ifconfig eth0 up; udhcpc`, or `insmod` a WiFi driver from
`/oem/usr/ko`. Anything that must genuinely hold is therefore removed from the **kernel**, with the userspace
steps kept as defence in depth. Note that **the oem partition is part of the attack surface**: every built
`.ko` is packaged to `/oem/usr/ko` and no rootfs hardening touches it.

| Vector | non-dev closes it via | Where |
|---|---|---|
| Kernel serial console | strip `console=ttyFIQ0`/`earlycon`/`user_debug` bootargs (forced on for non-dev; the `disable_uart2_console_debug` input is the dev override) | "Configure UART2 console debug" (all three builds) |
| Serial **login** (getty) | `# BR2_TARGET_GENERIC_GETTY is not set` in the defconfig **and** comment console/tty getty/login/shell `respawn` lines in the rootfs `/etc/inittab` | defconfig sed + `harden-nondev.sh` |
| **Networking — kernel** | `INET`/`PACKET`/`IPV6`/`NETDEVICES` off plus the Ethernet MAC+PHY (`STMMAC_ETH`/`RK630_PHY`) and `USB_CONFIGFS_RNDIS`: root cannot create an interface or open an AF_INET socket because the stack isn't compiled in. Gated on `debug_network=off` | `strip-kernel-network.sh` (Group A) |
| **WiFi — kernel** | `WL_ROCKCHIP` (umbrella that `select`s CFG80211+MAC80211 and sources every vendor WiFi Kconfig) + `RTL8723BS` off, so the 802.11 stack and all 8 vendor drivers are never built and can't reach `/oem/usr/ko`. Always stripped on non-dev | `strip-kernel-network.sh` (Group B) |
| Networking — userspace *(defence in depth)* | no interface bring-up: `S*network*` stubbed to loopback-only, DHCP neutered, `/etc/network/interfaces` = `lo`, telnet/ssh/dropbear init scripts removed | `harden-nondev.sh` (`HARDEN_DISABLE_NETWORK`) |
| **USB gadget** (ADB + RNDIS) | DTS `dr_mode = "host"`: dwc3 registers host-only so **`/sys/class/udc/` is empty and a configfs gadget has nothing to bind to** — root cannot re-enable adb at runtime. Plus adb userspace strip: stub `adbd`/`usbdevice`, blank the gadget function config, comment gadget lines in `RkLunch.sh`. `S*usb*` init scripts are **kept** — `S50usbdevice` mounts configfs (the SPI display depends on it) and is patched host-aware instead | `configure-usb-mode.sh` + `harden-nondev.sh` (`HARDEN_DISABLE_ADB=1`) + `patch-s50usbdevice.sh` |
| Logging daemons | remove `syslogd`/`klogd` autostart | `harden-nondev.sh` |
| Dev / network CLI tools | drop `python-pip`, `wget`, `libcurl`/curl from the target | defconfig sed |

**Kernel symbols that must stay enabled** — each would break the device:
`CONFIG_NET`/`CONFIG_UNIX` (pcscd uses an AF_UNIX socket; dropping `NET` kills smartcards),
`CONFIG_MODULES` (camera drivers are `=m`), and `CONFIG_USB_GADGET` — the *sole* provider of configfs here
(`USB_CONFIGFS` → `USB_LIBCOMPOSITE` → `select CONFIGFS_FS`); without configfs `luckfox-config` cannot create
the device-tree overlays that enable SPI0 and **the display dies**. That is why ADB is blocked via
`dr_mode=host` rather than by disabling the gadget stack. `strip-kernel-network.sh` refuses to run if any of
these is off, and `assert-kernel-network.sh` re-checks them after the build.

**Always verify against the generated `.config`, never the defconfig** — Kconfig silently drops defconfig
lines whose symbol doesn't exist or whose dependencies are unmet (exactly how the first U-Boot bootcount
attempt shipped green with no bootcount code). `assert-kernel-network.sh` runs after `build.sh kernel` and
again after `build.sh firmware`, checking the built config, a `CONFIGFS_FS=y` display canary, and that no
wireless `.ko` reached the oem payload.

The hardening lives in shared **`opt/luckfox/*.sh` scripts** (`harden-nondev.sh`, `configure-usb-mode.sh`,
`patch-s50usbdevice.sh`, `uboot-recovery-config.sh`, `strip-kernel-network.sh`, `assert-kernel-network.sh`,
`optimize-nondev.sh`, `patch-oem-pre-hook.sh`, `prune-oem-iqfiles.sh`) called identically by **all three build
implementations** — the GitHub Actions workflow
and both local Docker builds (`os-build.sh`, `build-local.sh`) — so CI and local images get the same
hardening; change the script, never one caller. Because the SDK rootfs layout varies by version, every
userspace step is **guarded/no-op if the target is absent** and logs each file it did/didn't touch.

**A green build does not prove the vectors were closed** — review the `[harden]` / `[kstrip]` / `[kassert]`
log lines, then verify on hardware. As root on the device: `ip link` shows no `eth0` and `ifconfig eth0 up`
**fails**; no wifi `.ko` exists under `/oem/usr/ko` to `insmod`; `ls /sys/class/udc/` is **empty** and
`adb devices` finds nothing; nothing listens on `:22`/`:23` and no DHCP requests appear on the LAN; no
console output or login prompt on the serial header; no `syslogd`/`klogd`; `which pip curl wget` empty. Also
confirm the things the strip must *not* have broken: **display** (the configfs canary), **camera** (modules
still load from `/oem/usr/ko`) and **smartcards** (the AF_UNIX/pcscd path). The reboot-to-Loader Power option
/ `rk-reboot` is retained in **both** variants.

### Non-dev size / boot optimizations

Non-dev images also get size and boot tweaks (dev keeps SDK defaults). Companion script
**`opt/luckfox/optimize-nondev.sh <ROOTFS_DIR>`** runs right after `harden-nondev.sh`:

| Tweak | What / where | Notes |
|---|---|---|
| Optimize for size | defconfig `BR2_OPTIMIZE_3=y` → `BR2_OPTIMIZE_S=y` | smaller binaries, marginally slower |
| Prune test/metadata | remove `tests/`, `*.dist-info`/`*.egg-info` under site-packages + `/opt/src`, and `/opt/tools` | `optimize-nondev.sh` |
| Prune camera iqfiles | keep only the board's sensor (`IQFILES_KEEP`), remove the rest from `/oem` | `prune-oem-iqfiles.sh`, run from the SDK's pre-build-OEM hook (see below); **verify camera** |
| Quiet boot | append `quiet loglevel=3` to the DTS `bootargs` | marginal once console is stripped |
| U-Boot bootdelay | zero any non-zero `CONFIG_BOOTDELAY`/`bootdelay=` in the SDK U-Boot | best-effort, guarded |
| UI-first camera | `optimize-nondev.sh` drops `/etc/seedsigner-nondev`; `start-seedsigner.sh` then backgrounds the ~4s camera-graph bootstrap so the UI comes up first | **experimental — verify camera on hardware** |

Same discipline as hardening: everything keys off `build_variant=non-dev`, is guarded/no-op when the SDK
target isn't present, and logs under `[optimize]` / `[iqprune]`. **iqfiles pruning and the UI-first camera
reorder must be verified on real hardware** (scan a QR) — a green build proves nothing about the camera. Both
are trivially revertible (widen `IQFILES_KEEP`; the reorder only triggers when the `/etc/seedsigner-nondev`
marker exists).

**Why iqfiles pruning uses an SDK hook.** Anything that edits the *oem* partition cannot run from
`optimize-nondev.sh`: oem is assembled by the SDK's `__PACKAGE_OEM`, which is called only from
`build_firmware()` (i.e. during `build.sh firmware`), long after the rootfs/app install step. The prune lived
there originally and therefore **silently did nothing in every build** until 2026-08-06. It now runs from
`prune-oem-iqfiles.sh`, invoked via the SDK's `__RUN_PRE_BUILD_OEM_SCRIPT` hook — which fires after
`__PACKAGE_OEM` but before `build_mkimg` creates `oem.img`, the one window where the staged oem tree exists
and is still editable. `patch-oem-pre-hook.sh` installs the call by **appending** to whatever script
`RK_PRE_BUILD_OEM_SCRIPT` names (every Luckfox board config points at the vendor's
`luckfox-buildroot-oem-pre.sh`, which prunes unused libs there for the same reason — replacing it would drop
those prunes). The prune decides what to delete before deleting anything and **aborts without touching a file
if `IQFILES_KEEP` matches nothing**, so a bad keep-list can't silently ship a camera with no tuning data.
The same hook is the right home for any future oem-partition surgery.

## Keeping the three build implementations in sync

There are three ways to build: `.github/workflows/build-luckfox.yml` (CI),
`opt/luckfox/os-build.sh` (Docker), and `opt/luckfox/build-local.sh` (no Docker). **Shared logic lives in
`opt/luckfox/*.sh`; change the script, never one caller.** Every one of these is invoked by all three:

| Script | Does |
|---|---|
| `apply-partition-layout.sh` | flash layout incl. the `userdata` partition |
| `pin-spidev-bufsiz.sh` | `spidev.bufsiz=8192` on the kernel command line |
| `readonly-rootfs.sh` / `assert-readonly-rootfs.sh` | squashfs root + overlay, and its verification |
| `install-gnupg-home.sh` | stages the GnuPG agent/scdaemon config seeded into `GNUPGHOME` |
| `strip-kernel-network.sh` / `assert-kernel-network.sh` | network/WiFi/coredump strip, and its verification |
| `configure-usb-mode.sh`, `harden-nondev.sh`, `optimize-nondev.sh`, `patch-s50usbdevice.sh`, `patch-oem-pre-hook.sh`, `prune-oem-iqfiles.sh`, `uboot-recovery-config.sh`, `compile-translations.sh` | as named |

**Why this is a hard rule, not a style preference.** Two of these were inlined and duplicated instead, and
both copies drifted into shipping a different device:

- **Partition layout.** The local builds *deleted* the `userdata` partition (`20M(oem),99M(rootfs)`, plus a
  sed stripping `userdata@/userdata@ubifs`) while CI kept it. Same repo, same board, silently different
  images — and the local one had nowhere to persist settings or write a boot log. With a read-only rootfs it
  had nowhere writable at all.
- **`spidev.bufsiz`.** Present only in CI. A locally built Mini kept the vendor default, hit the order-6
  allocation failure in `spidev_open()`, and came up with no display — while its splash drew fine on the same
  boot, which makes it look like a display bug rather than a build difference.

Neither had a build-time signal. Both are now single scripts that hard-fail if their result is wrong.

`opt/luckfox/build.sh` (the Docker wrapper) mirrors the CI workflow inputs: `--variant`,
`--readonly-rootfs`, `--usb-mode`, `--debug-network`, `--seedsigner-ref`, and `--model mini|max|pi|both`.
Previously only `BUILD_MODEL`/`BUILD_JOBS` crossed the container boundary, so a Docker build silently took
the defaults no matter what was asked for.

### Pinning the SeedSigner app

The app is **the only component this repo does not pin** — the SDK is fetched at a fixed revision, but the
app is cloned from a ref. `--seedsigner-ref` accepts a branch, a **release tag**, or a commit (anything
`git clone -b` takes), and a tag is the only one of those that is a fixed target:

```bash
./build.sh --luckfox build --model max --microsd --seedsigner-ref SeSi-0.8.7+ShSi-B11
```

The same value goes in the workflow's `seedsigner_branch` input. Whatever is used, the resolved ref and
commit are stamped into `/etc/seedsigner-os-release` (`SEEDSIGNER_APP_BRANCH` / `SEEDSIGNER_APP_COMMIT`), so
a built image always records what it contains — including the tag name, which `gen-os-release.sh` now
prefers over the branch, since a tag build is a detached checkout that would otherwise record nothing useful.

`build-local.sh` **reuses an existing `seedsigner/` checkout rather than re-cloning**, so it reports the ref
and commit it found and warns when they do not match what was requested. Delete the checkout to switch refs.

## Read-only root filesystem

Non-dev images mount `/` as **squashfs** with **tmpfs overlays** on `/etc`, `/var`, `/root` and `/home`.
A dirty unmount cannot corrupt the rootfs (squashfs has no journal, no allocator and no write path) and no
runtime change to `/` survives a reboot, because none can be committed in the first place.

This replaces a writable UBIFS root that was **self-damaging in normal operation**, via two confirmed writers:

- `luckfox-config` does `sed -i` on `/etc/luckfox.cfg` on **every boot**. A power cut mid-write truncates or
  loses the file; `luckfox_load_cfg` then silently `touch`es an empty one, zero device-tree overlays are
  created, there is no `/dev/spidev0.0` — and the board comes up with a **black screen and no way to report
  why**. That failure is indistinguishable on the bench from a display bug.
- the shipped Python bytecode sits on the same filesystem. A truncated `.pyc` surfaced as
  `EOFError: marshal data is too short` and needed a reflash.

Neither is fixable in application code: the damage happens during UBIFS journal replay, to files nobody was
deliberately writing.

| Path | State | Notes |
|---|---|---|
| `/` | squashfs, read-only | immutable after flash |
| `/etc` `/var` `/root` `/home` | overlayfs, tmpfs upper | writable; **discarded at reboot** |
| `/opt` | read-only | app + bytecode; deliberately not overlaid |
| `/userdata` | **read-write, persistent** | the only persistent store — settings live here |
| `/oem` | read-write | **not yet covered** — see below |

**Moving parts.** `readonly-rootfs.sh` (build time) sets `rootfs@IGNORE@squashfs` in the board config plus
`RK_SQUASHFS_COMP=xz`, and enables `CONFIG_OVERLAY_FS` in the kernel defconfig. Bootargs are **not** patched:
the SDK derives `root=`/`rootfstype=` from the filesystem type (`ubi.block=0,rootfs root=/dev/ubiblock0_0` on
NAND, `root=/dev/mmcblk0p<n>` on eMMC). `files/S01overlay` mounts the overlays at runtime, and is a **no-op on
a writable root**, so dev images are unaffected. Controlled by the `readonly_rootfs` build input
(`auto`/`on`/`off`; auto = on for non-dev).

**Bytecode is precompiled at build time.** A read-only `/opt` can never cache `__pycache__` at runtime, so
without this every import would re-compile `.py` source off xz squashfs, on a single-core A7, on every boot.
`precompile-bytecode.sh` runs after the app is staged (and after the non-dev prune) in all three build paths,
using the SDK buildroot's host python + the **target** python's `compileall.py` (discovered, version-matched —
wrong-magic `.pyc` would be ignored) with deterministic flags and hash-based invalidation, over
`/opt/src` **and** `site-packages`. Same approach as the Pi profiles' post-build scripts; `.py` sources stay
in the image (checked-hash validation reads them).

**Why the assertion matters.** `assert-readonly-rootfs.sh` checks the **generated** kernel `.config`, never
the defconfig written — Kconfig silently drops lines for symbols whose dependencies are unmet. A squashfs root
on a kernel without overlayfs boots fine and then fails the first write to `/etc`, which presents as exactly
the black screen described above. That has to fail the build, not the board.

**GnuPG is on tmpfs, deliberately.** The app never sets `GNUPGHOME` and never passes
`gpg --homedir`, so gpg resolves its home from `$HOME` — which under BusyBox init is `/`, i.e.
`/.gnupg` on the read-only root. Every write gpg needs then fails with "read-only file
system", which is what broke GPG key generation and key import. `start-seedsigner.sh` sets
`GNUPGHOME=/tmp/.gnupg` and seeds `gpg-agent.conf` + `scdaemon.conf` there from
`/usr/share/seedsigner/gnupg`.

`/tmp` rather than an overlaid path: it is a plain tmpfs available *before* `S01overlay` runs
(which itself uses `/tmp`), so gpg cannot inherit an overlay failure — and **GPG keys are
wiped at reboot by construction**, never written to flash. `scdaemon.conf`'s `disable-ccid`
matters here: until the home was writable, `gpg-agent`/`scdaemon` could not create their
sockets and never ran at all; giving them a working home means they start, and `disable-ccid`
routes scdaemon through pcscd instead of letting it grab the SEC1210 reader directly.

**Not yet covered:** the `oem` partition is still read-write. Its surface is much smaller (no equivalent of
the per-boot `luckfox.cfg` rewrite has been observed), but it is the remaining writable filesystem that is
mounted on every boot. The SDK does support `oem@/oem@squashfs`; converting it is a separate change needing
its own hardware verification.

## Boot recovery & auto-failover to Loader

So a bad image self-heals into a flashable state without the BOOT button:
- **KEY3 very-long-press on Home** (both variants, Luckfox only): hold KEY3 ~5 s on the home screen to reboot
  into rockusb Loader mode — same action as the Power menu's "Reboot to flash mode". A short KEY3 tap still
  selects. Implemented in the app (`MainMenuScreen`/`RebootToLoaderView`).
- **Startup watchdog** (`start-seedsigner.sh`, both variants): the app writes `/tmp/seedsigner-ready` when it
  reaches Home; if that never appears within ~120 s, or the launch retry loop is exhausted, the device reboots
  into Loader mode. Covers the app-crash and app-hang cases. **The app ref must carry the signal** — it was
  added in app commit `689483af` (2026-07-28), so `dev` and all release tags predate it. A signal-less app
  builds green, boots *looking* completely healthy, and reboots into Loader 120 s later, on every boot;
  `assert-app-watchdog-signal.sh` therefore fails the build after the app clone when the signal is absent.
  **Scoped by build variant:** non-dev (production, shipped) builds hard-fail; dev builds (automatic push/PR
  CI, debuggable, never shipped — the app's `dev` branch is signal-less, so a hard fail there would block all
  OS CI) warn instead. Escape hatch for deliberate bisect/A-B of an old app:
  `SEEDSIGNER_ALLOW_NO_WATCHDOG_SIGNAL=1`.
- **Persistent boot log** (`start-seedsigner.sh`, both variants, **off by default**): when enabled, every boot
  is recorded to `/userdata/seedsigner-boot.log` (rotated once, capped at 128 KiB, deleted as soon as the app
  signals ready) so a boot failure that leaves a "bricked-looking" device still explains itself — `/tmp` is a
  tmpfs and is gone on the next reboot. It is **off unless the build bakes `/etc/seedsigner-boot-log`**
  (`boot_log` dispatch input / `--boot-log on` / `SEEDSIGNER_BOOT_LOG=on`): a production device must write
  nothing to flash, and `/userdata` survives a reflash, so a persisted app traceback would be app output left
  in NVS on a device meant to be air-gapped. Even when disabled, a successful boot still sweeps any stale
  log/`.prev` and core dumps from writable storage.
- **`panic=5`** (non-dev bootargs): a kernel panic reboots instead of hanging, giving the failover another
  shot. Dev keeps panics visible for debugging.
- **USB role (`usb_mode`) — this is the ADB switch.** The RV1106 USB port is either a **device gadget**
  (`gadget` — adb + RNDIS, for debugging) or a **host** (`host` — drives external USB peripherals like a
  camera or smartcard reader; **no gadget, so no adb/RNDIS** = air-gapped on the USB axis). Set via the
  `usb_mode` dispatch input (`auto`/`gadget`/`host`/`otg`); `auto` follows the variant: **non-dev = host,
  dev = gadget**. Implemented as a device-tree override (`&usbdrd_dwc3 { dr_mode = "host"; }`) via the shared
  `opt/luckfox/configure-usb-mode.sh` (used by CI and both local builds). On non-dev the harden step
  additionally strips the adb *userspace* (`HARDEN_DISABLE_ADB=1`: no-op stubs for `adbd`/`usbdevice`,
  blanked gadget function config) as defence in depth — but never the `S*usb*` init scripts:
  **`S50usbdevice` must survive** (it is what mounts configfs, which `luckfox-config` needs to enable SPI0
  for the display); it is instead patched host-aware by `opt/luckfox/patch-s50usbdevice.sh`. To debug a
  non-dev image, build it with `usb_mode=gadget`. Switching to host does **not** weaken recovery: rockusb
  **Loader mode is a U-Boot/maskrom USB mode, independent of the Linux gadget**, so KEY3→Loader and the
  U-Boot bootcount failover still enumerate the device for re-flashing. (Host mode needs the board to supply
  VBUS to power bus-powered peripherals; a self-powered device or powered hub always works.)
- **Ethernet debug channel (`debug_network`) — the network switch.** The Luckfox SDK kernel keeps
  `CONFIG_INET` (unlike the Pi/La Frite non-dev kernels), and the Pro Max / Pico Pi have Ethernet — so
  networking is closed in **userspace** by `harden-nondev.sh` (`HARDEN_DISABLE_NETWORK=1`, the non-dev
  default): no interface bring-up (`S*network*` stubbed to loopback-only), DHCP neutered (no broadcast of
  MAC/hostname on any LAN it's plugged into), `/etc/network/interfaces` reduced to `lo`, and every
  telnet/ssh/dropbear init script removed. Set the `debug_network` dispatch input to `on` to build a non-dev
  image that keeps Ethernet + telnet (root shell on `:23`, login `root`/`luckfox`) as a USB-independent
  debug/recovery channel — invaluable for debugging host-mode images, but **never ship it**.

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
