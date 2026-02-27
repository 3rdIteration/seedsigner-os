# SeedSigner OS — Libre Computer La Frite (AML-S805X-AC)

Buildroot external tree for the [Libre Computer La Frite](https://libre.computer/products/aml-s805x-ac/)
(Amlogic S805X, quad-core Cortex-A35, AArch64, 512 MB or 1 GB LPDDR4).

---

## Board-specific learnings and tweaks

### 1. Bootloader — Amlogic FIP (multi-stage signed image)

**Problem:** The Amlogic S805X bootrom requires a signed, encrypted Firmware
Image Package (FIP) combining BL2 (Amlogic proprietary), BL31 (ARM Trusted
Firmware for GXL), and BL33 (U-Boot). A raw `u-boot.bin` written to the SD
card is silently rejected — the bootrom cannot execute it.

**Solution:** The post-image script downloads the pre-built FIP from Libre
Computer's boot server and writes it raw at SD byte-offset 512:

```
https://boot.libre.computer/ci/aml-s805x-ac
```

This is the same approach used by
[libretech-buildroot](https://github.com/3rdIteration/libretech-buildroot) and
[libretech-flash-tool](https://github.com/libre-computer-project/libretech-flash-tool).

The board's SPI NOR flash contains a factory-flashed bootloader that takes
priority over the SD card at power-on (Amlogic GXL boot order:
SPI NOR → eMMC → SD → USB). The SD-resident FIP is used when the SPI NOR
bootloader explicitly falls through to SD (e.g. no valid image found on SPI)
or is erased.

**Relevant files:**
- `board/post-image-seedsigner.sh` — downloads and integrity-checks the FIP
- `board/genimage-seedsigner.cfg` — writes FIP at offset 512, boot partition at 1 MB

---

### 2. Partition layout — FAT32 (0x0C), not EFI System Partition (0xEF)

**Problem:** The Libre Computer U-Boot (`boot.libre.computer`) uses
`CONFIG_BOOTSTD_FULL=y` with `bootflow scan -lb` and *no* `CONFIG_DISTRO_DEFAULTS`.
In this mode, U-Boot's `efi` bootmeth scans for `EFI/boot/BOOTAA64.EFI` on
`0xEF` type partitions. However, the extlinux `syslinux` bootmeth scans FAT
partitions of *any* MBR type, including `0x0C`.

Using `0xEF` caused the board to boot into EFI mode (looking for
`EFI/boot/BOOTAA64.EFI`), while our boot vfat contains extlinux layout.

**Solution:** Boot partition type is `0x0C` (FAT32 LBA). U-Boot's `bootflow
scan` finds `extlinux/extlinux.conf` on the FAT32 partition via the `syslinux`
bootmeth and boots the kernel correctly.

**Relevant files:**
- `board/genimage-seedsigner.cfg` — `partition-type = 0x0C`

---

### 3. extlinux — `devicetree` keyword, not `fdt`

**Problem:** U-Boot's syslinux parser accepts `devicetree` as the canonical
keyword for specifying the DTB. While some versions also accept `fdt`, using
`fdt` in `extlinux.conf` caused the DTB not to be loaded, resulting in a
kernel panic at boot (no console, no MMC, etc.).

**Solution:** Use `devicetree` in `extlinux.conf`, matching the upstream
Buildroot `lafrite_defconfig` approach.

```
label linux
  kernel /Image
  devicetree /meson-gxl-s805x-libretech-ac.dtb
  append console=ttyAML0,115200 earlyprintk rdinit=/sbin/init cma=64M
```

**Relevant files:**
- `board/extlinux.conf`

---

### 4. CMA — reduced to 64 MB

**Problem:** The Amlogic GXL device tree for La Frite reserves a large
Contiguous Memory Allocator (CMA) region by default (up to 256 MB in some DT
versions). On a 512 MB board this leaves very little RAM for the SeedSigner
application.

**Solution:** `cma=64M` is passed on the kernel command line in
`extlinux.conf`. This parameter overrides both the device-tree `linux,cma`
node and any `CONFIG_CMA_SIZE_MBYTES` Kconfig default, hard-capping the CMA
reservation at 64 MB.

**Relevant files:**
- `board/extlinux.conf` — `append ... cma=64M`

---

### 5. SPI — `spi-nor` claims `spi0.0`, blocking `/dev/spidev0.0`

**Problem:** The La Frite device tree (`meson-gxl-s805x-libretech-ac.dtsi`)
defines a `flash@0` node (`compatible = "jedec,spi-nor"`) on the `spifc` bus.
The `spi-nor` kernel driver probes and claims `spi0.0` at boot, so the
`spidev` driver never binds and `/dev/spidev0.0` is never created — even
though SPI is otherwise functional.

**Solution:** Two changes:

1. **`CONFIG_SPI_SPIDEV=y`** in `kernel-fragment.config` — the `spidev`
   driver must be compiled in (not a module) because we use an initramfs with
   no on-disk module tree; `modprobe spidev` would fail at runtime.

2. **`board/rootfs-overlay/etc/init.d/S01spidev`** — a BusyBox init.d script
   that runs before SeedSigner (`S02seedsigner`) and:
   - Unbinds `spi0.0` from the `spi-nor` driver
   - Sets `driver_override = spidev` on the sysfs device node
   - Binds `spi0.0` to `spidev` → kernel creates `/dev/spidev0.0`

   ```sh
   echo spi0.0 > /sys/bus/spi/drivers/spi-nor/unbind
   echo spidev > /sys/bus/spi/devices/spi0.0/driver_override
   echo spi0.0 > /sys/bus/spi/drivers/spidev/bind
   ```

**Relevant files:**
- `board/kernel-fragment.config` — `CONFIG_SPI_SPIDEV=y`
- `board/rootfs-overlay/etc/init.d/S01spidev`

---

### 6. python-embit — AArch64 prebuilt `libsecp256k1`

**Problem:** The `python-embit` package bundles prebuilt `libsecp256k1`
shared libraries for several architectures (`armv6l`, `armv7l`, `aarch64`).
The standard `0001-SeedSignerOS-RPi-Arch.patch` (used for ARM32 Pi targets)
filters the wheel to keep only the ARM32 variants. On AArch64 these are
rejected by Buildroot's `pyinstaller.py` with:

```
ERROR: architecture for libsecp256k1_linux_armv6l.so is "ARM", should be "AArch64"
```

**Solution:** A `PYTHON_EMBIT_POST_PATCH_HOOKS` hook in
`opt/external-packages/python-embit/python-embit.mk` (applied only when
`BR2_aarch64=y`):
- Edits `pyproject.toml` to reference `libsecp256k1_linux_aarch64.so` instead
  of the ARM wildcard
- Physically deletes `libsecp256k1_linux_armv6l.so` and
  `libsecp256k1_linux_armv7l.so` from the source tree so setuptools cannot
  include them regardless of any `SOURCES.txt` manifest

**Relevant files:**
- `opt/external-packages/python-embit/python-embit.mk`
- `opt/external-packages/python-embit/0001-SeedSignerOS-AArch64-Arch.patch`

---

### 7. Kernel — arm64 arch default config + fragment

Rather than a hand-written `defconfig`, the La Frite build uses:

- `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` — the upstream `arm64`
  default config, which includes all Amlogic GXL SoC drivers
  (`CONFIG_ARCH_MESON=y` and its transitive dependencies)
- `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` — a small fragment that forces
  certain drivers from module (`=m`) to built-in (`=y`), required because the
  initramfs has no on-disk module tree

This matches the approach in the upstream Buildroot `lafrite_defconfig`
and avoids the risk of a hand-maintained config missing critical SoC drivers.

**Relevant files:**
- `board/kernel-fragment.config`
- `configs/lafrite-smartcard-dev_defconfig`

---

### 8. `TE: 35043` / `opteed_fast` error at boot

**Symptom:** The boot log shows:

```
ERROR:   Error initializing runtime service opteed_fast
```

**Explanation:** This error is printed by BL31 (ARM Trusted Firmware) when
it cannot find a valid OP-TEE image in the FIP. The Libre Computer FIP from
`boot.libre.computer` is built without OP-TEE (`LBS_OPTEE=0` in the
`libretech-builder-simple` config for this board). BL31 logs the error but
continues booting normally — it is non-fatal and can be ignored.

The board boots successfully past this message.

---

## References

- [Libre Computer La Frite product page](https://libre.computer/products/aml-s805x-ac/)
- [libretech-buildroot](https://github.com/3rdIteration/libretech-buildroot) — reference Buildroot config for La Frite
- [libretech-builder-simple](https://github.com/libre-computer-project/libretech-builder-simple) — upstream Libre Computer build system
- [libre-computer-project/libretech-buildroot](https://github.com/libre-computer-project/libretech-buildroot) — upstream Buildroot configs with La Frite defconfig
- [Buildroot upstream `lafrite_defconfig`](https://github.com/buildroot/buildroot/blob/master/configs/lafrite_defconfig) — authoritative reference for kernel/DTS selection
- [Amlogic GXL boot flow](https://github.com/libre-computer-project/libretech-flash-tool) — libretech-flash-tool documents SD offset and FIP format
