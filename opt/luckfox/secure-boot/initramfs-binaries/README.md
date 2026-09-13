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
| busybox-arm  | ~223 KB   | minimal static busybox, armv7 (sh + coreutils for /init) — in the initramfs |
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
* Config: `allnoconfig` plus only what `/init` needs — sh/ash, mount, umount,
  pivot_root, dd, truncate, sha256sum, ls, cat, echo, sleep, true, false,
  reboot/halt/poweroff, mknod, grep, head, tail, dmesg, rm, mkdir, ln, cp, mv —
  plus `CONFIG_STATIC=y` and `CONFIG_ASH_INTERNAL_GLOB=y` (busybox refuses to
  use uClibc's buggy glob() otherwise).

### ss-lcd

* Source: [`../initramfs/ss-lcd.c`](../initramfs/ss-lcd.c) in this repo, plus
  the public-domain 8x8 font `font8x8_basic.h` (Daniel Hepper / Marcel Sondaar,
  based on IBM's public-domain VGA fonts).
* The ST7789 init sequence, SPI settings and GPIO lines are ported from the
  SeedSigner app's own driver (`seedsigner/hardware/displays/st7789_mpy.py` +
  `io_config.json` FOX_22 profile), which is the reference implementation for
  this panel.

## Why committed binaries instead of building at build time

* **Reproducibility**: non-dev images must be byte-identical across builds. A
  pinned, reviewed binary in the repo is deterministic by construction; a
  from-source build would need every toolchain version and flag pinned too.
* **No new build dependencies**: the Docker image does not gain Go/Zig/autotools
  just to produce three small static binaries.
* If any of these must be rebuilt (e.g. a CVE in libsodium), rebuild with the
  recipe above, update the file and its SHA-256 pin in `os-build.sh` together,
  and note the reason in the commit message.
