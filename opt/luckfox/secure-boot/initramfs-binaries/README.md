# initramfs-binaries/ — prebuilt static armv7 binaries for the rootfs-verification initramfs

These three binaries are packed into the initramfs that `os-build.sh` embeds in
the signed `boot.img` FIT ramdisk slot when `SEEDSIGNER_FIT_SIGNATURE=1`. They
run from RAM before pivot_root, so they must be **fully static** (no dynamic
linker, no host filesystem) and small enough for the 4 MiB boot partition.

All three are built with the SDK's own cross toolchain
(`tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf`, GCC 8.3.0 /
crosstool-NG 1.24.0, uClibc) so they match the platform libc family. They are
committed to the repo and SHA-256-pinned by `os-build.sh` (see
`verify_initramfs_binaries()`); a mismatch fails the build loudly rather than
shipping a different binary than the one that was reviewed.

| file         | size      | what it is |
|--------------|-----------|------------|
| busybox-arm  | ~227 KB   | minimal static busybox, armv7 (sh + coreutils for /init) — in the initramfs |
| minisign-arm | ~404 KB   | minisign 0.9, armv7 — boot-time signature verification in the initramfs |
| ss-lcd       | ~60 KB    | ST7789 status display, armv7 (source: ../initramfs/ss-lcd.c) — in the initramfs |
| minisign-host| ~1.0 MB   | minisign 0.9, x86-64 — build-time signing inside mkfs_ubi.sh's fakeroot script |

SHA-256 for all four: `SHA256SUMS` (pinned by `os-build.sh`).

## Provenance / rebuild recipe

### minisign-arm

