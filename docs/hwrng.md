# Hardware entropy across the supported boards

How randomness reaches the SeedSigner app differs per platform, and the differences are not
obvious from the board configs alone. This page records the current state, why each board is
configured the way it is, and how to verify it on a running device.

## How entropy reaches the app

The app never reads a hardware RNG directly. Every path — seed generation, camera entropy,
PIN salts — goes through `os.urandom()`, i.e. the kernel CSPRNG (`getrandom(2)`). **This is
correct and should not change:** the kernel CSPRNG is the right thing to draw key material from.

The question this page answers is a different one: *does the hardware RNG actually reach that
kernel pool?* A CSPRNG produces statistically perfect output whether or not a hardware source is
feeding it, so this cannot be established by looking at `/dev/urandom`.

There are two mechanisms that move bytes from `/dev/hwrng` into the kernel pool, and a board needs
**at least one** of them:

1. **`khwrngd`, the in-kernel filler thread.** `drivers/char/hw_random/core.c` starts it only when
   the registered driver reports a non-zero `quality`. It then credits entropy at
   `quality/1024` bits per bit. Most drivers set no quality at all, in which case this thread
   **never runs**.
2. **`rngd`, from the `rng-tools` package.** A userspace daemon that reads `/dev/hwrng`, runs
   FIPS 140-2 continuous tests on it, and injects the result with an entropy credit via
   `RNDADDENTROPY`. Installed as `/etc/init.d/S21rngd`.

## Current state per board

| Board | RNG driver | Driver `quality` | `khwrngd` runs? | `rngd` | Hardware entropy reaches pool |
|---|---|---|---|---|---|
| Luckfox Pico (RV1103/RV1106) | `rockchip-rng` (`rockchip,trngv1`) | **999** | yes | yes | via both |
| Pi — smartcard builds | `bcm2835-rng` / `iproc-rng200` | 0 | no | yes | via `rngd` |
| Pi — plain builds | `bcm2835-rng` / `iproc-rng200` | 0 | no | yes *(added — see below)* | via `rngd` |
| La Frite (smartcard only) | `meson-rng` | not audited | — | yes | via `rngd` |

### Luckfox Pico

The TRNG on RV1103/RV1106 is **TRNG v1, a separate IP block** (`rng@ff448000`, its own
`HCLK_TRNG_NS` clock) — *not* the RNG that lived inside the crypto block on crypto v1/v2 hardware.
Enabling `&crypto` therefore does **not** give you `/dev/hwrng`; the two are independent.

`rv1106.dtsi` ships `&rng` with `status = "disabled"`, and it is only enabled because upstream
`rv1106-evb.dtsi` — pulled in by every Luckfox board `.dts` — turns it on. Because that is an
uncontrolled upstream dependency, `opt/luckfox/os-build.sh` now pins **both** `&crypto` and `&rng`
to `okay` itself (`enable_dts_node`) and fails the build if either cannot be verified, rather than
inheriting the setting by luck. An SDK bump can no longer silently remove the entropy source.

`rockchip-rng.c` sets `quality = 999`, so `khwrngd` runs and credits roughly 7.8 bits per byte.
`rng-tools` is also installed, giving a second, independently tested path.

> Note: `BR2_PACKAGE_URANDOM_SCRIPTS=y` is selected, but the Luckfox rootfs is a read-only squashfs
> with tmpfs overlays, so the saved seed does **not** survive a power cycle. Every boot starts from
> a cold pool and depends on the TRNG. Combined with there being no RTC, this makes the TRNG
> load-bearing on this platform rather than a nice-to-have.

### Raspberry Pi

`bcm2835-rng` (Pi 0/02W/2) and `iproc-rng200` (Pi 4) **set no `.quality`**, and the hwrng core's
`default_quality` is 0. `khwrngd` therefore never starts, and a userspace read of `/dev/hwrng`
credits nothing. On the Pi, `rngd` is the *only* mechanism that moves hardware entropy into the
pool.

The **smartcard builds have always had `BR2_PACKAGE_RNG_TOOLS=y`**. The plain builds did not, which
meant `/dev/hwrng` existed but nothing ever read it and the hardware RNG contributed zero bits.
`BR2_PACKAGE_RNG_TOOLS=y` has been added to the eight plain board defconfigs
(`pi0`, `pi02w`, `pi2`, `pi4` and their `-dev` variants) so every Pi image behaves the same way.

Two related notes:

