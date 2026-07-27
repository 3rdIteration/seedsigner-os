# Build Profiles

SeedSigner OS supports multiple hardware platforms, each with variations for different use cases. This document explains the profile naming conventions, the differences between profile types, and how they're implemented at each build level.

## Profile Naming Convention

Profiles follow this pattern: `{board}[-smartcard][-dev]`

| Component | Values | Description |
|-----------|--------|-------------|
| `{board}` | `pi0`, `pi02w`, `pi2`, `pi4`, `lafrite` | Target hardware platform |
| `-smartcard` | present / absent | Includes NFC reader + JavaCard smartcard tooling |
| `-dev` | present / absent | Development build with networking, SSH, debug tools |

**Current profiles:**

| Profile | Hardware | Smartcard | Dev | Status |
|---------|----------|-----------|-----|--------|
| `pi0-smartcard` | Raspberry Pi Zero W | Yes | No | Production |
| `pi02w-smartcard` | Raspberry Pi Zero 2 W | Yes | No | Production |
| `pi2-smartcard` | Raspberry Pi 2 | Yes | No | Production |
| `pi4-smartcard` | Raspberry Pi 4 | Yes | No | Production |
| `pi0-smartcard-dev` | Raspberry Pi Zero W | Yes | Yes | Development |
| `pi02w-smartcard-dev` | Raspberry Pi Zero 2 W | Yes | Yes | Development |
| `pi2-smartcard-dev` | Raspberry Pi 2 | Yes | Yes | Development |
| `pi4-smartcard-dev` | Raspberry Pi 4 | Yes | Yes | Development |
| `lafrite-smartcard-dev` | La Frite (AML-S805X-AC) | Yes | Yes | Development |

## Dev vs Non-Dev Differences

Development builds (`-dev`) include networking, SSH access, and debugging tools. Production builds (non-dev) are air-gapped, minimal, and produce deterministic reproducible output images.

### Buildroot Packages (defconfig)

| Feature | Dev | Non-Dev |
|---------|-----|---------|
| SSH server (`dropbear`) | Included | Removed |
| Package managers (`git`, `pip`, `setuptools`, `wheel`) | Included | Removed |
| HTTP clients (`curl`, `wget`, `libcurl`, `nghttp2`) | Included | Removed |
| WiFi tools (`wpa_supplicant`, `iw`, `wireless-tools`, `wireless-regdb`) | Included | Removed |
| DHCP client | Enabled (`eth0 wlan0`) | Removed |
| Text editors (`nano`, `mc`) | Included | Removed (`pinentry-tty` only) |
| CA certificates | Included | Removed |

### Busybox Applets

| Feature | Dev | Non-Dev |
|---------|-----|---------|
| `ifconfig` | Enabled | Disabled |
| `ip` (iproute2 suite) | Enabled | Disabled |
| `ping` / `ping6` | Enabled | Disabled |
| `udhcpc` (DHCP client) | Enabled | Disabled |
| `wget` | Enabled | Disabled |
| `netstat`, `nslookup`, `route`, `arp` | Enabled | Disabled |

### Kernel Configuration

The most significant difference between dev and non-dev builds. Non-dev kernels strip networking stack and display output to reduce attack surface and image size.

**Networking (disabled in non-dev):**

| Option | Dev | Non-Dev | Purpose |
|--------|-----|---------|---------|
| `CONFIG_INET` | Enabled | Disabled | IPv4 protocol stack |
| `CONFIG_IPV6` | Enabled | Disabled | IPv6 protocol stack |
| `CONFIG_NETDEVICES` | Enabled | Disabled | Network device framework |
| `CONFIG_PACKET` | Enabled | Disabled | Raw packet sockets |
| `CONFIG_PHYLIB` | Enabled | Disabled | PHY device library |
| WiFi drivers (`CFG80211`, `MAC80211`, `BRCMFMAC`) | Enabled (Pi) | Disabled | Wireless networking |
| Ethernet controller (`BCMGENET`) | Enabled (Pi) | Disabled | Pi onboard ethernet |
| USB network drivers (~30 options) | Enabled | Disabled | USB ethernet adapters |

**Display/HDMI (disabled in non-dev):**

| Option | Dev | Non-Dev | Purpose |
|--------|-----|---------|---------|
| `CONFIG_DRM` | Enabled | Disabled | Direct Rendering Manager |
| `CONFIG_FRAMEBUFFER_CONSOLE` | Enabled | Disabled | Text console on framebuffer |
| `CONFIG_AUXDISPLAY` | Enabled (Pi dev) | Disabled | Auxiliary display devices |
| `CONFIG_DMABUF_HEAPS` (+ SYSTEM, CMA) | Enabled (Pi dev) | Disabled | DMA buffer sharing for HDMI |

**Other kernel differences:**