* Source: [jedisct1/minisign](https://github.com/jedisct1/minisign) tag `0.9`
  (commit `9b3a4f28fd58033a48d7b7284a1da30182d7d4b8`) — the C implementation;
  tags ≥ 0.10 are a Zig rewrite with no armv7 release asset.
* Crypto: [libsodium](https://github.com/jedisct1/libsodium) `1.0.22-RELEASE`.
  The release tarball was verified against the git tag before building: every
  file under `src/` and `include/` (323 files) matches the tagged commit
  byte-for-byte.
* Build: cross-configure libsodium static
  (`./configure --host=arm-rockchip830-linux-uclibcgnueabihf CC=<tc>-gcc
  --enable-static --disable-shared`), then
  `<tc>-gcc -O2 -static src/{base64,get_line,helpers,minisign}.c -lsodium`,
  strip.

### busybox-arm

* Source: [busybox-1.36.1.tar.bz2](https://busybox.net/downloads/) — sha256
  `b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314`, verified
  against the official `.sha256` file.
* Config: `allnoconfig` plus only what `/init` needs — sh/ash, **test** (BOTH
  options are required in busybox 1.36: CONFIG_TEST builds the standalone test
  applet, while ash's `[`/`test` *shell builtins* are guarded by a separate
  CONFIG_ASH_TEST — `shell/Config.in`, wired into the builtin table at
  `shell/ash.c`; with allnoconfig both default off and every `[ ... ]` in /init
   dies with "[: not found"), mount, umount, pivot_root, dd, truncate, sha256sum,
    ls, cat, echo, sleep, true, false, reboot/halt/poweroff, mknod, grep, head,
    tail, dmesg, rm, mkdir, ln, cp, mv — plus `CONFIG_STATIC=y`,
    `CONFIG_ASH_INTERNAL_GLOB=y` (busybox refuses to use uClibc's buggy glob()
    otherwise), `CONFIG_FEATURE_FANCY_HEAD=y` (enables `head -c`, which /init
    uses to trim the streamed volume read to exactly the signed byte count),
    `CONFIG_FEATURE_SH_MATH=y` (POSIX `$((...))` arithmetic — /init's wait-loop
    counter and block-count math; with allnoconfig it defaults off and ash dies
    at the first `$((` with "syntax error: support for $((arith)) is disabled")
    and `CONFIG_SWITCH_ROOT=y` (the initramfs→rootfs handoff — pivot_root()
    refuses to work from the kernel's rootfs pseudo-filesystem, so /init must
    use switch_root; see Documentation/filesystems/ramfs-rootfs-initramfs.rst).
* Rebuild procedure that reproduces the committed binary: `make allnoconfig`,
  then sed-flip ONLY those options from `# CONFIG_X is not set` to
  `CONFIG_X=y` in .config, then `yes '' | make oldconfig`. Do NOT start from a
  minimal .config and let oldconfig fill defaults — hundreds of FEATURE_*
  options default to y and the binary balloons ~1.2 MB (overflows the 4 MiB
  boot partition). Appending =y lines after allnoconfig also fails: busybox's
  kconfig rejects them as "reassignment" of already-set symbols.
* Rebuilt on 2026-09-13 (three times) after first-board-boot failures: CONFIG_TEST alone did
  NOT fix "[: not found" (that only builds the standalone applet) — what
  registers `[`/`test` as ash builtins is CONFIG_ASH_TEST. The committed binary
  also carries CONFIG_FEATURE_FANCY_HEAD for `head -c`, and CONFIG_FEATURE_SH_MATH:
  a second board boot died with "line 89: syntax error: support for $((arith)) is
  disabled" — the wait-loop counter uses `$((tries + 1))` and allnoconfig leaves
  POSIX math off. The third rebuild added CONFIG_SWITCH_ROOT after the board
  showed `pivot_root failed`: pivot_root() cannot work from an initramfs root
  (the kernel's rootfs pseudo-filesystem), so /init now hands over via
  switch_root, which also frees the initramfs RAM. Final size 230872, sha256 in
  SHA256SUMS; all other applets identical to the original build.
* Note: busybox bakes its build timestamp into a version string (`BusyBox v1.36.1
  (DATE)`), so two builds of the same config minutes apart have different hashes.
  The pin tracks the committed file, not a reproducible build.

### ss-lcd

* Source: [`../initramfs/ss-lcd.c`](../initramfs/ss-lcd.c) in this repo, plus
  the public-domain 8x8 font `font8x8_basic.h` (Daniel Hepper / Marcel Sondaar,
  based on IBM's public-domain VGA fonts).
* The ST7789 init sequence and SPI settings are ported from the SeedSigner
  app's own driver (`seedsigner/hardware/displays/ST7789.py` — the factory in
  `display_driver.py` selects it for 240x240 panels; `st7789_mpy.py` is only
  used for 320x240). Key values that differ from the mpy driver: MADCTL=0x70,
  COLMOD=0x05 (RGB order), and a single init pass with a 150 ms post-reset
  wait. The DC/RST control pins are per board (`io_config.json`): `/init`
  exports `SS_LCD_{DC,RST}_{CHIP,LINE}` at build time for each profile — the
  compiled-in defaults are the Mini/FOX_22 values (gpiochip1 lines 20/19);
  max uses gpiochip2 line 8 + gpiochip1 line 24, pi uses gpiochip1 lines
  27/24. DC and RST may sit on different gpiochips, so each is opened from its
  own env pair.
* Two modes: `ss-lcd <color> <title> [line x4]` draws a status screen;
  `ss-lcd waitkey <gpiochip> <line> <reg writes...>` blocks until the button
  goes LOW (the verification-failure escape hatch in `/init`). The register
  writes are raw IOMUX/pull-up/direction/IE sequences — required because the
  RV1106 pinctrl driver silently ignores gpiolib bias flags, and they must run
  before the chardev line request. Note: this SDK kernel's `linereq_create()`
  returns 0 and writes the fd into the request struct (Rockchip backport), so
  the code reads `req.fd` rather than using the ioctl return value.
* Rebuild: `<tc>/bin/arm-rockchip830-linux-uclibcgnueabihf-gcc -O2 -static
  ../initramfs/ss-lcd.c -o ss-lcd`, then strip with the toolchain's
  `arm-rockchip830-linux-uclibcgnueabihf-strip` (no libraries needed — raw
  SPI_IOC_MESSAGE + GPIO v2 ioctls only).

## Rebuilding at build time (opt-in)

`../build-initramfs-binaries.sh <SDK_TOOLCHAIN_DIR> <OUTPUT_DIR>` rebuilds all
four binaries from source and overwrites the copies in OUTPUT_DIR. It is wired
into both `os-build.sh` and `build-local.sh` behind
`SEEDSIGNER_REBUILD_INITRAMFS_BINARIES=1` (or `./build.sh build ... --rebuild-initramfs-binaries on`),
and only runs when `SEEDSIGNER_FIT_SIGNATURE=1`.

Everything the rebuild needs is pinned, so its output is deterministic:

* **Sources** — busybox 1.36.1, minisign @9b3a4f28 (tag 0.9), libsodium
  1.0.22-RELEASE — downloaded by URL and verified against hardcoded SHA-256 in
  the script (AGENTS.md: every external asset is checksum-pinned).
* **Toolchain** — the SDK's own `arm-rockchip830-linux-uclibcgnueabihf` for the
  three arm binaries (pinned by `SDK_COMMIT`); minisign-host uses the host gcc
  of the Ubuntu 22.04 build environment (Docker image or CI host).
* **Date** — `SOURCE_DATE_EPOCH=0`. busybox bakes it into its version string
  (`BusyBox v1.36.1 (1970-01-01 00:00:00 UTC)`); minisign and libsodium embed
  no date at all.

The rebuilt files are then checked by `verify_initramfs_binaries()` against the
committed SHA-256 pins, so a rebuild that does not reproduce the pinned bytes
EXACTLY fails the build loudly. The pins are therefore a live determinism
canary — do NOT auto-update them here or in the build scripts. When source
legitimately changes (e.g. ss-lcd.c), run two flag-on builds, confirm they are
byte-identical to each other, then update `SHA256SUMS`, both pin tables and
the committed binaries together in one commit.

## Why committed binaries instead of building at build time by default

* **Reproducibility**: non-dev images must be byte-identical across builds. A
  pinned, reviewed binary in the repo is deterministic by construction; a
  from-source build would need every toolchain version and flag pinned too (the
  opt-in rebuild above does exactly that pinning).
* **No new build dependencies**: the Docker image does not gain Go/Zig/autotools
  just to produce three small static binaries.
* If any of these must be rebuilt (e.g. a CVE in libsodium), either use the
  opt-in rebuild or follow the recipe above, update the file and its SHA-256 pin
  in `os-build.sh` together, and note the reason in the commit message.
