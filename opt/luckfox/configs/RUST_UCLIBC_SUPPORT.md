# Rust uclibc Support for python-cryptography

## Problem

The LuckFox Pico SDK uses a uclibc-based toolchain (`arm-rockchip830-linux-uclibcgnueabihf`).
Buildroot's Rust packages only support glibc and musl targets in their tier lists, so
`BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS` is never set for uclibc. This prevents
`python-cryptography` (and any other Rust-dependent package) from being enabled.

The Rust target `armv7-unknown-linux-uclibceabihf` is a valid Tier 3 target in Rust
(supported since Rust 1.36), but:
- Pre-built `rust-std` binaries are NOT available for Tier 3 targets
- Buildroot's `host-rust-bin` tries to download pre-built `rust-std` which fails
- Buildroot's `host-rust` (build from source) works but needs the tier gate unlocked

## Solution — Two Changes Required in the SDK's Buildroot

### Change 1: `package/rustc/Config.in.host`

Add uclibc as a Tier 3 platform and include it in `BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS`.

**Add this new config block** immediately before the `BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS`
config (after the Tier 2 platforms block):

```kconfig
# Tier 3 uclibc platforms - must be built from source (no pre-built std binaries)
# When adding new entries below, update RUST_TARGETS in utils/update-rust
config BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS
	bool
	# armv7-unknown-linux-uclibceabihf
	default y if BR2_ARM_CPU_ARMV7A && BR2_ARM_EABIHF && BR2_TOOLCHAIN_USES_UCLIBC
	# armv7-unknown-linux-uclibceabihf for armv8 hardware with 32-bit userspace
	default y if BR2_arm && BR2_ARM_CPU_ARMV8A && BR2_ARM_EABIHF && BR2_TOOLCHAIN_USES_UCLIBC
```

**Then add this line** inside `BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS`, after the
existing Tier 2 default:

```kconfig
	default y if BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS
```

### Change 2: `package/rust-bin/rust-bin.mk`

Pre-built `rust-std` binaries don't exist for uclibc Tier 3 targets on
https://static.rust-lang.org/dist/. The `host-rust-bin` package must skip downloading
them. When `host-rust` (build from source) is selected, it builds `rust-std` from source
instead, using `host-rust-bin` only as a bootstrap compiler.

**Replace** the existing conditional download block:

```makefile
ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)
HOST_RUST_BIN_EXTRA_DOWNLOADS += rust-std-$(RUST_BIN_VERSION)-$(RUSTC_TARGET_NAME).tar.xz
endif
```

**With:**

```makefile
# Pre-built rust-std is not available for uclibc Tier 3 targets;
# host-rust (build from source) will compile it instead.
ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)
ifneq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)
HOST_RUST_BIN_EXTRA_DOWNLOADS += rust-std-$(RUST_BIN_VERSION)-$(RUSTC_TARGET_NAME).tar.xz
endif
endif
```

**Replace** the existing conditional install block:

```makefile
ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)
define HOST_RUST_BIN_INSTALL_LIBSTD_TARGET
	(cd $(@D)/std/rust-std-$(RUST_BIN_VERSION)-$(RUSTC_TARGET_NAME); \
		./install.sh $(HOST_RUST_BIN_INSTALL_COMMON_OPTS))
endef
endif
```

**With:**

```makefile
# Skip installing pre-built target std for uclibc (not available);
# host-rust (build from source) provides it.
ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)
ifneq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)
define HOST_RUST_BIN_INSTALL_LIBSTD_TARGET
	(cd $(@D)/std/rust-std-$(RUST_BIN_VERSION)-$(RUSTC_TARGET_NAME); \
		./install.sh $(HOST_RUST_BIN_INSTALL_COMMON_OPTS))
endef
endif
endif
```

## How It Works

After these SDK changes:

1. `BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS=y` is auto-computed for
   armv7 + eabihf + uclibc toolchains
2. `BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS=y` gates open
3. `RUSTC_TARGET_NAME` is set to `armv7-unknown-linux-uclibceabihf`
4. `host-rust` (build from source) can be selected — it uses `host-rust-bin` as a
   bootstrap compiler (host-only, no target std download for uclibc) and then compiles
   the full Rust toolchain + target standard library from source
5. `python-cryptography` becomes available (its `depends on` is satisfied)

## Defconfig Settings (this repository)

With the SDK patches applied, enable in `luckfox_pico_defconfig`:

```
BR2_PACKAGE_HOST_RUSTC=y
BR2_PACKAGE_HOST_RUST=y
BR2_PACKAGE_PROVIDES_HOST_RUSTC="host-rust"
BR2_PACKAGE_PYTHON_CRYPTOGRAPHY=y
```

## Build Time Impact

Building Rust from source (`host-rust`) adds significant time to the first build
(30–60+ minutes depending on the host machine). Subsequent builds use the cached
output unless a clean build is triggered.

## References

- Rust platform support: https://doc.rust-lang.org/nightly/rustc/platform-support.html
- `armv7-unknown-linux-uclibceabihf` is a Tier 3 target (community-supported)
- Buildroot Rust infrastructure: `package/rustc/`, `package/rust/`, `package/rust-bin/`