| Option | Dev | Non-Dev | Reason |
|--------|-----|---------|--------|
| `CONFIG_IKCONFIG` | Built-in (`y`) | Module (`m`) | Kernel config access at runtime |
| `CONFIG_PREEMPT` | Voluntary | Full preempt | Deterministic scheduling for production |
| Initramfs compression | GZIP | LZ4 | Faster boot time in production |

**Note:** `CONFIG_NET=y` and `CONFIG_UNIX=y` remain enabled in both modes. The SeedSigner OS initramfs requires basic kernel networking infrastructure for internal operations, but with `INET`, `IPV6`, and `NETDEVICES` disabled, there is no network stack or device access available to user-space.

**Implementation approaches:**
- **Pi profiles**: Full `kernel.config` files. Dev configs add networking/display options at the bottom of an otherwise identical base config.
- **Lafrite profile**: Uses `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` (arm64 upstream defconfig) with a kernel fragment. The non-dev fragment explicitly disables networking and display options that the arch default enables, while keeping only the built-in drivers needed for initramfs boot (serial console, MMC, SPI).

### Image Creation Method

| Aspect | Dev | Non-Dev |
|--------|-----|---------|
| Tool | `genimage` | Manual deterministic script |
| Reproducibility | No (timestamps vary) | Yes (deterministic output) |
| FAT32 filesystem | Standard `mkfs.vfat` | `mkfs.vfat --invariant` (no random UUID, fixed timestamp) |
| Partition label ID | Random | Fixed (`ba5eba11`) |
| File timestamps | Build-time | Normalized to `2023/01/01T12:15:05` |
| Bootloader hash | Downloaded without verification (dev) / cached via `wget -nc` | SHA-256 verified (`download_and_verify()`) |

Non-dev images are designed to be **byte-identical across builds** from the same commit. This enables:
- Release image checksums that can be verified by end users
- Detection of supply-chain tampering
- Reliable A/B testing of build changes via diff

### Rootfs Overlay Structure

| Directory | Dev | Non-Dev | Contents |
|-----------|-----|---------|----------|
| `board/rootfs-overlay/` | Yes | Yes | Shared: mdev.conf, reader.conf.d (hardware config) |
| `../rootfs-overlay-dev/` | Copied by post-build.sh | Not present | Dev-only: MicroSD source override startup script |

Dev profiles' `post-build.sh` copies files from the shared `rootfs-overlay-dev/` directory into the target rootfs. This overlay contains a startup script that allows overriding the application source from a `src/` directory on the MicroSD card — useful for iterative development without rebuilding. Non-dev builds don't include this capability.

## Smartcard vs Non-Smartcard Differences

Smartcard profiles add NFC reading and JavaCard smartcard provisioning capabilities.

| Feature | Smartcard | Non-Smartcard |
|---------|-----------|---------------|
| **NFC Stack** | `libnfc-pn532-i2c`, `ifdnfc`, `openct`, `nfc-bindings` | Not included |
| **CCID (USB smartcard)** | `ccid`, `ccid-sec1210` | Not included |
| **Python crypto** | `pycryptodome-x`, `gnupg2`, `pgpy`, `pygp`, `specter-card` | Minimal (`ecdsa`, `pyaes`) |
| **Smartcard Python** | `pysatochip`, `keycard-py`, `pyscard` | Not included |
| **DIY Tools** | `diy-tools.squashfs` (Java JDK, Ant, Satochip source) on boot partition | Not included |
| **Pinentry** | `pinentry-ncurses` (TTY-based) | `pinentry-tty` only |
| **Headless mode** | Yes — no display output needed | Uses SeedSigner LCD UI |

The smartcard stack enables the device to act as a hardware wallet via NFC tap or USB CCID, compatible with standard PC/SC readers and GnuPG. The DIY tools squashfs contains everything needed to personally fabricate and program a Satochip JavaCard at home.

## Reproducibility

Non-dev builds target full reproducibility: same commit produces byte-identical `.img` files regardless of build machine or time.

**Key mechanisms:**
1. `BR2_REPRODUCIBLE=y` in defconfig — strips timestamps from Buildroot packages
2. `SOURCE_DATE_EPOCH=1` and `PYTHONHASHSEED=0` for python bytecode compilation
3. `mkfs.vfat --invariant` — eliminates random UUIDs and build-time timestamps from FAT32
4. Fixed partition label ID (`ba5eba11`) across all profiles
5. All file timestamps on boot partition normalized to `2023/01/01T12:15:05`
6. External downloads verified against SHA-256 checksums (bootloader, Java JDK, Ant, Satochip source)
7. Non-deterministic files removed in post-build (cryptography RECORD, python pyc files with host paths)

**Dev builds are not reproducible** — they use `genimage` which embeds build-time metadata, and include packages that may have non-deterministic build artifacts. This is acceptable since dev images are only used for local development and testing.
