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

### 5. SPI — `spicc` (40-pin header) disabled by default; `spifc` claims `spi0`

**Problem:** The La Frite device tree has TWO SPI controllers:

| Controller | Linux name | Purpose |
|------------|-----------|---------|
| `spifc` | `spi0` (upstream alias) | Dedicated SPI NOR flash controller → on-board 16 MB W25Q32 flash |
| `spicc` | `spi1` (upstream, disabled) | General-purpose SPI communication controller → 40-pin header |

SeedSigner's display and peripherals connect via the **40-pin header SPI pins**
(Pin 19 MOSI/GPIOX_8, Pin 21 MISO/GPIOX_9, Pin 23 CLK/GPIOX_11, Pin 24 CE0/GPIOX_10),
which map to `spicc`.

The upstream `meson-gxl-s805x-libretech-ac.dts` has:
- `spi0 = &spifc` — NOR flash controller aliased as spi0
- `spicc` — **disabled** (status = "disabled" from parent DTSI)

So the upstream DTS gives `/dev/spidev0.0` to the NOR flash bus, and the
40-pin header SPI does not exist in `/dev` at all.

An earlier incorrect fix tried to unbind `spi-nor` from `spifc` and bind `spidev`
— this would create `/dev/spidev0.0` on the wrong bus (the NOR flash controller),
not the 40-pin header.

**Solution:** A custom board DTS (`board/meson-gxl-s805x-libretech-ac.dts`) that:
1. Overrides the `spi0` alias to point to `spicc` instead of `spifc`
2. Enables `spicc` with `spi_pins` pinctrl (GPIOX_8/9/11 mux) and CS on GPIOX_10
3. Adds a `spidev@0` child node (`compatible = "rohm,dh2228fv"`)

```dts
aliases {
    spi0 = &spicc;  /* 40-pin header: pins 19/21/23/24 */
};

&spicc {
    status = "okay";
    pinctrl-0 = <&spi_pins>;
    pinctrl-names = "default";
    cs-gpios = <&gpio GPIOX_10 GPIO_ACTIVE_LOW>;

    spidev@0 {
        compatible = "rohm,dh2228fv";
        reg = <0>;
        spi-max-frequency = <41666666>;
    };
};
```

`spifc` (NOR flash controller) is kept enabled — it is still needed for the
on-board flash used by the bootloader.

`CONFIG_SPI_MESON_SPICC=y` and `CONFIG_SPI_SPIDEV=y` are added to the kernel
fragment to ensure both drivers are compiled in (not as modules — initramfs has
no on-disk module tree).

Based on: `libre-computer-project/libretech-wiring-tool` overlays
`spi-cc-1cs.dts` + `spi-cc-1cs-spidev.dts`.

**Relevant files:**
- `board/meson-gxl-s805x-libretech-ac.dts` — custom DTS with SPICC enabled
- `board/kernel-fragment.config` — `CONFIG_SPI_MESON_SPICC=y`, `CONFIG_SPI_SPIDEV=y`
- `configs/lafrite-smartcard-dev_defconfig` — `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH`

---

### 5a. UART - keep debug console on pins 3/5, enable UART-A on pins 8/10

The existing debug console remains on the board's current serial port and is
unchanged by the custom DTS. Enabling `uart_A` adds a second UART on the 40-pin
header:

- Pin 8 - TX (`GPIOX_12`)
- Pin 10 - RX (`GPIOX_13`)

This mirrors the `libretech-wiring-tool` UART-A overlay for `aml-s805x-ac`.
It only enables the hardware and pin mux. It does not move the kernel console
or login shell away from the existing debug UART.

**Relevant files:**
- `board/meson-gxl-s805x-libretech-ac.dts` - enables `&uart_A` with `uart_a_pins`

---

### 6. python-embit — `libsecp256k1` built for the target

**Background:** embit up to 0.8.0 bundled prebuilt `libsecp256k1` libraries
for several architectures, and La Frite (AArch64) needed a hook to swap in the
`aarch64` one; Buildroot's `pyinstaller.py` rejects the ARM32 ones with
`architecture for libsecp256k1_linux_armv6l.so is "ARM", should be "AArch64"`.

**Now (embit 0.8.2):** embit ships no binaries. `python-embit.mk` builds
`libsecp256k1` from the `secp256k1-zkp` commit embit pins, with the target
compiler, so every board -- AArch64 included -- gets a library for its own
architecture with no per-arch handling. It is installed as
`embit/util/prebuilt/libsecp256k1.so`. There is no pure-Python fallback: the
package patches `secp256k1.py` to bind only the compiled library, removes
`py_secp256k1.py`, and fails the build if the library lacks any symbol the
bindings use; `verify-secp256k1-binary.sh` (end of `post-build.sh`) checks the
final image.

**Relevant files:**
- `opt/external-packages/python-embit/python-embit.mk`
- `opt/external-packages/python-embit/0001-SeedSignerOS-secp256k1-compiled-library-only.patch`
- `opt/external-packages/python-embit/verify-secp256k1-binary.sh`

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

One exception is the onboard Ethernet MAC: the La Frite uses the Meson
DesignWare MAC path, which needs both the `stmmac` core and the Meson glue
driver built in for an initramfs-only boot. The board fragment explicitly
forces `CONFIG_STMMAC_ETH=y`, `CONFIG_DWMAC_MESON=y`, `CONFIG_PHYLIB=y`, and
`CONFIG_MESON_GXL_PHY=y` so Linux registers `eth0` instead of booting with
only `lo` present.

**Relevant files:**
- `board/kernel-fragment.config`
- `configs/lafrite-smartcard-dev_defconfig`

---

### 8. `efi_mgr` boot — EFI NVRAM boot variables override extlinux

**Symptom:** U-Boot's `bootflow list` shows only:
```
  0  efi_mgr      ready   (none)       0
```
and the boot does not use `extlinux/extlinux.conf`. The `efi_mgr` bootmeth
reads EFI boot variables from the SPI NOR flash (NVRAM emulation). If a
previous experiment (e.g., testing EFI partition type `0xEF`) wrote an EFI
boot entry to NVRAM, it persists and wins.

**Solution:** A `boot.scr` (compiled from `board/boot.cmd` via `mkimage`) is
placed in the root of the FAT boot partition. U-Boot's `script` bootmeth
finds `boot.scr` and executes it before the NVRAM-backed `efi_mgr` boots.
The script explicitly calls `sysboot` to load `extlinux/extlinux.conf`,
ensuring the correct kernel, DTB, and cmdline are always used.

**Relevant files:**
- `board/boot.cmd` — source for boot.scr; compiled to `boot.scr` by Buildroot
- `configs/lafrite-smartcard-dev_defconfig` — `BR2_PACKAGE_HOST_UBOOT_TOOLS=y` + `BR2_PACKAGE_HOST_UBOOT_TOOLS_BOOT_SCRIPT_SOURCE`
- `board/genimage-seedsigner.cfg` — `boot.scr` added to the boot.vfat file list

---

### 9. `TE: 35043` / `opteed_fast` error at boot

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
