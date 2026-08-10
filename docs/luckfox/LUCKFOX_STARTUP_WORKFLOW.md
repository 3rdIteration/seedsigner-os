# Luckfox Startup Workflow (SeedSigner)

This page documents the runtime startup sequence on Luckfox Pico hardware, with emphasis on execution order and memory behavior on the Luckfox Pico Mini.

## Goal

Bring up:
- SeedSigner UI (`python main.py`)
- Camera stack (`rk_dvbm`, `video_rkisp`, `video_rkcif`, `sc3336`)
- `rkaiq_3A_server` for real-time auto-exposure

while avoiding startup-time memory contention that can crash SeedSigner on Mini.

## Why startup order matters on Mini

The Mini is memory-constrained. If camera services are started too early, SeedSigner can fail opening SPI display resources (`/dev/spidev0.0`) due to memory pressure during init.

Observed reliable behavior:
1. Start SeedSigner first.
2. Wait for display/SPI initialization.
3. Start `rkaiq_3A_server` afterward.

Observed unreliable behavior:
1. Start `rkaiq_3A_server` first.
2. Then start SeedSigner.
3. SeedSigner may fail during startup (display init).

## Current runtime components

### Entry point
- `buildroot/files/S99seedsigner`
  - Executes `/start-seedsigner.sh`

### Main orchestrator
- `buildroot/files/start-seedsigner.sh`
  - Kills stale `rkipc`
  - Optionally bootstraps camera graph via temporary `rkipc`
  - Runs retry loop for SeedSigner startup
  - Configures button GPIO pins via `/usr/bin/configure-gpio.sh` before each launch attempt
  - Starts camera service only after app init conditions are met