- `opt/pi0/board/kernel.config` had `CONFIG_HW_RANDOM` commented out where every other Pi board set
  it explicitly. Because `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` makes that file the whole `.config`
  and `CONFIG_MODULES` is off, `olddefconfig` promoted the Kconfig `default m` to `y` and the driver
  was built anyway — correct, but by accident. It is now set explicitly.
- Every Pi and La Frite board removes `/etc/init.d/S20seedrng` in `post-build.sh`, so no entropy
  seed is carried across reboots on any platform. `rngd` refills the pool at boot instead.

## Verifying on a device

Use a **dev** image — the non-dev UART has no shell.

```sh
# 1. Which RNG is registered?  Expect "rockchip" on Luckfox, "bcm2835-rng" on Pi.
cat /sys/devices/virtual/misc/hw_random/rng_current

# 2. Does the device produce different bytes each read?
cat /dev/hwrng | od -x | head -n 1

# 3. Is the in-kernel filler thread running?  (Luckfox: yes.  Pi: no, by design.)
ps | grep '[h]wrng'

# 4. Is rngd running?  This is the load-bearing one on Pi.
pgrep rngd

# 5. Rockchip hardware crypto algorithms (Luckfox) — currently returns NOTHING; see note below
cat /proc/crypto | grep rk
```

If step 4 fails on a Pi image, the hardware RNG is contributing nothing — that is the exact
regression the `rng-tools` addition prevents.

**Bench-confirmed on a SeedSigner Luckfox Pico Mini NAND build (RV1103, dev, 2026-09):**
`rng_current` reads `rockchip`, the in-kernel `[hwrng]` filler thread **is running** (pid 41),
`/dev/hwrng` returns fresh bytes each read, the boot log shows `random: crng init done`, "Seeding
256 bits and crediting" and `Starting rngd` — so the TRNG path is fully working, both via the
kthread and `rngd`. This is the entropy guarantee this branch was about, and it holds on real
hardware.

> **The hardware *crypto* offload is a different story — it is NOT present, despite the build
> reporting "hardware crypto enabled".** On the booted board `cat /proc/crypto | grep rk` returns
> nothing, `/sys/bus/platform/drivers/` has no crypto driver, and `ff440000.crypto` is unbound.
> Cause: `apply_hwrng_crypto_kernel_patch` sets `CONFIG_CRYPTO_DEV_ROCKCHIP=y` (the umbrella) but
> not `CONFIG_CRYPTO_DEV_ROCKCHIP_V3=y`, which is the sub-option that actually compiles the RV1106
> (crypto-v3) algorithm code — so no driver is built. The build's assertion only greps the
> *defconfig text* for the umbrella symbol, so it passes and prints success while the driver is
> absent from the running kernel. This is harmless for SeedSigner (the app uses software crypto and
> never touches the hardware engine — step 5 is informational), but the enable is currently a no-op:
> pinning `&crypto` in the DTS turns on a node that nothing binds to. Only the `&rng` pin matters.
> To genuinely enable it would need `CONFIG_CRYPTO_DEV_ROCKCHIP_V3=y` plus an assertion that checks
> the built `.config` (or `/proc/crypto`), not the defconfig — but there is no functional reason to,
> so the accurate statement is simply: **hardware crypto acceleration is not enabled; the TRNG is.**

## Known limitation: the app's RNG health monitor

`HardwareRngMonitorThread` in the app repo (`src/seedsigner/hardware/rng_monitor.py`) samples
`os.urandom()` and runs statistical health checks on it — Shannon entropy, stuck-sample and
short-cycle detection.

Because `os.urandom()` is CSPRNG output, **those checks cannot fail even if the hardware RNG has
been dead since boot.** The monitor is a useful guard against a broken `getrandom()`, but despite
its name it says nothing about the TRNG. Detecting a stuck or failed hardware RNG requires reading
`/dev/hwrng` directly, which is what `rngd`'s FIPS tests already do on every board.

Any future change to sample `/dev/hwrng` from the app must account for the platform differences
above: on the Pi the device node exists and is readable even in the failure mode where nothing is
feeding the kernel pool, so merely opening it is not a sufficient health check.

## See also

- [`docs/luckfox/secure-boot.md`](luckfox/secure-boot.md) — OTP, secure boot, and the RV1106 crypto block
- Rockchip Crypto/HWRNG Developer Guide V1.2.1, §2.2 (HWRNG) and §2.2.4 (verification)
