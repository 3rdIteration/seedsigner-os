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

### Kernel Config Approaches by Platform

- **Pi profiles**: Full `kernel.config` files. Dev configs add networking/display options at the bottom of an otherwise identical base config. Non-dev configs strip them out.
- **Lafrite profile**: Uses `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` with a kernel fragment (`kernel-fragment.config`). The dev fragment only forces built-in drivers for initramfs boot (serial, MMC, SPI). The non-dev fragment additionally disables INET, IPV6, NETDEVICES, PACKET, DRM, and FRAMEBUFFER_CONSOLE that the arm64 arch default enables.

### Rootfs Overlay Structure

- `board/rootfs-overlay/` — shared between dev/non-dev: hardware config files (mdev.conf, reader.conf.d)
- `../rootfs-overlay-dev/` — dev-only: MicroSD source override startup script. Copied by dev profiles' post-build.sh. Not present in non-dev builds.

### Image Creation Methods

- **Dev**: `genimage` with `genimage-seedsigner.cfg`. Fast, but embeds build-time metadata (non-reproducible).
- **Non-dev**: Manual script that creates disk image via dd, partitions with sfdisk (fixed label-id `ba5eba11`), formats FAT32 with `mkfs.vfat --invariant`, copies files via mcopy with normalized timestamps. Produces byte-identical output across builds.

### Adding a New Profile

When creating a new profile (e.g. `lafrite-smartcard` from `lafrite-smartcard-dev`):
1. Copy hardware files unchanged: extlinux.conf, boot.cmd, DTS, genimage-diy-tools.cfg, rootfs-overlay, Config.in, external.mk
2. Create defconfig: remove dev packages, update paths to new profile name, single rootfs-overlay (no `-dev`)
3. Create post-build.sh: adapt from existing non-dev profile for the target architecture (armhf vs aarch64)
4. Create busybox.config: copy from equivalent non-dev profile (minimal networking)
5. Create kernel config or fragment: disable INET, IPV6, NETDEVICES, PACKET, DRM, FRAMEBUFFER_CONSOLE
6. Create post-image script: deterministic manual approach with pinned bootloader SHA-256
7. Update external.desc: keep buildroot's `key: value` format with a `name:` line (all profiles use `name: RPI_SEEDSIGNER`, referenced by `external.mk` as `BR2_EXTERNAL_RPI_SEEDSIGNER_PATH`); remove "Dev" from the `desc:`. A missing `name:` aborts the build with "external.desc does not define the name".
8. Set the executable bit on `post-build.sh` and the post-image script and confirm it before committing (see the note under [Buildroot Post-Build / Post-Install Scripts](#buildroot-post-build--post-install-scripts)). Non-executable scripts fail at `target-finalize` with exit code 126.