### GPIO configuration
- `buildroot/files/configure-gpio.sh` (installed as `/usr/bin/configure-gpio.sh`)
  - Auto-detects LuckFox Pico variant from `/proc/device-tree/model`
  - Writes IOMUX, pull-up, direction, and input-enable registers for all button pins
  - Uses busybox `io` for raw register writes (see [GPIO button configuration](#gpio-button-configuration) below)

### Camera service wrapper
- `buildroot/files/rkaiq-service` (installed as `/usr/bin/rkaiq-service`)
  - Loads camera kernel modules if missing
  - Exports `LD_LIBRARY_PATH` for Rockchip libs
  - Starts/stops `/oem/usr/bin/rkaiq_3A_server`
  - Writes logs to `/tmp/rkaiq_3A_server.log`

## GPIO button configuration

### What happens

Before each SeedSigner launch attempt, `start-seedsigner.sh` runs
`/usr/bin/configure-gpio.sh`.  This script auto-detects the LuckFox Pico
variant by reading `/proc/device-tree/model` and then writes the correct
RV1106 hardware registers for every button GPIO pin so that each pin is
configured as:

1. **IOMUX → GPIO function** — selects the GPIO mux option (value 0) instead
   of an alternate peripheral function.
2. **Pull → pull-up** — enables the internal pull-up resistor so that
   active-low buttons read HIGH when idle.
3. **Direction → input** — sets the GPIO data-direction register (DDR) bit
   to 0 (input).
4. **Input Enable (IE) → on** — enables the input buffer so that reads
   return the actual pin level.

The register values are written with the busybox `io` utility (`io -4 <addr> <value>`) which performs raw 32-bit memory-mapped I/O.  All writes use the
Rockchip write-with-mask format where bits [31:16] are the write-enable
mask and bits [15:0] are the value, ensuring only the targeted bit fields
are modified.

### Why standard Linux GPIO tools don't work on RV1106

GPIO configuration on the RV1106 **cannot** be reliably done through normal
Linux userspace interfaces:

| Approach | Problem on RV1106 |
|---|---|
| **`python-periphery` `bias="pull_up"`** | The RV1106 pinctrl driver does not implement `gpio_set_config` for bias. The `GPIO_V2_LINE_FLAG_BIAS_PULL_UP` flag is accepted but **silently ignored** — the pull resistor is never enabled. |
| **`/dev/mem` mmap writes** | The kernel's `CONFIG_STRICT_DEVMEM` blocks writes to IOC physical addresses with `EFAULT` (errno 14). Python `mmap` + `struct.pack_into` triggers a `SIGBUS` (hardware data-abort, uncatchable) on TrustZone-protected IOC registers. |
| **`libgpiod` / `gpioset`** | Can set direction but has no API for IOMUX selection, pull bias, or input-buffer enable on this SoC. |
| **`sysfs` GPIO interface** | Legacy interface with the same limitations — no control over IOMUX, pull, or IE registers. |

The only reliable userspace method is the busybox **`io`** command, which
uses `/dev/mem` reads and single-word `write()` syscalls.  Unlike
mmap-based approaches, the kernel's `write_mem()` path succeeds for these
IOC registers.

### Variant auto-detection

`configure-gpio.sh` reads `/proc/device-tree/model` (stripping null bytes
and lowercasing) and maps the string to a hardware profile:

| Model string contains | Profile | Connector |
|---|---|---|
| `luckfox pico mini` | FOX_22 | 22-pin |
| `luckfox pico pro max` | FOX_40 | 40-pin |
| `luckfox pico pi` | FOX_PI | 40-pin (Pi-style) |
| `luckfox pico pro` / `plus` / `max` | FOX_40 | 40-pin |
| `luckfox pico` (base, no qualifier) | FOX_22 | 22-pin |

Each profile configures the eight button pins (KEY_UP, KEY_DOWN, KEY_LEFT,
KEY_RIGHT, KEY_PRESS, KEY1, KEY2, KEY3) as defined in the SeedSigner
`io_config.json` for that variant.

### GPIO4 special case

GPIO4 is in the VCCIO6 power domain and uses a different pull-bias
encoding from GPIO0–GPIO3:

- GPIO0–3: `0` = normal, `1` = pull-up, `2` = pull-down
- GPIO4:   `0` = normal, `1` = pull-down, **`3` = pull-up**

The `configure_GPIO4_C1()` function in the script handles this difference.

### `/dev/gpiochip4` missing on Pico Mini

On the Luckfox Pico Mini the Linux kernel's device tree **omits the GPIO2
bank entirely**.  Because the kernel assigns `/dev/gpiochipN` numbers
sequentially (one per registered bank), all banks above GPIO1 are shifted
down by one:

| GPIO bank | Pi / Pro / Max | Mini (GPIO2 absent) |
|-----------|----------------|---------------------|
| GPIO0 | `/dev/gpiochip0` | `/dev/gpiochip0` |
| GPIO1 | `/dev/gpiochip1` | `/dev/gpiochip1` |
| GPIO2 | `/dev/gpiochip2` | *(not registered)* |
| GPIO3 | `/dev/gpiochip3` | `/dev/gpiochip2` |
| GPIO4 | `/dev/gpiochip4` | `/dev/gpiochip3` |

Any profile that references `/dev/gpiochip4` (e.g. for GPIO4_C0/C1 pins)
will crash without the path present:

```
periphery.gpio.GPIOError: [Errno 2] Opening GPIO chip: No such file or directory
```

**Fix:** `start-seedsigner.sh` calls `ensure_gpiochip_symlinks()` once at
startup before the retry loop.  On **Mini**, because the GPIO2-absent shift
is a static hardware fact, the symlink is created directly without any sysfs
scanning:

```
/dev/gpiochip4  ->  /dev/gpiochip3   (on Mini, always)
```

The symlink is created **unconditionally on Mini** — regardless of which
pins the current `io_config.json` profile happens to reference.  This
future-proofs the boot against profile changes and avoids fragile sysfs
label matching.

On variants where GPIO2 is present (Pi, Pro, Max), `/dev/gpiochip4`
already exists as a real device node, so the function returns immediately.
For those variants, if `/dev/gpiochip4` were ever absent, the function falls
back to a dynamic sysfs search anchored on the GPIO4 controller's fixed
hardware address (`0xff560000`).

### Reference

The full register-level reference for all RV1106 GPIO pins (addresses,
bit positions, and ready-to-use `io` commands) is in:

> **`docs/Rockchip_RV1106_User_Manual_GPIO.pdf`**
> ([original source](https://github.com/user-attachments/files/16725839/Rockchip_RV1106_User_Manual_GPIO.pdf))

Pin-to-button mappings for each variant come from the SeedSigner
`io_config.json`:

> **`src/seedsigner/hardware/io_config.json`** in the
> [seedsigner repo](https://github.com/3rdIteration/seedsigner/tree/dev)

## No boot autostart for camera service

`rkaiq-service` is intentionally installed to `/usr/bin/rkaiq-service` (not as `/etc/init.d/S50...`) so it is not started by generic boot order before SeedSigner.

SeedSigner controls when camera service starts.

## Adaptive retry logic

`start-seedsigner.sh` includes adaptive behavior to handle board and boot-media timing differences (SPI-NAND vs microSD):

- On each retry:
  - Stop camera service (`rkaiq-service stop`)
  - Kill stale `rkipc`
  - Restart SeedSigner cleanly
- Camera service start is delayed until:
  - SeedSigner process is alive
  - SPI init signal is detected (via process fds), then an additional delay is applied
- Delay increases slightly per retry:
  - `camera_post_spi_delay = CAMERA_POST_SPI_DELAY + retry_count`

This gives the UI more headroom to initialize first, especially on Mini and on slower boot timing paths.

## Why `rkaiq_3A_server` is required

The critical function provided by `rkaiq_3A_server` is:
- **real-time automatic exposure adjustment** for camera capture.

Without it, camera frames may be available but exposure behavior is degraded/static.

## Field validation checklist

After boot:

1. Verify media/video nodes:
```sh
ls -l /dev/media* /dev/video* /dev/v4l-subdev* 2>/dev/null
```

2. Verify SeedSigner + camera service processes:
```sh
ps | grep -E "python|rkaiq_3A_server|rkipc" | grep -v grep
```

3. Check startup and camera logs:
```sh
tail -n 120 /tmp/startup.log
tail -n 120 /tmp/rkaiq_3A_server.log
```

4. Verify GPIO configuration ran (look for "GPIO button configuration complete"):
```sh
grep configure-gpio /tmp/startup.log
```

5. Functional check in app:
- Camera scan works
- Exposure adjusts dynamically in changing light
- All buttons respond (up, down, left, right, press, key1, key2, key3)

## microSD filesystem corruption (read-only state)

### Symptom

The microSD card occasionally becomes stuck in a **read-only** state after an
unexpected power-off.  All write operations fail silently or with "Read-only
file system" errors, and the condition persists across reboots until the card
is repaired on a PC.

### Root cause

When the system loses power while filesystem writes are in progress, the
on-disk journal may be left in an inconsistent state.  On the next mount the
kernel's ext4 driver detects the inconsistency and automatically **remounts
the partition read-only** to prevent further corruption.  This is a
kernel-level safety mechanism — it is not a hardware fault and does not mean
the card is damaged.

### How to detect it

Check the kernel log immediately after boot:

```sh
dmesg | grep -E "(remount|EXT4-fs error|I/O error|read-only|JBD2|journal commit)"
```

A read-only remount looks like:

```
EXT4-fs error (device mmcblk1p5): ...
EXT4-fs (mmcblk1p5): Remounting filesystem read-only
```

You can also inspect the mount flags directly:

```sh
mount | grep mmcblk
```

A healthy rootfs shows `rw`; a remounted-RO partition shows `ro`.

### Fix

Connect the microSD card to a PC (or a Linux host) and run `fsck` on the
affected partition.  The partition containing the rootfs is typically
the fifth partition on the LuckFox image layout.

> ⚠️ **Replace `X` with your actual device letter** (e.g., `b`, `c`, `d`) before
> running these commands.  Use `lsblk` or `fdisk -l` to identify the correct
> device.  Running `fsck` on the wrong device can cause data loss.

```sh
# Identify the card — look for the device whose size matches your microSD
lsblk

# Unmount the partition first if it is auto-mounted
sudo umount /dev/sdX5

# Run fsck in automatic-repair mode (-y answers "yes" to all questions)
sudo fsck -y /dev/sdX5
```

On Windows, use the built-in **Scan and Fix** prompt that appears when the
drive is inserted, or run `chkdsk X: /f` in an administrator command prompt
(only effective for FAT/exFAT partitions — for ext4 use a Linux environment
such as WSL2 or a live USB).

After `fsck` completes successfully, re-insert the card; the kernel will
mount it read-write on the next boot.

### Prevention

The root cause is always an unclean shutdown.  Best practices:

1. **Always shut down gracefully** — from within the SeedSigner app, use the
   power-off / shutdown option if one is available, or run `halt` / `shutdown -h now`
   via SSH before removing power.
2. **Sync writes before power-off** — if you must cut power, run `sync` first
   from a shell to flush all buffered writes to the card.
3. **Use a good-quality microSD card** — cards rated for frequent
   write cycles (e.g., A1/A2 application-class or industrial-grade cards)
   handle unexpected power loss more reliably.

## Notes for future changes

- Treat startup order as a functional requirement, not just cleanup.
- Test both Mini and Max, and both SPI-NAND and microSD boot timing.
- If memory regressions reappear, adjust post-SPI camera delay and retry backoff before changing camera features.
