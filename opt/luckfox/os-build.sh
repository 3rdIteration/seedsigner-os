#!/bin/bash
# SeedSigner Self-Contained Build Script - No Home Directory Pollution!
# All repositories cloned inside container - completely portable

set -e

# Environment setup - everything happens inside /build
export BUILD_DIR="/build"
export REPOS_DIR="/build/repos"
export OUTPUT_DIR="/build/output"

# Repository URLs for cloning
export LUCKFOX_REPO_URL="https://github.com/3rdIteration/luckfox-pico.git"
# Overridable defaults, matching build-luckfox.yml's seedsigner_repo_url /
# seedsigner_branch inputs. These were hard assignments, which silently discarded
# whatever the caller passed in -- so a local build ALWAYS built `dev` no matter
# what branch was asked for, and the resulting image differed from CI in the one
# component that is not pinned by this repo. See also: the build records the app
# branch, not its commit, so "dev" is not a fixed target either.
export SEEDSIGNER_REPO_URL="${SEEDSIGNER_REPO_URL:-https://github.com/3rdIteration/seedsigner.git}"
# May be a branch, a release tag or a commit -- `git clone -b` accepts all three.
export SEEDSIGNER_BRANCH="${SEEDSIGNER_REF:-${SEEDSIGNER_BRANCH:-dev}}"
# Build variant: non-dev (hardened/air-gapped) or dev. Mirrors build-luckfox.yml's build_variant.
export SEEDSIGNER_BUILD_VARIANT="${SEEDSIGNER_BUILD_VARIANT:-non-dev}"
# USB role (mirrors build-luckfox.yml's usb_mode): gadget|host|otg|auto.
# auto follows the variant: non-dev = host (no adb/RNDIS, drives USB
# peripherals), dev = gadget (adb). Applied via opt/luckfox/configure-usb-mode.sh.
export SEEDSIGNER_USB_MODE="${SEEDSIGNER_USB_MODE:-auto}"
# Ethernet debug channel (mirrors build-luckfox.yml's debug_network): on|off|auto.
# auto follows the variant: non-dev = off (no interface bring-up, no telnet),
# dev = on. Applied via harden-nondev.sh's HARDEN_DISABLE_NETWORK.
export SEEDSIGNER_DEBUG_NETWORK="${SEEDSIGNER_DEBUG_NETWORK:-auto}"
# Read-only (squashfs) rootfs with tmpfs overlays: auto|on|off. auto follows the
# build variant, matching the CI input of the same name.
export SEEDSIGNER_READONLY_ROOTFS="${SEEDSIGNER_READONLY_ROOTFS:-auto}"
# Persistent boot log (mirrors build-luckfox.yml's boot_log): on|off. on bakes
# /etc/seedsigner-boot-log so start-seedsigner.sh records every boot to /userdata.
# Default off: a production device must write nothing to flash.
export SEEDSIGNER_BOOT_LOG="${SEEDSIGNER_BOOT_LOG:-off}"
# Strip the adb userspace on non-dev (mirrors build-luckfox.yml's harden_adb):
# on|off. build.sh has always forwarded this variable, but nothing here read it,
# so --harden-adb off was silently ignored on every Docker build while CI
# honoured it -- the exact kind of CI/local divergence that makes an image
# impossible to reproduce locally. Applied as HARDEN_DISABLE_ADB below.
export SEEDSIGNER_HARDEN_ADB="${SEEDSIGNER_HARDEN_ADB:-on}"
# Rootfs verification (only with SEEDSIGNER_FIT_SIGNATURE=1): dir holding a
# minisign dev.key/dev.pubkey pair used to sign the rootfs volume's logical
# UBIFS contents at build time. Default: the committed PUBLIC dev keypair in
# secure-boot/dev-keys-rootfs/ (see its README — grants no protection, keeps
# signed builds reproducible and the failure mode recoverable).
export SEEDSIGNER_ROOTFS_KEY_DIR="${SEEDSIGNER_ROOTFS_KEY_DIR:-}"
# Passphrase for that secret key. The committed dev key uses the documented
# public passphrase "seedsigner-dev"; a real key via SEEDSIGNER_ROOTFS_KEY_DIR
# must set this explicitly (no default — an empty prompt would hang the build).
export SEEDSIGNER_ROOTFS_KEY_PASSPHRASE="${SEEDSIGNER_ROOTFS_KEY_PASSPHRASE:-}"
# Rebuild the four vendored initramfs binaries from source at build time and
# overwrite the committed copies before their SHA-256 pins are checked. Off by
# default: the committed binaries ARE the reviewed, pinned artifacts (see
# secure-boot/initramfs-binaries/README.md). When on, a rebuild that does not
# reproduce the pinned bytes exactly fails the build loudly — the pins act as
# a live determinism canary, so they must never be auto-updated. Requires
# network access for the checksum-pinned source downloads.
export SEEDSIGNER_REBUILD_INITRAMFS_BINARIES="${SEEDSIGNER_REBUILD_INITRAMFS_BINARIES:-0}"
# SeedSigner OS Buildroot packages now live in this same repo. build.sh mounts
# opt/external-packages into the container at /build/external-packages, so there
# is no seedsigner-os clone.

# Internal paths (after cloning)
export LUCKFOX_SDK_DIR="$REPOS_DIR/luckfox-pico"
export SEEDSIGNER_CODE_DIR="$REPOS_DIR/seedsigner"
# Converged SeedSigner Buildroot packages, mounted from this repo's opt/external-packages
export SEEDSIGNER_OS_PACKAGES_DIR="${SEEDSIGNER_OS_PACKAGES_DIR:-/build/external-packages}"
export SEEDSIGNER_LUCKFOX_DIR="/build"

# Common paths (computed after SDK directory is determined)
# Placeholder only. The real path is resolved from the unpacked SDK by
# ensure_buildroot_tree() via resolve-buildroot-dir.sh, because the buildroot
# version is chosen by the SDK revision, not by us. Hard-coding it here is what
# broke every Docker build when the SDK moved to buildroot-2024.11.4.
export BUILDROOT_DIR="${LUCKFOX_SDK_DIR}/sysdrv/source/buildroot/UNRESOLVED"
export PACKAGE_DIR="${BUILDROOT_DIR}/package"
export CONFIG_IN="${PACKAGE_DIR}/Config.in"
export PYZBAR_PATCH="${PACKAGE_DIR}/python-pyzbar/0001-PATH-fixed-by-hand.patch"
export ROOTFS_DIR="${LUCKFOX_SDK_DIR}/output/out/rootfs_uclibc_rv1106"

# Parallel build configuration.
#
# The default is nproc CAPPED BY MEMORY, not nproc. This build compiles host-rust
# from source -- and therefore LLVM -- because the Docker path never caches a
# toolchain the way CI does. LLVM's X86/AArch64 codegen translation units are
# among the largest C++ compiles in common use, several GB of RSS each. On a
# 32-core machine, -j32 asks for tens of GB at peak; when the host cannot supply
# it the compiler is OOM-killed and the build dies at ~97% with a bare
#
#   gmake[3]: *** [.../lib/Target/X86/CMakeFiles/LLVMX86CodeGen.dir/all] Error 2
#
# which names no cause and looks like a compiler bug rather than a resource
# limit. ~2 GB per parallel job is the usual rule of thumb for building LLVM.
#
# An explicit BUILD_JOBS (or `--jobs N`) always wins; this only sets the default.
# Note /proc/meminfo inside the container reports the memory the container can
# actually use -- on WSL2 that is the WSL VM's allocation, not the Windows host's,
# which is exactly the number that matters here.
_ss_cpu_jobs="$(nproc)"
_ss_mem_gb="$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)"
if [[ "${_ss_mem_gb:-0}" -gt 0 ]]; then
    _ss_mem_jobs=$(( _ss_mem_gb / 2 ))
    [[ "$_ss_mem_jobs" -lt 1 ]] && _ss_mem_jobs=1
    if [[ "$_ss_mem_jobs" -lt "$_ss_cpu_jobs" ]]; then
        _ss_default_jobs="$_ss_mem_jobs"
    else
        _ss_default_jobs="$_ss_cpu_jobs"
    fi
else
    _ss_default_jobs="$_ss_cpu_jobs"
fi
export BUILD_JOBS="${BUILD_JOBS:-$_ss_default_jobs}"

# DO NOT export MAKEFLAGS="-j$BUILD_JOBS" here. It corrupts the image.
#
# GNU make propagates MAKEFLAGS into every sub-make, including the SDK's
# sysdrv build, and sysdrv/Makefile is not parallel-safe:
#
#     rootfs: rootfs_prepare pctools buildroot boardtools drv
#     rootfs_prepare: ; rm -rf $(SYSDRV_DIR_OUT_ROOTFS) ...
#
# Those are sibling prerequisites with no ordering between them and no
# .NOTPARALLEL in the file, and rootfs_prepare `rm -rf`s the very directory
# boardtools installs into. Serial make walks prerequisites left to right, so
# rootfs_prepare runs first and everything is fine -- which is what the
# validated CI workflow gets, because it never sets MAKEFLAGS. Under -j they
# race, and when rootfs_prepare loses the race it deletes the board tools that
# were already installed. The rootfs tarball is then sealed without them.
#
# Observed exactly that: the Docker image was missing 84 files against the CI
# image -- eudev, mtd-utils, rockchip_test, memtester, stressapptest, adbd,
# usbdevice and the dosfstools binaries S02fsck needs -- with 0 extra files,
# every time. In the CI log `prepare rootfs` runs first; in the Docker log it
# ran after the boardtools installs.
#
# BR2_JLEVEL still gives Buildroot its parallelism (that is Buildroot's own
# knob and does not leak into sysdrv), and build-local.sh has never exported
# MAKEFLAGS either, so this brings all three builds into line. The wall-clock
# cost is nil: the CI build without MAKEFLAGS took 3h30, the Docker build with
# it took 3h46.
export BR2_JLEVEL="${BUILD_JOBS}"

# LLVM's per-translation-unit cost (~2 GB) is the heaviest in buildroot, and
# x.py sets LLVM's cmake --parallel to num_cpus() on its own -- it does NOT
# honour MAKEFLAGS/BR2_JLEVEL (nor CMAKE_BUILD_PARALLEL_LEVEL), so the caps
# above have no effect on the host-rust (LLVM) compile and a memory-tight
# host OOMs at ~94-97% of the LLVM build with a bare
#   gmake[3]: *** [.../lib/Target/X86/CMakeFiles/LLVMX86CodeGen.dir/all] Error 2
# The rust.mk patch in apply_sdk_patches injects `jobs = $${RUST_BUILD_JOBS}`
# into config.toml's [build] section, which x.py honours for both `x.py build`
# and `x.py dist`. RUST_BUILD_JOBS defaults to half of BUILD_JOBS (LLVM ~2 GB
# per job vs typical C ~1 GB per job), keeping the LLVM compile within the
# memory budget the overall -j already targets; on a 16 GB host this is ~4.
# Override explicitly with RUST_BUILD_JOBS=<n>.
if (( BUILD_JOBS > 1 )); then
    _ss_rust_default_jobs=$(( BUILD_JOBS / 2 ))
else
    _ss_rust_default_jobs=1
fi
export RUST_BUILD_JOBS="${RUST_BUILD_JOBS:-$_ss_rust_default_jobs}"
export FORCE_UNSAFE_CONFIGURE=1
# Reproducible builds: the epoch compilers and packaging tools stamp into their
# output. Same value and same reasoning as the Pi/La Frite path (opt/build.sh:5),
# which the Luckfox build never picked up. e2fsprogs honours it for ext4
# superblock times, for example. It does NOT reach U-Boot's FIT `timestamp`
# field: the SDK ships U-Boot 2017.09, whose mkimage stamps time(NULL) into
# boot.img/uboot.img regardless (verified against shipped CI images), and its
# RSA-PSS signing draws a random salt -- so even with this epoch set, two signed
# builds differ in the FIT timestamp AND every signature byte. That is why
# deterministic_sign_chain() re-signs all four images with our own tools after
# the SDK's sign_boot_image: digest-derived salts + zeroed timestamps make the
# final signatures byte-identical across builds of the same commit.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

# Kernel reproducibility. Without these the kernel records the build time, the
# building user and the host name, so boot.img differs on every build -- the
# FIT data-size moved by 152 bytes between two builds of identical source.
# These are the kernel's own documented knobs (Documentation/kbuild).
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-@${SOURCE_DATE_EPOCH}}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-seedsigner}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-seedsigner-os}"
export BUILD_MODEL="${BUILD_MODEL:-both}"
export MINI_CMA_SIZE="${MINI_CMA_SIZE:-1M}"
# Serial console (ttyFIQ0). Accepts auto|true|false and the legacy 1|0, matching
# build-luckfox.yml's disable_uart2_console_debug input.
#
# The default used to be a flat 1 -- console always stripped, whatever the
# variant -- while CI's "auto" keeps the console on a dev build. So a Docker dev
# image had no serial console and the CI dev image did, from the same source.
# That is the whole point of a dev image, and it is not something you discover
# until the board is on the bench and silent.
#
# Resolved after SEEDSIGNER_BUILD_VARIANT is known, in resolve_uart2_console().
export DISABLE_UART2_CONSOLE_DEBUG="${DISABLE_UART2_CONSOLE_DEBUG:-auto}"
export DEFAULT_PYTHON_VERSION="${DEFAULT_PYTHON_VERSION:-3.12}"
# Host Rust toolchain cache (see rust-toolchain-cache.sh). Unset = no caching,
# i.e. host-rust (and therefore LLVM) is compiled from source every build, which
# is what the Docker path always did. build.sh sets this when given --cache-dir;
# CI sets it and wraps the directory in actions/cache. Deliberately outside the
# SDK tree, which prepare-sdk-checkout.sh wipes before every build.
export RUST_TOOLCHAIN_CACHE="${RUST_TOOLCHAIN_CACHE:-}"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_step() { echo -e "\n${BLUE}[STEP] $1${NC}\n"; }
print_success() { echo -e "\n${GREEN}[SUCCESS] $1${NC}\n"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}\n"; }
print_info() { echo -e "\n${YELLOW}[INFO] $1${NC}\n"; }
# Was missing while two call sites used it (the ifd-ccid.bundle removal and the
# rkaiq-service check). Under `set -e` an undefined command exits 127, so the
# build died outright the first time either branch was taken -- which only
# happened once the build got far enough for those files to exist.
# build-local.sh has always defined it; this is the two drifting apart again.
print_warning() { echo -e "\n${YELLOW}[WARNING] $1${NC}\n"; }

# Normalise DISABLE_UART2_CONSOLE_DEBUG to a plain 1|0 before anything reads it,
# applying the same rule as build-luckfox.yml: an explicit true/false (or the
# legacy 1/0) wins; auto follows the build variant -- non-dev strips the serial
# console, dev keeps it. The three apply_uart2_* functions below then only ever
# see 1 or 0, so the policy lives in exactly one place.
resolve_uart2_console() {
    case "$DISABLE_UART2_CONSOLE_DEBUG" in
        1|true)  DISABLE_UART2_CONSOLE_DEBUG=1 ;;
        0|false) DISABLE_UART2_CONSOLE_DEBUG=0 ;;
        *)
            if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
                DISABLE_UART2_CONSOLE_DEBUG=1
            else
                DISABLE_UART2_CONSOLE_DEBUG=0
            fi
            ;;
    esac
    export DISABLE_UART2_CONSOLE_DEBUG
}
resolve_uart2_console

# Run an SDK build stage with address-space randomisation disabled.
#
# The Rockchip image tools write uninitialised host memory into the FIT
# /memreserve/ entries of uboot.img and boot.img. Two builds of identical
# source produced, respectively:
#
#     /memreserve/ 0x7c00b3301000 0x600;
#     /memreserve/ 0x73874da5c000 0x600;
#
# Those are host mmap addresses -- so the value changes with ASLR on every
# single run, and no amount of SOURCE_DATE_EPOCH will settle it. Disabling
# randomisation makes the leaked pointers constant, which makes the images
# reproducible without changing what the tools actually do. Zeroing the
# entries afterwards would alter image semantics; this does not.
#
# This is a workaround for an SDK bug and is worth reporting upstream.
# setarch is util-linux and present in the build image; if it is somehow
# missing, fall back to running unwrapped rather than failing the build.
sdk_build() {
    if command -v setarch >/dev/null 2>&1; then
        setarch "$(uname -m)" -R ./build.sh "$@"
    else
        print_warning "setarch unavailable -- FIT /memreserve/ will vary between builds"
        ./build.sh "$@"
    fi
}

# Deterministic tarball. Plain `tar -czf` records each entry's mtime, uid/gid and
# whatever order readdir happened to return, and gzip stamps its own header with
# the current time -- so the three bundles below differed on every build even
# when their contents were byte-identical. Same treatment the Pi/La Frite rootfs
# archive gets in opt/build.sh:340.
#
# --sort=name fixes entry order, --mtime/--owner/--group fix the metadata, and
# gzip -n omits the timestamp and original filename from the gzip header.
SS_REPRODUCIBLE_MTIME="@${SOURCE_DATE_EPOCH:-0}"
ss_tar_deterministic() {  # <output.tar.gz> <-C dir> <member>
    local out="$1" dir="$2" member="$3"
    tar --sort=name \
        --mtime="$SS_REPRODUCIBLE_MTIME" \
        --owner=root:0 --group=root:0 --numeric-owner \
        --format=gnu \
        -cf - -C "$dir" "$member" | gzip -n > "$out"
    touch -d "@${SOURCE_DATE_EPOCH:-0}" "$out"
}

debug_uart_bootargs_file() {
    local file_path="$1"
    local label="$2"
    print_info "UART bootargs debug (${label}): $file_path"
    if [[ -f "$file_path" ]]; then
        grep -nE 'ttyFIQ0|console=|earlycon=|user_debug=|CMDLINE|BOOTARGS' "$file_path" || echo "  (no matching bootarg tokens)"
    else
        echo "  (file not found)"
    fi
}

debug_uart_bootargs_outputs() {
    local image_dir="$LUCKFOX_SDK_DIR/output/image"
    print_info "UART bootargs debug (output image files): $image_dir"
    if [[ ! -d "$image_dir" ]]; then
        echo "  (output image directory not found)"
        return
    fi

    local found=false
    local f
    for f in "$image_dir"/*.txt "$image_dir"/*.cfg "$image_dir"/*.ini "$image_dir"/parameter*; do
        [[ -e "$f" ]] || continue
        found=true
        echo "  checking: $(basename "$f")"
        grep -nE 'ttyFIQ0|console=|earlycon=|user_debug=|CMDLINE|BOOTARGS' "$f" || echo "    (no matching bootarg tokens)"
    done

    if [[ "$found" == "false" ]]; then
        echo "  (no text-like image metadata files found)"
    fi
}

resolve_dts_path_for_profile() {
    local board_profile="$1"
    local dts_dir="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts"
    local dts_file=""

    case "$board_profile" in
        mini)
            dts_file="$dts_dir/rv1103g-luckfox-pico-mini.dts"
            ;;
        max)
            dts_file="$dts_dir/rv1106g-luckfox-pico-pro-max.dts"
            ;;
        pi)
            dts_file="$dts_dir/rv1106g-luckfox-pico-pi.dts"
            ;;
        *)
            print_error "Unsupported board profile for DTS patch: $board_profile"
            exit 1
            ;;
    esac

    if [[ ! -f "$dts_file" ]]; then
        print_error "DTS file not found for UART2 console patch: $dts_file"
        exit 1
    fi

    echo "$dts_file"
}

resolve_dtsi_path_for_profile() {
    local board_profile="$1"
    local dts_dir="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts"
    local dtsi_file=""

    case "$board_profile" in
        mini)
            dtsi_file="$dts_dir/rv1103-luckfox-pico-ipc.dtsi"
            ;;
        max)
            dtsi_file="$dts_dir/rv1106-luckfox-pico-pro-max-ipc.dtsi"
            ;;
        pi)
            dtsi_file="$dts_dir/rv1106-luckfox-pico-pi-ipc.dtsi"
            ;;
        *)
            print_error "Unsupported board profile for DTSI patch: $board_profile"
            exit 1
            ;;
    esac

    if [[ ! -f "$dtsi_file" ]]; then
        print_error "DTSI file not found for UART2 console patch: $dtsi_file"
        exit 1
    fi

    echo "$dtsi_file"
}

show_usage() {
    echo "SeedSigner Self-Contained Build System"
    echo "Usage: $0 [auto|auto-nand|auto-nand-only|interactive|shell|clone-only]"
    echo ""
    echo "  auto        - Run full automated SD-card image build (default)"
    echo "  auto-nand   - Run automated build + NAND-flashable image packaging"
    echo "  interactive - Clone repos + drop into interactive shell"
    echo "  shell       - Drop directly into shell (no setup)"
    echo "  clone-only  - Only clone repositories and exit"
    echo ""
    echo "Features:"
    echo "  - All repositories cloned inside container"
    echo "  - No host directory pollution"
    echo "  - Self-contained and portable"
    echo "  - SD artifacts for multiple board labels (default: mini,max)"
    echo "  - Model selector via BUILD_MODEL=mini|max|pi|both"
    echo "  - Mini CMA override via MINI_CMA_SIZE (default: 1M)"
    echo "  - 'both' builds mini+max; use 'pi' to build the Pico Pi (eMMC only)"
    echo "  - UART2 console toggle via DISABLE_UART2_CONSOLE_DEBUG=auto|true|false (default: auto)"
    echo "    auto follows the variant: non-dev strips the console, dev keeps it"
    echo "  - SDK revision pinned by opt/luckfox/SDK_COMMIT"
    echo "    (override with LUCKFOX_COMMIT=<sha> or LUCKFOX_BRANCH=<branch>)"
    echo ""
}

clone_repositories() {
    print_step "Cloning Required Repositories"
    
    mkdir -p "$REPOS_DIR"
    cd "$REPOS_DIR"
    
    # Put the SDK on the pinned revision, in a pristine tree. NOT a bare
    # `if [[ ! -d luckfox-pico ]]`: that clone was unpinned (default branch,
    # whatever it meant that day) AND reused a tree the previous build had
    # already patched in place, since $REPOS_DIR is a Docker volume that
    # outlives the build. Shared with CI and build-local.sh -- see
    # prepare-sdk-checkout.sh for the full account.
    bash "$SEEDSIGNER_LUCKFOX_DIR/prepare-sdk-checkout.sh" "$REPOS_DIR" "$LUCKFOX_REPO_URL"
    
    # SeedSigner OS Buildroot packages are part of this repo and mounted at
    # $SEEDSIGNER_OS_PACKAGES_DIR (see build.sh); nothing to clone here.

    # Put the SeedSigner app checkout on exactly $SEEDSIGNER_BRANCH. NOT a bare
    # `if [[ ! -d seedsigner ]]`: $REPOS_DIR is a Docker volume that outlives
    # the build, so an existing checkout used to be reused and the requested
    # ref silently ignored -- see prepare-app-checkout.sh. Shared with CI
    # (build-luckfox.yml) and build-local.sh.
    bash "$SEEDSIGNER_LUCKFOX_DIR/prepare-app-checkout.sh" "$REPOS_DIR" "$SEEDSIGNER_BRANCH" "$SEEDSIGNER_REPO_URL"

    # The app MUST carry the boot-watchdog liveness signal (it writes
    # /tmp/seedsigner-ready): a signal-less ref builds green, but the image
    # boots the app fine and then reboots into Loader 120 s later, on every
    # boot. Runs after the clone-or-reuse decision so a stale reused checkout
    # is caught too. Shared with CI via assert-app-watchdog-signal.sh.
    bash "$SEEDSIGNER_LUCKFOX_DIR/assert-app-watchdog-signal.sh" "$SEEDSIGNER_CODE_DIR"

    # Compile translation catalogs (.po -> .mo) + slim fonts in the checkout so
    # the image ships multi-language support. Must run before the checkout is
    # copied into the rootfs / l10n/ is pruned. Degrades to English-only if the
    # container python toolchain is unavailable.
    if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/compile-translations.sh" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/compile-translations.sh" "$SEEDSIGNER_CODE_DIR" \
          || print_info "Translation compile skipped (image will be English-only)"
    fi
    
    # Show repository status
    print_info "Repository Status:"
    echo "  luckfox-pico: $(du -sh luckfox-pico 2>/dev/null | cut -f1 || echo 'missing')"
    echo "  seedsigner: $(du -sh seedsigner 2>/dev/null | cut -f1 || echo 'missing')"
    echo "  Total: $(du -sh . 2>/dev/null | cut -f1 || echo 'unknown')"
    
    print_success "All repositories cloned successfully"
}

apply_sdk_patches() {
    print_step "Applying SeedSigner SDK Patches"

    # Partition layout is shared with CI via apply-partition-layout.sh. It used to
    # be duplicated here, and the copy had drifted badly: this function DELETED the
    # userdata partition (20M(oem),99M(rootfs) plus a sed stripping the
    # userdata@/userdata@ubifs mount) while CI kept it. Locally built images
    # therefore had nowhere to persist settings or write a boot log -- and since
    # the rootfs became read-only squashfs, nowhere writable at all.
    bash "$SEEDSIGNER_LUCKFOX_DIR/apply-partition-layout.sh" "$LUCKFOX_SDK_DIR"

    # Pin ubinize's image_seq and mksquashfs's timestamps. Must run before
    # `build.sh rootfs`, because the pctools step copies these scripts from
    # sysdrv/tools/pc into sysdrv/out/pc and it is the copies that get used.
    bash "$SEEDSIGNER_LUCKFOX_DIR/patch-fs-determinism.sh" "$LUCKFOX_SDK_DIR"

    # Rootfs minisign hooks for signed builds: sign the rootfs during `build.sh
    # firmware` (same pctools-copy constraint as above). No-op unless
    # SEEDSIGNER_FIT_SIGNATURE=1. The UBI hook covers NAND (squashfs/ubifs packed
    # into a UBI volume by mkfs_ubi.sh's embedded call); the squashfs hook covers
    # MicroSD/eMMC, where build_mkimg writes a raw-partition squashfs through
    # mkfs_squashfs.sh and no UBI is involved. Both write per-image outputs, so a
    # multi-profile run never clobbers another medium's signature.
    if [[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/patch-mkfs-ubi-signing.sh" "$LUCKFOX_SDK_DIR"
        bash "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/patch-mkfs-squashfs-signing.sh" "$LUCKFOX_SDK_DIR"
    fi

    # /bin/sdkinfo carries a live build timestamp. project/build.sh's
    # __PACKAGE_ROOTFS() (invoked during `./build.sh firmware`) does:
    #
    #     cat >$RK_PROJECT_PACKAGE_ROOTFS_DIR/bin/sdkinfo <<EOF
    #     echo Build Time:  $(date "+%Y-%m-%d-%T")
    #     ...
    #
    # Patching the FILE this generates is useless -- __PACKAGE_ROOTFS runs
    # during firmware packaging, after everything else, and rewrites it fresh
    # every time. Patching the GENERATOR is the only thing that works.
    # Confirmed: two builds shipped sdkinfo build times exactly as far apart as
    # the two runs were, i.e. genuinely live, not a stale cached value.
    local project_build_sh="$LUCKFOX_SDK_DIR/project/build.sh"
    if [[ ! -f "$project_build_sh" ]]; then
        print_error "$project_build_sh not found -- cannot pin sdkinfo Build Time"
        exit 1
    fi
    # The idempotency check and the post-sed verification both look for the
    # SAME marker (a literal "-d @", which only the patched form contains) --
    # not for "$(date", which is present in both the patched and unpatched
    # line and so cannot tell them apart. An earlier version checked for the
    # substituted EPOCH VALUE rather than this marker, which is never present
    # as that literal string; the verification always failed and exit 1'd on
    # every single run, patched or not.
    if grep -q 'echo Build Time:.*date -u -d @' "$project_build_sh"; then
        print_info "sdkinfo Build Time already pinned (idempotent re-run)"
    else
        sed -i "s|echo Build Time:  \$(date \"+%Y-%m-%d-%T\")|echo Build Time:  \$(date -u -d @${SOURCE_DATE_EPOCH:-0} \"+%Y-%m-%d-%T\")|" "$project_build_sh"
        if grep -q 'echo Build Time:.*date -u -d @' "$project_build_sh"; then
            print_success "sdkinfo Build Time pinned to SOURCE_DATE_EPOCH in project/build.sh"
        else
            print_error "Failed to pin sdkinfo Build Time in $project_build_sh"
            grep -n 'Build Time' "$project_build_sh" || true
            exit 1
        fi
    fi

    # stressapptest embeds its own build stamp -- same class of problem as
    # sdkinfo, different mechanism. Its configure.ac has:
    #
    #     timestamp=$(date)
    #     AC_DEFINE_UNQUOTED([STRESSAPPTEST_TIMESTAMP],
    #                        "$username @ $hostname on $timestamp", ...)
    #
    # and the SDK ships a pre-generated `configure` with that line already
    # expanded verbatim, so a plain sed on the committed script is enough --
    # no autoreconf involved. $username/$hostname are already covered: the
    # container runs as root with a fixed --hostname (opt/luckfox/build.sh),
    # so this is the one remaining live value.
    #
    # The SDK's own Makefile already seds this exact `configure` for an
    # unrelated fix (an armv7a detection bug), immediately before running it,
    # so a sibling sed line is the established pattern here, not a new one.
    # That Makefile rule only re-extracts+builds when
    # sysdrv/tools/board/stressapptest/out/bin/stressapptest is absent -- true
    # on every build starting from a pristine SDK, since that path is
    # untracked build output.
    #
    # Delegated to Python rather than shell: the text being inserted is a
    # MAKEFILE RECIPE that itself contains a shell `sed` command, so a literal
    # `$(` that must survive both Make's expansion and the shell's quoting
    # needs `$$(` in the Makefile source -- three semantic layers deep. Getting
    # that right by hand in bash produced a syntax-breaking mess on the first
    # attempt; Python string concatenation with explicit chr() for backslash
    # and newline is unambiguous, and this exact approach was verified with
    # `make --just-print` (confirms the shell receives the sed argument
    # exactly as intended) and by executing the patched line twice (confirms
    # it evaluates to a fixed value both times).
    local stressapptest_mk="$LUCKFOX_SDK_DIR/sysdrv/tools/board/stressapptest/Makefile"
    if [[ -f "$stressapptest_mk" ]]; then
        SS_EPOCH="${SOURCE_DATE_EPOCH:-0}" python3 - "$stressapptest_mk" <<'PYEOF'
import io, os, sys

path = sys.argv[1]
epoch = os.environ.get("SS_EPOCH", "0")
BS, NL, TAB = chr(92), chr(10), chr(9)

s = io.open(path, encoding='utf-8').read()

marker = "timestamp=$$(date)"
if marker in s:
    print("stressapptest build timestamp already pinned (idempotent re-run)")
    sys.exit(0)

anchor = (TAB + TAB + 'sed -i "s/' + BS + '*armv7a' + BS + '*) :/ arm '
          + BS + '| &/" ./configure; ' + BS + NL)
if anchor not in s:
    print("ERROR: armv7a anchor line not found in " + path, file=sys.stderr)
    sys.exit(1)

inject = (TAB + TAB + "sed -i 's|timestamp=$$(date)|timestamp=$$(date -u -d @"
          + epoch + ")|' ./configure; " + BS + NL)

s = s.replace(anchor, anchor + inject, 1)
io.open(path, 'w', encoding='utf-8').write(s)

if marker not in s:
    print("ERROR: patch did not take in " + path, file=sys.stderr)
    sys.exit(1)
print("stressapptest build timestamp pinned to SOURCE_DATE_EPOCH=" + epoch)
PYEOF
        ss_status=$?
        if [[ $ss_status -ne 0 ]]; then
            print_error "Failed to pin stressapptest build timestamp in $stressapptest_mk"
            exit 1
        fi
        print_success "stressapptest build timestamp step complete"
    else
        print_info "stressapptest Makefile not found at $stressapptest_mk -- skipping (SDK layout may have changed)"
    fi
}

validate_environment() {
    print_step "Validating Build Environment"
    
    local required_dirs=(
        "$LUCKFOX_SDK_DIR"
        "$SEEDSIGNER_CODE_DIR"
        "$SEEDSIGNER_OS_PACKAGES_DIR"
    )

    local required_items=(
        "$LUCKFOX_SDK_DIR/build.sh"
        "$SEEDSIGNER_CODE_DIR/src"
        "$SEEDSIGNER_OS_PACKAGES_DIR"
    )
    
    local missing_dirs=()
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs+=("$dir")
            echo "[ERROR] Missing: $dir"
        else
            echo "[OK] Found: $dir"
        fi
    done
    
    local missing_items=()
    for item in "${required_items[@]}"; do
        if [[ ! -e "$item" ]]; then
            missing_items+=("$item")
            echo "[ERROR] Missing: $item"
        else
            echo "[OK] Found: $item"
        fi
    done
    
    if [[ ${#missing_dirs[@]} -ne 0 || ${#missing_items[@]} -ne 0 ]]; then
        print_error "Environment validation failed"
        echo "Missing directories: ${missing_dirs[*]}"
        echo "Missing items: ${missing_items[*]}"
        echo "Try running with 'clone-only' mode first to setup repositories"
        exit 1
    fi
    
    print_success "Environment validation complete"
}

setup_sdk_environment() {
    print_step "Setting Up SDK Environment"
    
    cd "$LUCKFOX_SDK_DIR"
    
    # Initialize SDK if needed (creates .BoardConfig.mk)
    if [[ ! -f ".BoardConfig.mk" ]]; then
        print_info "Initializing SDK (first time setup)..."
        # Run the SDK init which creates the board config
        echo -e "\n\n\n" | timeout 10s ./build.sh lunch 2>/dev/null || {
            print_info "SDK lunch completed (timeout expected)"
        }
    fi
    
    # Source the toolchain environment
    local toolchain_dir="$LUCKFOX_SDK_DIR/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf"
    if [[ -f "$toolchain_dir/env_install_toolchain.sh" ]]; then
        print_info "Sourcing toolchain environment..."
        cd "$toolchain_dir"
        set +e  # Temporarily disable exit on error
        source env_install_toolchain.sh 2>/dev/null
        local source_result=$?
        set -e  # Re-enable exit on error
        
        cd "$LUCKFOX_SDK_DIR"
        print_success "Toolchain environment configured"
    else
        print_error "Toolchain environment script not found at: $toolchain_dir/env_install_toolchain.sh"
        exit 1
    fi
}



select_board_profile() {
    local board_profile="$1"
    local boot_medium="$2"

    local hw_index
    local boot_index

    case "$board_profile" in
        mini)
            hw_index=1
            ;;
        max)
            hw_index=4
            ;;
        pi)
            hw_index=7
            ;;
        *)
            print_error "Unsupported board profile: $board_profile (expected: mini,max,pi)"
            exit 1
            ;;
    esac

    case "$boot_medium" in
        sd)
            boot_index=0
            ;;
        nand)
            boot_index=1
            ;;
        emmc)
            boot_index=0
            ;;
        *)
            print_error "Unsupported boot medium: $boot_medium (expected: sd,nand,emmc)"
            exit 1
            ;;
    esac

    print_step "Selecting SDK board profile: ${board_profile} (${boot_medium})"
    printf "%s
%s
0
" "$hw_index" "$boot_index" | ./build.sh lunch
}


apply_mini_cma_profile() {
    if [[ "$board_profile" != "mini" ]]; then
        return
    fi

    print_step "Applying Mini CMA profile (${MINI_CMA_SIZE})"

    local cfg_dir="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC"
    if [[ ! -d "$cfg_dir" ]]; then
        print_error "BoardConfig directory not found: $cfg_dir"
        exit 1
    fi

    local cfg_files=("$cfg_dir"/BoardConfig-*-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk)
    local found=false

    for cfg in "${cfg_files[@]}"; do
        [[ -f "$cfg" ]] || continue
        found=true
        if grep -q '^export RK_BOOTARGS_CMA_SIZE=' "$cfg"; then
            sed -i "s|^export RK_BOOTARGS_CMA_SIZE=.*|export RK_BOOTARGS_CMA_SIZE=\"${MINI_CMA_SIZE}\"|" "$cfg"
        else
            echo "export RK_BOOTARGS_CMA_SIZE=\"${MINI_CMA_SIZE}\"" >> "$cfg"
        fi
        print_info "Updated CMA size in: $cfg"
    done

    if [[ "$found" == "false" ]]; then
        print_error "No Mini board config files found under: $cfg_dir"
        exit 1
    fi
}

apply_uart2_console_config() {
    local board_profile="$1"
    local boot_medium="$2"

    if [[ "$DISABLE_UART2_CONSOLE_DEBUG" != "1" ]]; then
        print_info "UART2 console debug left enabled (DISABLE_UART2_CONSOLE_DEBUG=${DISABLE_UART2_CONSOLE_DEBUG})"
        return
    fi

    local sdk_hardware
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max) sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi) sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)
            print_error "Unsupported board profile for UART2 console config: $board_profile"
            exit 1
            ;;
    esac

    local sdk_boot_medium
    case "$boot_medium" in
        sd) sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *)
            print_error "Unsupported boot medium for UART2 console config: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"

    print_step "Disabling UART2 console debug in board config (${board_profile}/${boot_medium})"
    if [[ ! -f "$board_config" && -L "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        board_config="$(readlink -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk")"
    fi

    if [[ ! -f "$board_config" ]]; then
        print_error "Board config file not found for UART2 console config: $board_config"
        exit 1
    fi

    debug_uart_bootargs_file "$board_config" "before patch"
    sed -i 's/\<console=ttyFIQ0[^ "]*\>//g; s/\<earlycon=uart8250,[^ "]*\>//g; s/\<user_debug=[^ "]*\>//g' "$board_config"
    debug_uart_bootargs_file "$board_config" "after patch"

    if grep -Eq '(^|[[:space:]])console=ttyFIQ0([^[:space:]]*)?([[:space:]]|$)' "$board_config"; then
        print_error "UART2 console debug removal verification failed: console=ttyFIQ0 still present in $board_config"
        exit 1
    fi

    print_success "UART2 console debug disabled in: $board_config"
}

apply_uart2_console_dts_patch() {
    local board_profile="$1"

    if [[ "$DISABLE_UART2_CONSOLE_DEBUG" != "1" ]]; then
        return
    fi

    local dts_file dtsi_file target
    dts_file="$(resolve_dts_path_for_profile "$board_profile")"
    dtsi_file="$(resolve_dtsi_path_for_profile "$board_profile")"

    print_step "Disabling UART2 console debug in DTS sources (${board_profile})"
    for target in "$dts_file" "$dtsi_file"; do
        debug_uart_bootargs_file "$target" "before patch"
        sed -i 's/\<console=ttyFIQ0[^ "]*\>//g; s/\<earlycon=uart8250,[^ "]*\>//g; s/\<user_debug=[^ "]*\>//g' "$target"

        # Enable UART2 as a normal peripheral UART so /dev/ttyS* can be created.
        if grep -Eq '&uart2[[:space:]]*\{' "$target"; then
            sed -i '/&uart2[[:space:]]*{/,/};/ s/status[[:space:]]*=[[:space:]]*"[^"]*"/status = "okay"/' "$target"
        else
            cat >> "$target" <<'EOF'

&uart2 {
	status = "okay";
};
EOF
        fi
        debug_uart_bootargs_file "$target" "after patch"

        if grep -Eq '(^|[[:space:]])console=ttyFIQ0([^[:space:]]*)?([[:space:]]|$)' "$target"; then
            print_error "UART2 console debug removal verification failed in DTS source: $target"
            exit 1
        fi
    done

    print_success "UART2 console debug disabled in DTS sources: $dts_file, $dtsi_file"
}

apply_uart2_fiq_kernel_patch() {
    local board_profile="$1"
    local boot_medium="$2"

    if [[ "$DISABLE_UART2_CONSOLE_DEBUG" != "1" ]]; then
        return
    fi

    local sdk_hardware sdk_boot_medium
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)
            print_error "Unsupported board profile for kernel FIQ patch: $board_profile"
            exit 1
            ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *)
            print_error "Unsupported boot medium for kernel FIQ patch: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [[ ! -f "$board_config" && -L "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        board_config="$(readlink -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk")"
    fi
    if [[ ! -f "$board_config" ]]; then
        print_error "Board config file not found for kernel FIQ patch: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [[ ! -f "$kernel_cfg_file" ]]; then
        print_error "Kernel defconfig not found for FIQ patch: $kernel_cfg_file"
        exit 1
    fi

    print_step "Disabling FIQ debugger in kernel defconfig ($kernel_defconfig)"
    sed -i -E '/^CONFIG_FIQ_DEBUGGER(=|_)/d;/^# CONFIG_FIQ_DEBUGGER is not set$/d' "$kernel_cfg_file"
    echo '# CONFIG_FIQ_DEBUGGER is not set' >> "$kernel_cfg_file"

    # Ensure DesignWare 8250 UART driver path is enabled for RV1106 UARTs.
    sed -i -E '/^CONFIG_SERIAL_8250(=|_)/d;/^# CONFIG_SERIAL_8250 is not set$/d' "$kernel_cfg_file"
    sed -i -E '/^CONFIG_SERIAL_8250_DW(=|_)/d;/^# CONFIG_SERIAL_8250_DW is not set$/d' "$kernel_cfg_file"
    sed -i -E '/^CONFIG_SERIAL_OF_PLATFORM(=|_)/d;/^# CONFIG_SERIAL_OF_PLATFORM is not set$/d' "$kernel_cfg_file"
    {
        echo 'CONFIG_SERIAL_8250=y'
        echo 'CONFIG_SERIAL_8250_DW=y'
        echo 'CONFIG_SERIAL_OF_PLATFORM=y'
    } >> "$kernel_cfg_file"

    if grep -Eq '^CONFIG_FIQ_DEBUGGER(=|_)' "$kernel_cfg_file"; then
        print_error "Kernel FIQ debugger disable verification failed in: $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_SERIAL_8250=y$' "$kernel_cfg_file"; then
        print_error "Kernel serial driver enable verification failed: CONFIG_SERIAL_8250 in $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_SERIAL_8250_DW=y$' "$kernel_cfg_file"; then
        print_error "Kernel serial driver enable verification failed: CONFIG_SERIAL_8250_DW in $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_SERIAL_OF_PLATFORM=y$' "$kernel_cfg_file"; then
        print_error "Kernel serial driver enable verification failed: CONFIG_SERIAL_OF_PLATFORM in $kernel_cfg_file"
        exit 1
    fi
    print_success "Kernel FIQ debugger disabled and serial drivers enabled in: $kernel_cfg_file"
}

apply_kernel_network_strip() {
    local board_profile="$1"
    local boot_medium="$2"

    [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]] || {
        print_info "dev build: kernel networking/WiFi retained"
        return 0
    }

    local sdk_hardware sdk_boot_medium
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *) print_error "Unsupported board profile for kernel network strip: $board_profile"; exit 1 ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *) print_error "Unsupported boot medium for kernel network strip: $boot_medium"; exit 1 ;;
    esac

    local board_config="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [[ ! -f "$board_config" && -L "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        board_config="$(readlink -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk")"
    fi
    if [[ ! -f "$board_config" ]]; then
        print_error "Board config file not found for kernel network strip: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [[ ! -f "$kernel_cfg_file" ]]; then
        print_error "Kernel defconfig not found for network strip: $kernel_cfg_file"
        exit 1
    fi

    # Networking is gated on debug_network (off -> strip) so a non-dev image can
    # still be built with Ethernet + telnet for debugging. WiFi is always
    # stripped on non-dev. Shared with CI via strip-kernel-network.sh.
    local strip_net=1
    if [[ "$SEEDSIGNER_DEBUG_NETWORK" == "on" ]]; then strip_net=0; fi
    export SS_STRIP_NET="$strip_net"

    print_step "Stripping kernel networking/WiFi for non-dev ($kernel_defconfig, net_strip=$strip_net)"
    # The board config is passed too: the SDK builds OUT-OF-TREE wifi drivers when
    # RK_ENABLE_WIFI=y, and they fail modpost once the in-kernel cfg80211 is gone.
    bash "$SEEDSIGNER_LUCKFOX_DIR/strip-kernel-network.sh" \
        "$kernel_cfg_file" "$strip_net" 1 "$board_config" 1

}

# Read-only rootfs (squashfs + tmpfs overlays). Shared with CI via
# readonly-rootfs.sh.
#
# Deliberately NOT gated on non-dev, unlike apply_kernel_network_strip: a dev
# image with a read-only root is the only configuration where the property can
# actually be TESTED, because a hardened image has no shell to check `mount` or
# prove that a write to /etc is discarded. Gating this would silently ignore
# SEEDSIGNER_READONLY_ROOTFS=on for exactly the build used to verify it.
apply_readonly_rootfs() {
    local board_profile="$1"
    local boot_medium="$2"

    local sdk_hardware sdk_boot_medium
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *) print_error "Unsupported board profile for read-only rootfs: $board_profile"; exit 1 ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *) print_error "Unsupported boot medium for read-only rootfs: $boot_medium"; exit 1 ;;
    esac

    local board_config="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [[ ! -f "$board_config" && -L "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        board_config="$(readlink -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk")"
    fi
    if [[ ! -f "$board_config" ]]; then
        print_error "Board config file not found for read-only rootfs: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [[ ! -f "$kernel_cfg_file" ]]; then
        print_error "Kernel defconfig not found for read-only rootfs: $kernel_cfg_file"
        exit 1
    fi

    local ro_rootfs
    case "$SEEDSIGNER_READONLY_ROOTFS" in
        on)  ro_rootfs=1 ;;
        off) ro_rootfs=0 ;;
        # auto: hardened images get an immutable root; dev images keep a writable
        # one so the rootfs can be poked at over the serial console.
        *)   if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then ro_rootfs=1; else ro_rootfs=0; fi ;;
    esac
    # A signed SD/eMMC build MUST have an immutable root: the initramfs verifier
    # streams the raw partition bytes and only knows how to mount squashfs there
    # (a writable ext4 root would stop verifying after the first runtime write,
    # and /init has no case for it at all). Force it on rather than failing late
    # in apply_signed_nand_bootargs — dev signed builds then match non-dev's
    # stack exactly (the debug access lives in userspace: adb/telnet/serial).
    # NAND is exempt: the verifier handles both squashfs and writable UBIFS.
    if [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] && { [ "$boot_medium" = "sd" ] || [ "$boot_medium" = "emmc" ]; } \
       && [ "$ro_rootfs" != 1 ]; then
        print_info "SEEDSIGNER_FIT_SIGNATURE=1 on $boot_medium: forcing read-only squashfs root (the initramfs verifier only supports immutable roots there)"
        ro_rootfs=1
    fi
    export SS_RO_ROOTFS="$ro_rootfs"
    # Recorded for the post-build assertions, which need the same board config.
    export SS_BOARD_CONFIG="$board_config"

    print_step "Configuring read-only rootfs (enabled=$ro_rootfs)"
    bash "$SEEDSIGNER_LUCKFOX_DIR/readonly-rootfs.sh" \
        "$board_config" "$kernel_cfg_file" "$ro_rootfs"
}

# Pin spidev.bufsiz on the kernel command line. Shared with CI via
# pin-spidev-bufsiz.sh — without it the 64 MB Mini fails an order-6 allocation in
# spidev_open() and the display never opens, while the pre-app splash on the same
# boot draws fine. Applies to every board and every variant.
apply_spidev_bufsiz() {
    local board_profile="$1"

    local sdk_hardware
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *) print_error "Unsupported board profile for spidev bufsiz: $board_profile"; exit 1 ;;
    esac

    print_step "Pinning spidev.bufsiz (display SPI open)"
    bash "$SEEDSIGNER_LUCKFOX_DIR/pin-spidev-bufsiz.sh" "$LUCKFOX_SDK_DIR" "$sdk_hardware" 8192
}

# Extend the RV1106 OTP nvmem region so /init can read the secure-boot enable
# fuse (offset 0x80) and show "SECURE BOOT not enabled" on unfused boards.
# Shared with CI via patch-otp-size.sh; applies to every board — all three use
# rv1106_data in rockchip-otp.c (the Mini's RV1103 includes rv1106.dtsi).
# No-op unless SEEDSIGNER_FIT_SIGNATURE=1: unsigned builds keep the kernel
# byte-identical to before this feature.
apply_otp_size_patch() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    print_step "Extending OTP nvmem region for secure-boot fuse read"
    bash "$SEEDSIGNER_LUCKFOX_DIR/patch-otp-size.sh" "$LUCKFOX_SDK_DIR"
}

apply_hwrng_kernel_patch() {
    local board_profile="$1"
    local boot_medium="$2"

    local sdk_hardware sdk_boot_medium
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)
            print_error "Unsupported board profile for HWRNG kernel patch: $board_profile"
            exit 1
            ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *)
            print_error "Unsupported boot medium for HWRNG kernel patch: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [[ ! -f "$board_config" && -L "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        board_config="$(readlink -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk")"
    fi
    if [[ ! -f "$board_config" ]]; then
        print_error "Board config file not found for HWRNG kernel patch: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [[ ! -f "$kernel_cfg_file" ]]; then
        print_error "Kernel defconfig not found for HWRNG patch: $kernel_cfg_file"
        exit 1
    fi

    print_step "Enabling HWRNG in kernel defconfig ($kernel_defconfig)"

    # Enable hardware random number generator
    sed -i -E '/^CONFIG_HW_RANDOM=/d;/^# CONFIG_HW_RANDOM is not set$/d' "$kernel_cfg_file"
    sed -i -E '/^CONFIG_HW_RANDOM_ROCKCHIP=/d;/^# CONFIG_HW_RANDOM_ROCKCHIP is not set$/d' "$kernel_cfg_file"
    {
        echo 'CONFIG_HW_RANDOM=y'
        echo 'CONFIG_HW_RANDOM_ROCKCHIP=y'
    } >> "$kernel_cfg_file"


    if ! grep -Eq '^CONFIG_HW_RANDOM=y$' "$kernel_cfg_file"; then
        print_error "Kernel HWRNG enable verification failed: CONFIG_HW_RANDOM in $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_HW_RANDOM_ROCKCHIP=y$' "$kernel_cfg_file"; then
        print_error "Kernel HWRNG enable verification failed: CONFIG_HW_RANDOM_ROCKCHIP in $kernel_cfg_file"
        exit 1
    fi
    print_success "HWRNG enabled in kernel defconfig: $kernel_cfg_file"
}

# Force a DTS node's status to "okay", appending an override when the board DTS
# does not already reference the node. Returns non-zero if the result cannot be
# verified afterwards.
enable_dts_node() {
    local node="$1"
    local dts_file="$2"

    if grep -Eq "&${node}[[:space:]]*[{]" "$dts_file"; then
        sed -i "/&${node}[[:space:]]*{/,/};/ s/status[[:space:]]*=[[:space:]]*\"[^\"]*\"/status = \"okay\"/" "$dts_file"
    else
        printf '\n&%s {\n\tstatus = "okay";\n};\n' "$node" >> "$dts_file"
    fi

    awk -v node="$node" '
        $0 ~ "&" node "[[:space:]]*[{]" { found = 1 }
        found && /status[[:space:]]*=[[:space:]]*"okay"/ { ok = 1 }
        /\};/ { if (found) exit }
        END { exit !ok }
    ' "$dts_file"
}

# rng: TRNG v1. On RV1103/RV1106 this is a SEPARATE IP block (rng@ff448000, its
#      own HCLK_TRNG_NS clock), not the RNG that lived inside the crypto block on
#      crypto v1/v2 hardware. rv1106.dtsi ships &rng disabled and it is only
#      "okay" today because upstream rv1106-evb.dtsi happens to enable it, so pin
#      it here -- an SDK bump must not silently drop the hardware entropy source.
#
# The hardware crypto engine (&crypto / CONFIG_CRYPTO_DEV_ROCKCHIP) is NOT
# enabled: SeedSigner uses software crypto, and on RV1106 that driver needs the
# CRYPTO_DEV_ROCKCHIP_V3 sub-option to build at all -- confirmed absent on a
# flashed image (empty /proc/crypto, unbound crypto node). Pinning only &rng is
# deliberate; do not re-add &crypto without also building the driver.
# Make the MicroSD slot usable as removable storage on the NAND / eMMC profiles.
#
# The controller on the sdmmc0 pins IS enabled in the stock device tree, but it
# is configured as an SDIO interface - the upstream Luckfox default for the
# Wi-Fi board variants:
#
#     /mmc@ffaa0000  status = okay
#         pinctrl-0 = sdmmc0-clk, sdmmc0-cmd, sdmmc0-det, sdmmc0-bus4
#         supports-sdio, cap-sdio-irq, non-removable, no-mmc, no-1-8-v
#
# `non-removable` makes the kernel ignore the sdmmc0-det card-detect line and
# `supports-sdio` makes it probe as an SDIO function, so no /dev/mmcblk block
# device is ever created. That, and not /etc/luckfox.cfg, is why a NAND-booted
# Luckfox has no MicroSD in Linux. Verified by reading the built kernel DTB out
# of boot.img on mini and max.
#
# SD_CARD profiles are left alone: there the same controller already carries the
# rootfs (root=/dev/mmcblk1p6), so it is configured as storage already and the
# one slot is occupied anyway.
apply_sdmmc_dts_patch() {
    local board_profile="$1" boot_medium="$2"

    case "$boot_medium" in
        nand|emmc) ;;
        *) return 0 ;;
    esac

    local dts_file
    dts_file="$(resolve_dts_path_for_profile "$board_profile")"

    # Find the label of the controller that owns the sdmmc0 pins, rather than
    # assuming it. A wrong label would otherwise fail deep inside dtc.
    local dts_dir="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts"
    local label
    label="$(grep -rhoE '^[[:space:]]*[a-z0-9_]+:[[:space:]]*mmc@ffaa0000' "$dts_dir" 2>/dev/null \
             | head -n1 | cut -d: -f1 | tr -d "[:space:]")"
    if [[ -z "$label" ]]; then
        print_error "could not find the label for mmc@ffaa0000 in $dts_dir"
        print_error "candidates: $(grep -rhoE '[a-z0-9_]+:[[:space:]]*mmc@[0-9a-f]+' "$dts_dir" 2>/dev/null | sort -u | tr -s "[:space:]" " ")"
        exit 1
    fi

    if grep -q "SEEDSIGNER-SDMMC-REMOVABLE" "$dts_file"; then
        print_success "MicroSD already enabled as removable storage in: $dts_file"
        return 0
    fi

    print_step "Enabling MicroSD as removable storage (&${label}, ${board_profile}/${boot_medium})"
    cat >> "$dts_file" <<EOF

/* SEEDSIGNER-SDMMC-REMOVABLE: the stock config drives this controller as SDIO,
 * so the card-detect line is ignored and no block device appears. Drop the SDIO
 * properties so a MicroSD enumerates as removable storage. */
&${label} {
	/delete-property/ supports-sdio;
	/delete-property/ cap-sdio-irq;
	/delete-property/ non-removable;
	bus-width = <4>;
	cap-sd-highspeed;
	disable-wp;
	status = "okay";
};
EOF

    grep -q "SEEDSIGNER-SDMMC-REMOVABLE" "$dts_file" || {
        print_error "failed to append the sdmmc override to $dts_file"; exit 1; }
    print_success "MicroSD override appended to: $dts_file (&${label})"
}

apply_rng_dts_patch() {
    local board_profile="$1"

    local dts_file
    dts_file="$(resolve_dts_path_for_profile "$board_profile")"

    print_step "Enabling rng DTS node (${board_profile})"
    if ! enable_dts_node rng "$dts_file"; then
        print_error "rng DTS node enable verification failed in: $dts_file"
        exit 1
    fi
    print_success "rng DTS node enabled in: $dts_file"
}

resolve_rootfs_dir() {
    local pattern="$LUCKFOX_SDK_DIR/output/out/rootfs_uclibc_*"
    local matches=( $pattern )

    if [[ ${#matches[@]} -eq 0 ]]; then
        print_error "Could not find rootfs output directory matching: $pattern"
        exit 1
    fi

    export ROOTFS_DIR="${matches[0]}"
    print_info "Using rootfs directory: $ROOTFS_DIR"
}

normalise_boot_images() {
    # Pin the wall-clock releaseTime that two prebuilt SDK tools stamp into the
    # boot images, then repair each file's trailer checksum:
    #   - download.bin (tag "LDR ") is packed by rkbin/tools/boot_merger during
    #     `make uboot`; it writes localtime(time(NULL)) into the header.
    #   - update.img (tag "RKFW") is packed by Linux_Pack_Firmware/rkImageMaker
    #     in build_updateimg; same live-clock stamp, plus an ASCII MD5 trailer
    #     over everything before it that changes with the stamp.
    # Both are prebuilt binaries, so there is no source to patch -- normalise
    # the output instead (ss-fs-normalise.sh bootimg rewrites releaseTime to
    # SOURCE_DATE_EPOCH and recomputes the trailer).
    #
    # Order matters: update.img EMBEDS a verbatim copy of download.bin (the
    # "bootloader" partition, right after its own 102-byte RKFW header), so the
    # LDR file must be normalised FIRST and the pack step re-run to rebuild
    # update.img from the normalised input -- otherwise the embedded copy keeps
    # the live-clock stamp (and its CRC) inside an otherwise-identical image.
    # The re-pack is deterministic given identical inputs: a double-pack test
    # showed only the RKFW header time and the MD5 trailer vary between runs,
    # which step 3 then pins. Everything downstream (bundle copies,
    # sha256sums.txt) reads these files from output/image, so doing it here
    # once covers the SD, eMMC and NAND artifact paths.
    local image_dir="$LUCKFOX_SDK_DIR/output/image"

    if [[ ! -f "$image_dir/download.bin" || ! -f "$image_dir/update.img" ]]; then
        print_error "Boot images missing from $image_dir -- cannot normalise (run 'build.sh firmware' first)"
        exit 1
    fi

    bash "$SEEDSIGNER_LUCKFOX_DIR/ss-fs-normalise.sh" bootimg \
        "$image_dir/download.bin" "${SOURCE_DATE_EPOCH}"

    # Re-run the SDK's own pack step so update.img embeds the normalised LDR.
    # Same invocation as build_updateimg in project/build.sh; the chip id comes
    # from the active BoardConfig (rv1106 for every Luckfox Pico profile).
    local chip="rv1106"
    if [[ -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        local cfg_chip
        cfg_chip="$(grep -E '^export RK_CHIP=' "$LUCKFOX_SDK_DIR/.BoardConfig.mk" | head -n 1 | cut -d= -f2)"
        [[ -n "$cfg_chip" ]] && chip="$cfg_chip"
    fi
    bash "$LUCKFOX_SDK_DIR/tools/linux/Linux_Pack_Firmware/mk-update_pack.sh" \
        -id "$chip" -i "$image_dir"

    bash "$SEEDSIGNER_LUCKFOX_DIR/ss-fs-normalise.sh" bootimg \
        "$image_dir/update.img" "${SOURCE_DATE_EPOCH}"
}

create_nand_image_artifacts() {
    local board_profile="$1"
    local tag="$2"
    local profile_medium="${3:-unknown}"

    print_step "Creating NAND-Flashable Image Artifacts (${board_profile})"

    local image_dir="$LUCKFOX_SDK_DIR/output/image"

    if [[ ! -d "$image_dir" ]]; then
        print_error "Image output directory not found: $image_dir"
        exit 1
    fi

    cd "$image_dir"

    if [[ ! -f "update.img" ]]; then
        print_error "update.img not found. Run './build.sh firmware' before NAND packaging."
        exit 1
    fi

    local nand_bundle_dir="$OUTPUT_DIR/seedsigner-luckfox-pico-${board_profile}-nand-files-${tag}"
    mkdir -p "$nand_bundle_dir"

    # userdata.img is required, not optional. Mini/Max/Pi all declare a userdata
    # partition, and /userdata is the only non-rootfs writable store the app saves
    # settings to -- on a read-only-rootfs build it is the ONLY writable store at
    # all. A bundle without it flashes a board that boots, looks healthy, and
    # silently discards every setting: a failure with no symptom until a user
    # loses state, which is why it belongs in the required list rather than being
    # copied opportunistically.
    #
    # This was missing here (and in build-local.sh) while the inline CI packaged
    # it and hard-failed without it, so only CI ever produced a complete bundle.
    # The partition layout itself was already reconciled across the three builds
    # (see apply-partition-layout.sh and the note in apply_sdk_patches); the
    # PACKAGING of it never was.
    local required_bundle_files=(
        update.img
        download.bin
        env.img
        idblock.img
        uboot.img
        boot.img
        rootfs.img
        userdata.img
        sd_update.txt
        tftp_update.txt
    )

    local missing_bundle_files=()
    for file in "${required_bundle_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp -v "$file" "$nand_bundle_dir/"
        else
            missing_bundle_files+=("$file")
        fi
    done

    if [[ ${#missing_bundle_files[@]} -ne 0 ]]; then
        print_error "Missing required NAND bundle files: ${missing_bundle_files[*]}"
        exit 1
    fi

    if [[ "$profile_medium" == "nand" ]]; then
        validate_nand_oriented_output "$image_dir"
    elif ! grep -q "mtd " "$nand_bundle_dir/sd_update.txt" 2>/dev/null; then
        print_info "Bundle for ${board_profile} (${profile_medium}) does not contain SPI-NAND mtd script commands."
    fi

    cat > "$nand_bundle_dir/README.txt" << 'EOF'
SeedSigner Luckfox NAND Flash Bundle

Contains SDK-generated NAND flashing files:
- update.img / download.bin
- partition images (*.img)
- U-Boot scripts: sd_update.txt and tftp_update.txt

Flash guidance:
- Use update.img with official Luckfox/Rockchip upgrade tooling, or
- Use sd_update.txt / tftp_update.txt with U-Boot workflows.
EOF

    local nand_bundle="seedsigner-luckfox-pico-${board_profile}-nand-bundle-${tag}.tar.gz"
    ss_tar_deterministic "$OUTPUT_DIR/$nand_bundle" "$OUTPUT_DIR" "$(basename "$nand_bundle_dir")"
    print_success "NAND bundle folder created: $nand_bundle_dir"
    print_success "NAND bundle archive created: $OUTPUT_DIR/$nand_bundle"
}


create_emmc_bundle() {
    local board_profile="$1"
    local tag="$2"

    print_step "Creating eMMC-Flashable Bundle (${board_profile})"

    local image_dir="$LUCKFOX_SDK_DIR/output/image"

    if [[ ! -d "$image_dir" ]]; then
        print_error "Image output directory not found: $image_dir"
        exit 1
    fi

    cd "$image_dir"

    if [[ ! -f "update.img" ]]; then
        print_error "update.img not found. Run './build.sh firmware' before eMMC bundling."
        exit 1
    fi

    local emmc_bundle_dir="$OUTPUT_DIR/seedsigner-luckfox-pico-${board_profile}-emmc-files-${tag}"
    mkdir -p "$emmc_bundle_dir"

    # userdata.img is required here too -- same reasoning as the NAND bundle
    # above. The Pi BoardConfig declares 256M(userdata) with userdata@ext4, so
    # the SDK does emit it; it simply was never copied.
    local emmc_files=(
        update.img
        download.bin
        env.img
        idblock.img
        uboot.img
        boot.img
        rootfs.img
        userdata.img
    )

    for file in "${emmc_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp -v "$file" "$emmc_bundle_dir/"
        else
            print_info "Optional file not found, skipping: $file"
        fi
    done

    # The loop above treats every file as optional, so listing userdata.img in
    # emmc_files is not enough on its own -- a missing one would be skipped with
    # an INFO line and the bundle would ship incomplete. Check explicitly, the
    # way the CI workflow did before this packaging moved here.
    if [[ ! -f "$emmc_bundle_dir/userdata.img" ]]; then
        print_error "userdata.img missing from the eMMC bundle."
        echo "   The Pi BoardConfig declares 256M(userdata) and userdata@/userdata@ext4,"
        echo "   so the SDK should have emitted it. Check RK_PRE_BUILD_USERDATA_SCRIPT"
        echo "   and the partition layout step (apply-partition-layout.sh)."
        exit 1
    fi

    cat > "$emmc_bundle_dir/README.txt" << 'EOF'
SeedSigner Luckfox eMMC Flash Bundle

Contains SDK-generated eMMC flashing files:
- update.img / download.bin
- partition images (*.img)

Flash guidance:
- Use update.img with official Luckfox SocToolKit (Windows) or rkdeveloptool (Linux/Mac)
- Connect the board in MASKROM mode (hold BOOT button while connecting USB)
- See: https://wiki.luckfox.com/Luckfox-Pico-Plus-Mini/Flash-image
EOF

    local emmc_bundle="seedsigner-luckfox-pico-${board_profile}-emmc-bundle-${tag}.tar.gz"
    ss_tar_deterministic "$OUTPUT_DIR/$emmc_bundle" "$OUTPUT_DIR" "$(basename "$emmc_bundle_dir")"
    print_success "eMMC bundle folder created: $emmc_bundle_dir"
    print_success "eMMC bundle archive created: $OUTPUT_DIR/$emmc_bundle"
}


validate_nand_oriented_output() {
    local image_dir="$1"

    local sd_script="$image_dir/sd_update.txt"
    local tftp_script="$image_dir/tftp_update.txt"

    for script in "$sd_script" "$tftp_script"; do
        if [[ ! -f "$script" ]]; then
            print_error "Missing NAND validation script: $script"
            exit 1
        fi

        if grep -q "mmc write" "$script"; then
            print_error "Invalid NAND output: found 'mmc write' in $(basename "$script")"
            exit 1
        fi

        if ! grep -q "mtd " "$script"; then
            print_error "Invalid NAND output: missing 'mtd' commands in $(basename "$script")"
            exit 1
        fi

        # patch-sd-update-scripts.sh must have run: staging at the SDK's default
        # ${ramdisk_addr_r} overruns U-Boot's own stack/heap on a 64 MiB Mini and
        # hangs the microSD auto-flash on rootfs.img. Cheap catch if the patch
        # step is ever dropped from a call site.
        if grep -q '\${ramdisk_addr_r}' "$script"; then
            print_error "Invalid NAND output: $(basename "$script") still stages at \${ramdisk_addr_r}"
            echo "   patch-sd-update-scripts.sh did not run before packaging."
            exit 1
        fi
    done

    print_success "Validated NAND-oriented update scripts"
}


export_official_nand_image_dir() {
    local board_profile="$1"
    local tag="$2"
    local image_root="$LUCKFOX_SDK_DIR/IMAGE"

    if [[ ! -d "$image_root" ]]; then
        print_info "No SDK IMAGE directory found at: $image_root"
        return 0
    fi

    local latest_dir
    latest_dir=$(find "$image_root" -maxdepth 1 -type d -name 'IPC_SPI_NAND_BUILDROOT_*' | sort | tail -n 1)

    if [[ -z "$latest_dir" ]]; then
        print_info "No SPI_NAND IMAGE export directory found under: $image_root"
        return 0
    fi

    local bundle_name="seedsigner-luckfox-pico-${board_profile}-nand-sdk-images-${tag}.tar.gz"
    ss_tar_deterministic "$OUTPUT_DIR/$bundle_name" "$image_root" "$(basename "$latest_dir")"
    print_success "Exported official SDK NAND image directory: $OUTPUT_DIR/$bundle_name"
}

# Set BUILDROOT_DIR and everything derived from it, together.
#
# PACKAGE_DIR, CONFIG_IN and PYZBAR_PATCH are all computed from BUILDROOT_DIR at
# file scope, where its value is still the UNRESOLVED placeholder. Updating
# BUILDROOT_DIR alone therefore leaves them pointing at a path that does not
# exist, and the failure surfaces hundreds of lines later in whichever step
# happens to use one of them first. They are set in one place so they cannot
# drift apart again.
_set_buildroot_paths() {
    export BUILDROOT_DIR="$1"
    export PACKAGE_DIR="${BUILDROOT_DIR}/package"
    export CONFIG_IN="${PACKAGE_DIR}/Config.in"
    export PYZBAR_PATCH="${PACKAGE_DIR}/python-pyzbar/0001-PATH-fixed-by-hand.patch"

    # Prove the paths point at a real buildroot tree. Without this, a bad resolve
    # is only discovered by whichever later step happens to touch one of these
    # first -- which is how the UNRESOLVED placeholder got as far as "Adding
    # SeedSigner Menu to Buildroot" before anything complained.
    if [[ ! -f "$CONFIG_IN" ]]; then
        print_error "Buildroot paths do not resolve to a real tree:"
        print_error "  BUILDROOT_DIR=$BUILDROOT_DIR"
        print_error "  expected package index at $CONFIG_IN"
        exit 1
    fi
}

ensure_buildroot_tree() {
    # Resolve rather than assume. The version in the SDK's buildroot tarball is
    # the SDK's business and changes between revisions; this used to be pinned to
    # buildroot-2023.02.6 while the SDK shipped 2024.11.4, so every Docker build
    # died here. CI discovered the directory all along, which is precisely why
    # the breakage stayed invisible until the Docker path was run.
    local resolved
    if resolved="$(bash "$SEEDSIGNER_LUCKFOX_DIR/resolve-buildroot-dir.sh" "$LUCKFOX_SDK_DIR" 2>/dev/null)"; then
        _set_buildroot_paths "$resolved"
        print_info "Using buildroot directory: $BUILDROOT_DIR"
        return
    fi

    print_step "Preparing Buildroot Source Tree"
    make buildroot_create -C "$LUCKFOX_SDK_DIR/sysdrv"

    if ! resolved="$(bash "$SEEDSIGNER_LUCKFOX_DIR/resolve-buildroot-dir.sh" "$LUCKFOX_SDK_DIR")"; then
        print_error "Buildroot tree still not found after buildroot_create"
        exit 1
    fi
    _set_buildroot_paths "$resolved"
    print_success "Using buildroot directory: $BUILDROOT_DIR"
}

# Opt-in secure-boot support (SEEDSIGNER_FIT_SIGNATURE=1), OFF by default so a
# normal build is byte-for-byte unchanged. Two halves:
#   apply_fit_signature_config  - turn ON FIT signature ENFORCEMENT in the U-Boot
#       defconfig BEFORE the U-Boot build, so SPL/U-Boot require a valid signature.
#   export_fit_sign_tree        - AFTER the build, copy everything fit-sign.sh
#       needs (the packed images from output/image + a fit_signcfg/ holding the
#       built u-boot .config as sign.readonly_config) into $OUTPUT_DIR, which is
#       bind-mounted to the host. Signing then happens on the host with
#       secure-boot/sign-secure-boot.sh --build-tree <that dir>. The Docker build
#       itself never signs and never burns.
# See docs/luckfox/secure-boot-bench-procedure.md.
apply_fit_signature_config() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local ubootdir="$LUCKFOX_SDK_DIR/sysdrv/source/uboot/u-boot"
    local cfgdir="$ubootdir/configs"
    print_step "Enabling FIT signature enforcement in U-Boot defconfig (SEEDSIGNER_FIT_SIGNATURE=1)"
    local f found=0 sym
    for f in "$cfgdir"/luckfox_rv1106_uboot*defconfig; do
        [ -f "$f" ] || continue
        found=1
        for sym in CONFIG_FIT_SIGNATURE CONFIG_SPL_FIT_SIGNATURE; do
            sed -i -E "/^# ${sym} is not set\$/d; /^${sym}=/d" "$f"
            echo "${sym}=y" >> "$f"
        done
        print_success "FIT signature enabled in $(basename "$f")"
    done
    if [ "$found" != 1 ]; then
        print_error "SEEDSIGNER_FIT_SIGNATURE=1 but no luckfox_rv1106_uboot*defconfig under $cfgdir"
        exit 1
    fi
    # With CONFIG_FIT_SIGNATURE=y the SDK signs the FIT *during* the build:
    # scripts/fit-core.sh runs check_rsa_keys and `mkimage -k keys/`, which abort
    # with "ERROR: No keys/dev.key" unless the dev.{key,pubkey,crt} triple is
    # present in the u-boot tree. Provide one so the build completes.
    provision_fit_build_keys "$ubootdir/keys"
    arm_fit_burn_key_hash "$ubootdir"   # opt-in: SEEDSIGNER_FIT_BURN_KEY_HASH=1 (IRREVERSIBLE fuse)
}

# IRREVERSIBLE. Arm the OTP key-hash burn. The build's u-boot make.sh never
# passes --burn-key-hash to the FIT signing, so a normal signed build produces a
# loader that verifies signatures but NEVER writes OTP (safe to flash forever).
# When SEEDSIGNER_FIT_BURN_KEY_HASH=1, patch make.sh so pack_fit_image adds
# --burn-key-hash to the fit.sh call: fit-core.sh then sets `burn-key-hash 0x1`
# in the SPL DTB (with its own readback check) and re-packs the loader. On first
# boot that loader writes the FIT pubkey hash to OTP and turns on secure boot --
# permanently. The pubkey burned is whatever signed this build (the committed
# PUBLIC dev key unless SEEDSIGNER_FIT_KEY_DIR gave a real one). Off by default;
# never set in CI or a normal build.
arm_fit_burn_key_hash() {
    [ "${SEEDSIGNER_FIT_BURN_KEY_HASH:-0}" = "1" ] || return 0
    local ubootdir="$1"
    local mk="$ubootdir/make.sh"
    print_step "ARMING OTP BURN — SEEDSIGNER_FIT_BURN_KEY_HASH=1 (IRREVERSIBLE)"
    print_success "  the built loader will write the FIT pubkey hash to OTP on first boot and"
    print_success "  turn on secure boot PERMANENTLY. Flash it only on a board you mean to fuse."
    # Same confirm gate as sign-secure-boot.sh's confirm_burn: arming the fuse is
    # irreversible, so it must not happen from a stray env var alone. A build with
    # SEEDSIGNER_FIT_BURN_KEY_HASH=1 but no token would otherwise silently emit a
    # burn-armed loader. Note the burned key is the PUBLIC dev key unless
    # SEEDSIGNER_FIT_KEY_DIR gave a real one — arming with the dev key fuses the
    # board to a key with no protection (recoverable, but never re-keyable).
    if [ "${SEEDSIGNER_SB_CONFIRM:-}" != "I-UNDERSTAND-THIS-BURNS-A-FUSE" ]; then
        print_error "refusing to arm the OTP burn without SEEDSIGNER_SB_CONFIRM=I-UNDERSTAND-THIS-BURNS-A-FUSE"
        print_error "  (SEEDSIGNER_FIT_BURN_KEY_HASH=1 arms an IRREVERSIBLE fuse; set the token only on a board you mean to fuse)"
        exit 1
    fi
    # Not a refusal (fusing to the dev key is a valid sacrificial-board test of the
    # burn mechanism — see bench §7.5), but say so loudly, the way sign-secure-boot.sh's
    # warn_if_public_dev_key does: arming with the dev key gives NO protection and
    # the board can never later move to a real key.
    if [ "${SEEDSIGNER_FIT_KEY_DIR:-}" = "" ]; then
        print_error "  WARNING: no SEEDSIGNER_FIT_KEY_DIR — this arms a burn to the committed PUBLIC dev key."
        print_error "  WARNING: that fuses the board to a key with NO protection, and it can NEVER be re-keyed."
        print_error "  WARNING: only meaningful as a sacrificial-board test of the burn mechanism itself."
    fi
    [ -f "$mk" ] || { print_error "u-boot make.sh not found at $mk"; exit 1; }
    # Append --burn-key-hash to the uboot.img FIT signing call inside
    # pack_fit_image (the `${SCRIPT_FIT} ${ARG_LIST_FIT} --chip ${RKCHIP_LABEL}`
    # line). Idempotent, and narrow enough not to touch the SCRIPT_DECOMP line.
    if ! grep -q 'SCRIPT_FIT}.*--chip.*RKCHIP_LABEL}.*--burn-key-hash' "$mk"; then
        sed -i '/SCRIPT_FIT} .* --chip .*RKCHIP_LABEL}$/ s/$/ --burn-key-hash/' "$mk"
    fi
    grep -q 'SCRIPT_FIT}.*--chip.*RKCHIP_LABEL}.*--burn-key-hash' "$mk" \
        || { print_error "failed to arm --burn-key-hash in $mk (pack_fit_image line not found)"; exit 1; }
    print_success "armed: pack_fit_image now signs with --burn-key-hash"
}

# Lay down the dev.{key,pubkey,crt} the in-SDK signing needs. Three sources, in
# order: an existing triple already in the tree (kept SDK checkout) is reused; a
# real key supplied via SEEDSIGNER_FIT_KEY_DIR is copied in and its pubkey ends up
# embedded in the loader (no host resign needed); otherwise the committed PUBLIC
# dev key (secure-boot/dev-keys/) is used as a placeholder — its pubkey is meant
# to be replaced on the host by `fit-sign.sh --key-dir <real>` over the exported
# fit-sign tree.
#
# Why the fixed public key rather than a fresh random one: it keeps the signed
# build reproducible, and it makes the "skipped the re-sign, then burned the OTP"
# mistake RECOVERABLE — the board fuses to a key everyone has, so it can still be
# signed/updated, instead of being bricked by a discarded random key. It grants
# no security (the key is public); real protection needs the Stage 2 re-sign with
# a secret key. See secure-boot/dev-keys/README.md.
provision_fit_build_keys() {
    local keydir="$1" k
    mkdir -p "$keydir"
    if [ -f "$keydir/dev.key" ] && [ -f "$keydir/dev.pubkey" ] && [ -f "$keydir/dev.crt" ]; then
        print_success "reusing existing FIT signing key already in $keydir"
        return 0
    fi
    if [ -n "${SEEDSIGNER_FIT_KEY_DIR:-}" ]; then
        local s="$SEEDSIGNER_FIT_KEY_DIR"
        for k in dev.key dev.pubkey dev.crt; do
            [ -f "$s/$k" ] || { print_error "SEEDSIGNER_FIT_KEY_DIR=$s is missing $k (need dev.key + dev.pubkey + dev.crt; generate with secure-boot/make-dev-keys.sh)"; exit 1; }
        done
        cp "$s/dev.key" "$s/dev.pubkey" "$s/dev.crt" "$keydir/"
        print_success "using supplied FIT signing key from SEEDSIGNER_FIT_KEY_DIR (its pubkey is embedded in the loader; no host resign needed)"
        return 0
    fi
    local devkeys="$SEEDSIGNER_LUCKFOX_DIR/secure-boot/dev-keys"
    for k in dev.key dev.pubkey dev.crt; do
        [ -f "$devkeys/$k" ] || { print_error "committed public dev key missing: $devkeys/$k (stale Docker image? rebuild with --force)"; exit 1; }
    done
    cp "$devkeys/dev.key" "$devkeys/dev.pubkey" "$devkeys/dev.crt" "$keydir/"
    print_step "Using the committed PUBLIC dev key as the FIT build placeholder"
    print_success "  this key is NOT secret and grants NO protection — re-sign the exported fit-sign"
    print_success "  tree with your real secret key (fit-sign.sh --key-dir <real>) before you burn."
    print_success "  (A burn done with this placeholder is recoverable but unsecurable; see"
    print_success "   secure-boot/dev-keys/README.md.)"
}

# When the boot.img FIT is signed, u-boot must NOT rewrite the kernel DTB's
# /chosen bootargs at runtime (that would break the signature), so the kernel
# uses whatever root= is BAKED into the DTB. Each board's ipc.dtsi hardcodes its
# stock SD/eMMC default (root=/dev/mmcblk1p7 on mini+max, root=/dev/mmcblk0p7 on
# pi — eMMC is the FIRST block device; those are pre-oem-removal positions and
# apply_signed_nand_bootargs now bakes p6); on a signed NAND build the SDK's usual
# runtime injection of root=ubi0:rootfs / ubi.mtd / rootfstype / rk_dma_heap_cma
# is dropped, so the board hangs at "Waiting for root device" and comes up with
# the DT-default CMA. Bake the rootfs cmdline (the exact args the SDK computes in
# parse_partition_file/__GET_BOOTARGS_FROM_BOARD_CFG) into /chosen before the
# kernel build — including the partition-layout token (mtdparts= / blkdevparts=
# built from RK_PARTITION_CMD_IN_ENV, exactly what parse_partition_file() wrote
# to env.img): since lock-kernel-cmdline.sh stops U-Boot importing those from the
# unsigned env partition (M1), and our images carry no MBR, this baked token is
# now the ONLY partition table the kernel has. Gated on signed builds, so
# unsigned ones are untouched (u-boot still overrides their /chosen at runtime).
# This also fixes the attacker-controlled-cmdline gap for signed builds: root
# and the layout are pinned inside the signed image, not read from the unsigned
# env partition. A mismatch is not a fallback: it is "Waiting for root device"
# with no recovery short of a reflash.
apply_signed_nand_bootargs() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local profile="$1" medium="$2"
    case "$medium" in
        nand|sd|emmc) ;;
        *) print_info "apply_signed_nand_bootargs: no bootargs baking needed for '$medium'"; return 0 ;;
    esac
    # Per-board DTSI (the one carrying /chosen/bootargs) and the rootfs block
    # device. All three boards share the same 6-partition layout
    # (env,idblock,uboot,boot,userdata,rootfs — apply-partition-layout.sh; oem
    # was folded into the rootfs and removed), so on NAND rootfs is mtd5
    # everywhere; SD/SDMMC is mmcblk1p6, eMMC is mmcblk0p6.
    #
    # old_root_dev is the SDK's stock default (rootfs was partition 7 when oem
    # occupied slot 6). The DTSI ships unmodified from the SDK, so a fresh
    # checkout still carries p7 and every replacement must accept either.
    local dtsi root_dev old_root_dev
    case "$profile" in
        mini) dtsi="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts/rv1103-luckfox-pico-ipc.dtsi";      root_dev="mmcblk1p6"; old_root_dev="mmcblk1p7" ;;
        max)  dtsi="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts/rv1106-luckfox-pico-pro-max-ipc.dtsi"; root_dev="mmcblk1p6"; old_root_dev="mmcblk1p7" ;;
        pi)   dtsi="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts/rv1106-luckfox-pico-pi-ipc.dtsi";     root_dev="mmcblk0p6"; old_root_dev="mmcblk0p7" ;;
        *) print_error "signed bootargs: unsupported board profile '$profile' (expected mini, max or pi)"; exit 1 ;;
    esac
    [ -f "$dtsi" ] || { print_error "signed bootargs: DTS not found: $dtsi"; exit 1; }

    # The CMA size the SDK's env would have injected at runtime (RK_BOOTARGS_CMA_SIZE):
    # a signed FIT never applies it, so bake exactly that value. For mini this is
    # $MINI_CMA_SIZE — apply_mini_cma_profile already rewrote the board config to
    # it earlier in main; for max/pi it is the SDK's own 66M. Reading the config
    # (not a per-board constant) keeps one source of truth: whatever an unsigned
    # build would have ended up with, the signed bake matches.
    local cma_size
    cma_size="$(sed -n 's/^export RK_BOOTARGS_CMA_SIZE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$SS_BOARD_CONFIG" 2>/dev/null | head -n1)"
    [ -n "$cma_size" ] \
        || { print_error "signed bootargs: no RK_BOOTARGS_CMA_SIZE in board config ${SS_BOARD_CONFIG:-missing}"; exit 1; }

    # The partition-layout token baked alongside root=. This is the SAME string
    # U-Boot used to append from the unsigned env partition — project/build.sh
    # parse_partition_file() builds <prefix>:<RK_PARTITION_CMD_IN_ENV> and writes
    # it into env.img, and board.c merged whatever env held verbatim. Since
    # lock-kernel-cmdline.sh stops that import (M1), the kernel would see NO
    # partitions at all without this: our images carry no MBR (sector 0 is the
    # ENVF itself), so blkdevparts=/mtdparts= is the only partition table the
    # kernel has. Read from the board config — one source of truth with
    # apply-partition-layout.sh, never a second hardcoded copy. The device
    # prefixes mirror parse_partition_file() exactly (spi-nand0 is the kernel's
    # spi-nand MTD name; eMMC is mmcblk0, SD card mmcblk1).
    local part_layout part_token
    part_layout="$(sed -n 's/^export RK_PARTITION_CMD_IN_ENV="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$SS_BOARD_CONFIG" 2>/dev/null | head -n1)"
    [ -n "$part_layout" ] \
        || { print_error "signed bootargs: no RK_PARTITION_CMD_IN_ENV in board config ${SS_BOARD_CONFIG:-missing}"; exit 1; }
    case "$medium" in
        nand) part_token="mtdparts=spi-nand0:$part_layout" ;;
        sd)   part_token="blkdevparts=mmcblk1:$part_layout" ;;
        emmc) part_token="blkdevparts=mmcblk0:$part_layout" ;;
    esac

    if [ "$medium" = "nand" ]; then
        # The baked cmdline must match what mkfs_ubi.sh actually built. readonly-
        # rootfs (resolved by apply_readonly_rootfs, which runs earlier in
        # build_profile_artifacts) decides: non-dev packs squashfs into a STATIC
        # UBI volume exposed as /dev/ubiblock0_0; dev keeps a writable dynamic
        # UBIFS volume at ubi0:rootfs. Same split the SDK's own
        # __GET_TARGET_PARTITION_FS_TYPE makes for spi_nand.
        local baked_root marker
        if [ "${SS_RO_ROOTFS:-0}" = "1" ]; then
            baked_root="ubi.block=0,rootfs root=/dev/ubiblock0_0 rootfstype=squashfs ubi.mtd=5 rk_dma_heap_cma=$cma_size $part_token"
        else
            baked_root="root=ubi0:rootfs ubi.mtd=5 rootfstype=ubifs rk_dma_heap_cma=$cma_size $part_token"
        fi
        # The full string, not just the first token: a stale bake with the same
        # root= but an old ubi.mtd (e.g. 6, before oem was removed) must NOT be
        # mistaken for "already baked" and left in place — that would boot to
        # "Waiting for root device".
        marker="$baked_root"
        if grep -qF "$marker" "$dtsi"; then
            print_success "NAND root already baked in $(basename "$dtsi") ($marker)"
            return 0
        fi
        # The SDK checkout survives between runs, so the DTSI may carry an EARLIER
        # bake — this one (RO or dev) or the SD/eMMC one on the same file. All prior
        # states start with a recognisable root= token:
        #   fresh            : root=/dev/$old_root_dev (stock SDK default, pre-oem-removal)
        #   stale SD bake    : root=/dev/$root_dev rootfstype=squashfs rk_dma_heap_cma=X
        #   stale NAND RO    : ubi.block=0,rootfs root=/dev/ubiblock0_0 ...
        #   stale NAND dev   : root=ubi0:rootfs ...
        grep -qE "(^|[[:space:]])((ubi\.block=0,rootfs )?root=/dev/($root_dev|$old_root_dev|ubiblock0_0)|root=ubi0:rootfs)([[:space:]]|$)" "$dtsi" \
            || { print_error "signed-NAND bootargs: no root= for $root_dev / $old_root_dev / ubiblock0_0 / ubi0:rootfs in $(basename "$dtsi") — SDK layout changed"; exit 1; }
        # rootfs is mtd5 in our 6-partition NAND layout (env,idblock,uboot,boot,userdata,rootfs).
        # Replace any previously-baked sequence with the new bake — each known format
        # exactly, because the token orders differ between them (one combined regex
        # cannot cover all), and a plain root= substitution alone would leave stale
        # tokens behind: the kernel takes the LAST occurrence of a cmdline param, so
        # a dev-NAND build after an SD build would otherwise ship with
        # rootfstype=squashfs winning over ubifs. Only one -e can match per state;
        # on a fresh (never-baked) DTSI none do and the final bare-root= substitution
        # applies instead. The optional trailing mtdparts=/blkdevparts= token is an
        # earlier bake of THIS change: it must be consumed too, or a stale layout
        # would survive after the new one (last occurrence wins).
        sed -i -E \
            -e "s|ubi\.block=0,rootfs root=/dev/ubiblock0_0 rootfstype=[A-Za-z0-9]+ ubi\.mtd=[0-9]+ rk_dma_heap_cma=[A-Za-z0-9]+( mtdparts=[^[:space:]]+)?|$baked_root|" \
            -e "s|root=ubi0:rootfs ubi\.mtd=[0-9]+ rootfstype=[A-Za-z0-9]+ rk_dma_heap_cma=[A-Za-z0-9]+( mtdparts=[^[:space:]]+)?|$baked_root|" \
            -e "s#root=/dev/($root_dev|$old_root_dev) rootfstype=[A-Za-z0-9]+ rk_dma_heap_cma=[A-Za-z0-9]+( mtdparts=[^[:space:]]+| blkdevparts=[^[:space:]]+)?#$baked_root#" \
            "$dtsi"
        sed -i -E "s#root=/dev/($root_dev|$old_root_dev)#$baked_root#" "$dtsi"
        grep -qF "$marker" "$dtsi" || { print_error "signed-NAND bootargs: rewrite failed in $(basename "$dtsi")"; exit 1; }
        print_success "baked: $baked_root ($profile)"
    else
        # MicroSD/eMMC: the stock DTSI already carries root=/dev/$root_dev (the
        # SDK's own default for these media); what is missing on a signed build
        # are the two things the SDK would normally append via sys_bootargs —
        # exactly the env values a signed /chosen ignores:
        #   rootfstype=squashfs   — the SD/eMMC rootfs is a read-only squashfs in
        #       both variants (readonly-rootfs.sh only ever switches TO squashfs,
        #       and apply_readonly_rootfs forces it on for signed builds), and the
        #       initramfs verifier mounts it as squashfs; assert it rather than
        #       guess (a non-squashfs rootfs would verify bytes the kernel then
        #       mounts with a different filesystem). This is a backstop: the force
        #       above makes an ext4 root unreachable on signed SD/eMMC builds.
        #   rk_dma_heap_cma=$cma_size — WITHOUT this the DT-default CMA region is
        #       reserved. On the 64 MB Mini that leaves only ~24 MB usable and
        #       starves the SeedSigner app: it thrashes in direct reclaim and
        #       never signals ready, so the boot watchdog reboots in a loop (the
        #       original reason this bake exists). On max/pi (512 MB) it is not
        #       fatal, but baking keeps signed == unsigned behaviour exactly. The
        #       RK_BOOTARGS_CMA_SIZE profile only reaches the runtime-injected
        #       cmdline, which a signed FIT never applies.
        local fs_cfg rootfs_fs baked marker
        fs_cfg="$(grep -E '^[[:space:]]*export[[:space:]]+RK_PARTITION_FS_TYPE_CFG=' "$SS_BOARD_CONFIG" 2>/dev/null | head -n1 || true)"
        rootfs_fs="$(echo "$fs_cfg" | sed -n 's/.*rootfs@[^@,"]*@\([A-Za-z0-9]*\).*/\1/p')"
        [ "$rootfs_fs" = "squashfs" ] \
            || { print_error "signed-$medium bootargs: rootfs fs type is '${rootfs_fs:-<unknown>}' (board config ${SS_BOARD_CONFIG:-missing}) — only squashfs roots are supported by the initramfs verifier"; exit 1; }
        baked="root=/dev/$root_dev rootfstype=squashfs rk_dma_heap_cma=$cma_size $part_token"
        # The FULL string, including the root device: a stale bake pointing at
        # the old partition 7 must not match p6 and be left in place.
        marker="$baked"
        if grep -qF "$marker" "$dtsi"; then
            print_success "SD/eMMC bootargs already baked in $(basename "$dtsi") ($marker)"
            return 0
        fi
        # Accept either the stock default ($old_root_dev, partition 7 in the
        # pre-oem-removal layout) or our own earlier bake ($root_dev, partition 6).
        grep -qE "root=/dev/($root_dev|$old_root_dev)" "$dtsi" \
            || { print_error "signed-$medium bootargs: expected 'root=/dev/$root_dev' (or stock $old_root_dev) in $(basename "$dtsi") — SDK layout changed (or different bootargs already baked)"; exit 1; }
        # The SDK checkout survives between builds (seedsigner-repos volume), so
        # the DTSI may carry an EARLIER bake of this same line. Replace root=
        # plus any previously-baked trailing tokens, not just bare root=: a
        # plain substitution would leave the old tokens behind, and if the CMA
        # size ever changes the stale rk_dma_heap_cma would win (the kernel takes
        # the LAST occurrence of a cmdline param). The optional trailing
        # blkdevparts=/mtdparts= token is an earlier bake of THIS change; it must
        # be consumed too, or a stale layout would survive after the new one.
        sed -i -E "s#root=/dev/($root_dev|$old_root_dev)( rootfstype=[A-Za-z0-9]+)?( rk_dma_heap_cma=[A-Za-z0-9]+)?(( blkdevparts=[^[:space:]]+| mtdparts=[^[:space:]]+)?)#$baked#" "$dtsi"
        grep -qF "$baked" "$dtsi" \
            || { print_error "signed-$medium bootargs: rewrite failed in $(basename "$dtsi")"; exit 1; }
        print_success "baked: $baked ($profile/$medium)"
    fi
}

# Enable the SPI display (spidev0.0) STATICALLY in the kernel DTB, instead of via
# luckfox-config's runtime device-tree overlay. That overlay is fragile: it needs
# a __symbols__ label map in the live DTB (absent here) to resolve &spi0, and
# `luckfox-config` core-dumps `dtc` with "get_node_by_label: label empty",
# leaving &spi0 disabled -> no /dev/spidev0.0 -> black screen. On a signed FIT the
# overlay is doubly moot (u-boot can't rewrite the signed DTB). Baking it in makes
# the display work regardless.
#
# Every board's DTS ships `&spi0 { status = "disabled"; }`. We flip it to okay and,
# critically, set pinctrl WITHOUT MISO: on RV1103/RV1106 spi0m0_miso is RK_PC3,
# which the mini HAT uses as the panel RESET (the very pin spi0m0_miso would
# claim); max/pi don't wire PC3 to their HATs, but the ST7789 panels are 3-wire
# anyway, so one no-MISO pinctrl serves all three. Where the board's DTS tree has
# an fbtft@0 (st7789v) node we disable it: it shares CS0 with spidev@0 and on max
# drives RK_PB0 as backlight while SeedSigner uses that pin as DC — the in-kernel
# fb must be off or both clash. Appended as a late &spi0 override so it wins over
# the earlier `disabled`. The disabled fbtft@0 is labelled (ss_fbtft_keep) and
# referenced from an alias: Rockchip's dtc (CONFIG_DTC_OMIT_DISABLED=y, see
# scripts/dtc/checks.c fixup_node_disabled) strips every non-okay node that nothing
# references, and luckfox-config's FBTFT_SPI overlay targets /spi@ff500000/fbtft@0
# by path at boot — without the reference the node is absent from the DTB, the
# overlay fails with -22, and the board dies during S99.
apply_spi_display_dts() {
    local profile="$1"
    local dts has_fbtft
    case "$profile" in
        mini) dts="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts/rv1103g-luckfox-pico-mini.dts";      has_fbtft=1 ;;
        max)  dts="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pro-max.dts"; has_fbtft=1 ;;
        pi)   dts="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pi.dts";      has_fbtft=0 ;;
        *) print_error "apply_spi_display_dts: unsupported board profile '$profile' (expected mini, max or pi)"; exit 1 ;;
    esac
    [ -f "$dts" ] || { print_error "SPI display DTS not found: $dts"; exit 1; }
    print_step "Enabling SPI display (spidev0.0) statically in the DTB (${profile})"
    if grep -q 'ss_fbtft_keep' "$dts"; then
        print_success "SPI display already enabled in $(basename "$dts")"
        return 0
    fi
    if grep -q 'SEEDSIGNER_SPI_DISPLAY' "$dts"; then
        # A previous build's block without the fbtft keep-alive reference: Rockchip's
        # dtc would strip /spi@ff500000/fbtft@0 and luckfox-config breaks at boot.
        # Refuse rather than append a second &spi0 block.
        print_error "stale SEEDSIGNER_SPI_DISPLAY block (pre-keep-alive) in $(basename "$dts"); rebuild from a clean SDK checkout"
        exit 1
    fi
    {
        echo ""
        echo "/* SEEDSIGNER_SPI_DISPLAY -- enable /dev/spidev0.0 statically (see os-build.sh"
        echo " * apply_spi_display_dts). pinctrl has NO miso: RK_PC3 must stay a GPIO on the"
        echo " * mini HAT (panel reset); the panels are 3-wire so no board needs MISO."
        if [ "$has_fbtft" = 1 ]; then
            echo " * fbtft@0 shares CS0 with spidev@0 and must be off. It is labelled and"
            echo " * referenced from an alias because Rockchip's dtc (CONFIG_DTC_OMIT_DISABLED)"
            echo " * strips every non-okay node that nothing references -- and luckfox-config's"
            echo " * FBTFT_SPI overlay targets /spi@ff500000/fbtft@0 by path at boot. */"
        else
            echo " */"
        fi
        echo "&spi0 {"
        echo -e "\tstatus = \"okay\";"
        echo -e "\tpinctrl-0 = <&spi0m0_clk &spi0m0_mosi &spi0m0_cs0>;"
        if [ "$has_fbtft" = 1 ]; then
            echo -e "\tss_fbtft_keep: fbtft@0 {"
            echo -e "\t\tstatus = \"disabled\";"
            echo -e "\t};"
        fi
        echo "};"
        if [ "$has_fbtft" = 1 ]; then
            # Path reference (not &aliases): this dtc only resolves &name for
            # LABELS, and the aliases node has none.
            echo ""
            echo "&{/aliases} {"
            echo -e "\tss-fbtft = &ss_fbtft_keep;"
            echo "};"
        fi
    } >> "$dts"
    grep -q 'SEEDSIGNER_SPI_DISPLAY' "$dts" || { print_error "SPI display enable failed in $dts"; exit 1; }
    if [ "$has_fbtft" = 1 ]; then
        print_success "spidev0.0 enabled (SPI0_M0, no MISO, fbtft off) in $(basename "$dts")"
    else
        print_success "spidev0.0 enabled (SPI0_M0, no MISO; no fbtft node on this board) in $(basename "$dts")"
    fi
}

# Sign the FINAL boot.img in-container (opt-in). The u-boot build signs uboot.img
# (fit-core.sh, because we enabled CONFIG_FIT_SIGNATURE), but NOTHING in this SDK
# signs boot.img -- mk-fitimage.sh packs it with the "dev" signature *template*
# and no `-k`, so an enforcing u-boot rejects it at boot ("Failed to verify
# required signature 'key-dev'"), which is exactly the bench failure we saw.
#
# Sign it with the SDK's own scripts/fit.sh --boot_img: it unpacks the built
# boot.img to recover its .its, re-signs the FIT with keys/dev.* (placed in the
# u-boot tree by apply_fit_signature_config) and writes the signed image back to
# <u-boot>/boot.img. This is the same tested path that signs uboot.img. At
# runtime u-boot verifies it with the pubkey already embedded in uboot.img, so
# the whole chain (loader -> uboot.img -> boot.img) is now consistently signed by
# one key -- the direct build output boots, no host re-sign needed.
#
# Runs BEFORE normalise_boot_images so the update.img repack embeds the signed
# boot.img. fit.sh runs fit_check_sign internally and is `set -e`, so a bad sign
# aborts here rather than shipping an unbootable enforced image.
sign_boot_image() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local ubootdir="$LUCKFOX_SDK_DIR/sysdrv/source/uboot/u-boot"
    local img="$LUCKFOX_SDK_DIR/output/image/boot.img"
    print_step "Signing boot.img with the FIT key (SEEDSIGNER_FIT_SIGNATURE=1)"
    [ -f "$img" ] || { print_error "boot.img not found at $img"; exit 1; }
    [ -f "$ubootdir/scripts/fit.sh" ] || { print_error "u-boot fit.sh missing under $ubootdir"; exit 1; }
    [ -f "$ubootdir/keys/dev.key" ] || { print_error "FIT signing key missing at $ubootdir/keys/dev.key (apply_fit_signature_config should have placed it)"; exit 1; }
    ( cd "$ubootdir" && ./scripts/fit.sh --boot_img "$img" ) \
        || { print_error "boot.img signing (fit.sh --boot_img) failed"; exit 1; }
    # fit_gen_boot_img wrote the signed FIT to <u-boot>/boot.img; copy it back.
    [ -f "$ubootdir/boot.img" ] && cp -f "$ubootdir/boot.img" "$img"
    print_success "boot.img signed (whole chain now signed with the FIT key)"
}

# Re-sign all four boot-chain images with our own tools (opt-in). The SDK's in-
# build signing is not byte-reproducible: mkimage stamps wall-clock time into
# the FIT signature node and draws random PSS salts, and rk_sign_tool (loader
# tier) is a prebuilt binary we cannot patch. deterministic-sign.sh overwrites
# every signature with a digest-derived salt and zeroes the timestamp; both sit
# outside the signed region, so on-device verification is unaffected. Runs
# AFTER sign_boot_image (all content mutations done) and BEFORE
# normalise_boot_images, so update.img's repack embeds OUR signatures.
deterministic_sign_chain() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local ubootdir="$LUCKFOX_SDK_DIR/sysdrv/source/uboot/u-boot"
    local image_dir="$LUCKFOX_SDK_DIR/output/image"
    print_step "Deterministically re-signing the boot chain (SEEDSIGNER_FIT_SIGNATURE=1)"
    bash "$SEEDSIGNER_LUCKFOX_DIR/deterministic-sign.sh" \
        "$image_dir" "$ubootdir/keys/dev.key" "$ubootdir/keys/dev.pubkey" \
        || { print_error "deterministic re-signing failed"; exit 1; }
}

# --- Rootfs verification (SEEDSIGNER_FIT_SIGNATURE=1) -------------------------
#
# The rootfs volume's logical UBIFS contents are signed at build time by the
# minisign hook in mkfs_ubi.sh (secure-boot/patch-mkfs-ubi-signing.sh). These
# functions:
#   * verify the vendored initramfs binaries against their pinned hashes,
#   * resolve the signing key and export it for the fakeroot script,
#   * make sure the kernel can run a script /init from a gzipped initramfs,
#   * after `build.sh firmware`, pack the verifier (busybox + minisign + ss-lcd
#     + pubkey + signature) into an initramfs and embed it in boot.img's FIT
#     ramdisk slot. The subsequent sign_boot_image() re-signs the whole FIT,
#     including the new ramdisk image: fit-unpack.sh iterates /images generically
#     and "ramdisk" is added to sign-images by the repack below.

rebuild_initramfs_binaries() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    [ "${SEEDSIGNER_REBUILD_INITRAMFS_BINARIES:-0}" = "1" ] || return 0
    # Called from the per-profile block, which runs once per board/medium combo
    # (up to five in an --all build) — rebuild exactly once per run.
    [ "${SS_INITRAMFS_BINARIES_REBUILT:-0}" = "1" ] && return 0
    local tc="$LUCKFOX_SDK_DIR/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf"
    print_step "Rebuilding vendored initramfs binaries from source (SEEDSIGNER_REBUILD_INITRAMFS_BINARIES=1)"
    bash "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/build-initramfs-binaries.sh" \
        "$tc" "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/initramfs-binaries" || exit 1
    SS_INITRAMFS_BINARIES_REBUILT=1
}

verify_initramfs_binaries() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local dir="$SEEDSIGNER_LUCKFOX_DIR/secure-boot/initramfs-binaries" f actual
    print_step "Verifying vendored initramfs binaries (SHA-256 pins)"
    # Pinned at commit time; see secure-boot/initramfs-binaries/README.md.
    local -A pins=(
        [busybox-arm]=df8256cbb975dd747cb15d0f109c56ccad2ae684310492f2bce0e8bf25f51eb5
        [minisign-arm]=e2a05519706b3f98457b9db34c4a9cfa8da47acb5856cadd1ab064d3cf1d1dae
        [ss-lcd]=37bb95f67fd757912db2c72c8662ae7aa86ed2bcdbdbb9b18108379b72737be0
        [minisign-host]=1f6105515a2feb3f9b2bbda37e5c89c693a8d3c7e5c0899b47553d50ffef7c4f
    )
    for f in "${!pins[@]}"; do
        [ -f "$dir/$f" ] || { print_error "vendored binary missing: $dir/$f (stale checkout?)"; exit 1; }
        actual="$(sha256sum "$dir/$f" | cut -d' ' -f1)"
        if [ "$actual" != "${pins[$f]}" ]; then
            print_error "SHA-256 mismatch for $dir/$f: got $actual, want ${pins[$f]}"; exit 1
        fi
    done
    print_success "initramfs binaries match their pins"
}

provision_rootfs_signing_key() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local keydir="${SEEDSIGNER_ROOTFS_KEY_DIR:-$SEEDSIGNER_LUCKFOX_DIR/secure-boot/dev-keys-rootfs}" k
    for k in dev.key dev.pubkey; do
        [ -f "$keydir/$k" ] || { print_error "rootfs signing key missing: $keydir/$k (set SEEDSIGNER_ROOTFS_KEY_DIR to a dir with minisign dev.key/dev.pubkey)"; exit 1; }
    done
    if [[ -z "${SEEDSIGNER_ROOTFS_KEY_PASSPHRASE:-}" ]]; then
        if [ "$keydir" = "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/dev-keys-rootfs" ]; then
            # The committed dev key's passphrase is public and documented in its
            # README; defaulting it keeps the plain SEEDSIGNER_FIT_SIGNATURE=1
            # build unattended. A real key must set it explicitly.
            export SEEDSIGNER_ROOTFS_KEY_PASSPHRASE="seedsigner-dev"
        else
            print_error "SEEDSIGNER_ROOTFS_KEY_DIR is set but SEEDSIGNER_ROOTFS_KEY_PASSPHRASE is empty (the signing step would hang on a prompt)"; exit 1
        fi
    fi
    export SEEDSIGNER_ROOTFS_SIGNING_KEY="$keydir/dev.key"
    print_success "rootfs signing key: $SEEDSIGNER_ROOTFS_SIGNING_KEY"
}

apply_initramfs_kernel_config() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local board_profile="$1" boot_medium="$2"
    # The initramfs /init is a shell script (needs BINFMT_SCRIPT), the cpio is
    # gzip-compressed (needs RD_GZIP), and /init mounts /proc + /sys to read the
    # cmdline and wait on UBI (needs PROC_FS/SYSFS). None of these symbols are in
    # the SDK defconfig, so they rely on Kconfig defaults — pin them explicitly
    # instead of trusting that (verify against what gets built, not a default).
    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$LUCKFOX_SDK_DIR/.BoardConfig.mk" 2>/dev/null | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"
    local kernel_cfg_file="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [[ ! -f "$kernel_cfg_file" ]]; then
        print_error "Kernel defconfig not found for initramfs config: $kernel_cfg_file"
        exit 1
    fi
    local sym
    for sym in CONFIG_BINFMT_SCRIPT CONFIG_RD_GZIP CONFIG_PROC_FS CONFIG_SYSFS; do
        sed -i -E "/^${sym}(=|_)/d;/^# ${sym} is not set\$/d" "$kernel_cfg_file"
        echo "${sym}=y" >> "$kernel_cfg_file"
    done
    print_success "pinned BINFMT_SCRIPT/RD_GZIP/PROC_FS/SYSFS =y in $kernel_defconfig (script /init from gzipped initramfs)"
}

# Pack the rootfs verifier into an initramfs and embed it in boot.img's FIT
# ramdisk slot — for every medium (NAND, MicroSD, eMMC). Runs after `build.sh
# firmware` (the signing hook's .minisig/.size outputs exist by then) and before
# sign_boot_image (which re-signs the whole FIT, ramdisk included). The repack
# mirrors what scripts/mkimg + fit-core.sh do: unpack the built boot.img with
# the SDK's own fit-unpack.sh, add a ramdisk image node + config entry (+
# "ramdisk" in sign-images), and mkimage -E it back.
embed_rootfs_verifier() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local board_profile="$1" boot_medium="$2"
    print_step "Embedding rootfs verifier in boot.img initramfs (SEEDSIGNER_FIT_SIGNATURE=1)"

    # Which signing hook produced the signature depends on the medium: NAND
    # packs squashfs/ubifs into a UBI volume via mkfs_ubi.sh's embedded call
    # (rootfs.ubifs.*), MicroSD/eMMC write a raw-partition squashfs through
    # mkfs_squashfs.sh (rootfs.img.*). Same key, same trusted comment — /init
    # does not care which medium produced the bytes it streams.
    local imgdir="$LUCKFOX_SDK_DIR/output/image"
    local sig size_file hook_script
    case "$boot_medium" in
        nand)  sig="$imgdir/rootfs.ubifs.minisig";   size_file="$imgdir/rootfs.ubifs.size";   hook_script="mkfs_ubi.sh (patch-mkfs-ubi-signing.sh)" ;;
        sd|emmc) sig="$imgdir/rootfs.img.minisig";    size_file="$imgdir/rootfs.img.size";     hook_script="mkfs_squashfs.sh (patch-mkfs-squashfs-signing.sh)" ;;
        *) print_error "embed_rootfs_verifier: unsupported boot medium '$boot_medium' (expected nand, sd or emmc)"; exit 1 ;;
    esac
    [ -f "$sig" ] || { print_error "rootfs signature missing at $sig -- the $hook_script signing hook did not run (patch applied? SEEDSIGNER_ROOTFS_SIGNING_KEY exported?)"; exit 1; }

    local ubootdir="$LUCKFOX_SDK_DIR/sysdrv/source/uboot/u-boot"
    local img="$imgdir/boot.img"
    [ -f "$img" ] || { print_error "boot.img not found at $img (run 'build.sh firmware' first)"; exit 1; }

    # --- assemble the initramfs staging tree ---------------------------------
    local bin="$SEEDSIGNER_LUCKFOX_DIR/secure-boot/initramfs-binaries"
    local src="$SEEDSIGNER_LUCKFOX_DIR/secure-boot/initramfs"
    local keydir="${SEEDSIGNER_ROOTFS_KEY_DIR:-$SEEDSIGNER_LUCKFOX_DIR/secure-boot/dev-keys-rootfs}"
    local stage
    stage="$(mktemp -d)"
    # Mountpoints MUST exist in the cpio: mount(2) does not create them, and
    # devtmpfs auto-mount (DEVTMPFS_MOUNT=y) mounts onto an existing /dev —
    # without it there is no /dev/ubi0_0 or /dev/mmcblk* and the verifier can
    # never see its root device.
    mkdir -p "$stage/bin" "$stage/dev" "$stage/mnt" "$stage/proc" "$stage/sys"
    cp "$bin/busybox-arm"  "$stage/bin/busybox"
    cp "$bin/minisign-arm" "$stage/bin/minisign"
    cp "$bin/ss-lcd"       "$stage/bin/ss-lcd"
    chmod 755 "$stage/bin/"*
    # /init calls these by name; busybox resolves them through symlinks.
    local applet
    for applet in sh mount umount switch_root dd truncate sha256sum ls cat echo sleep \
                  true false reboot halt poweroff mknod grep head tail dmesg rm mkdir ln cp mv; do
        ln -s busybox "$stage/bin/$applet"
    done
    # /init with the signed image size baked in (the volume/partition is padded
    # beyond the signed prefix, so /init's streaming read of it must stop at
    # exactly this many bytes).
    [ -f "$size_file" ] || { print_error "signed rootfs size missing at $size_file -- the $hook_script signing hook did not run"; exit 1; }
    local signed_size
    signed_size="$(cat "$size_file")"
    [[ "$signed_size" =~ ^[0-9]+$ ]] && [ "$signed_size" -gt 0 ] \
        || { print_error "signed rootfs size is not a positive integer: '$signed_size'"; exit 1; }
    # The verification-failure escape-hatch key: GPIO1_C7 is wired to a button
    # on every variant (io_config.json), so /init's waitkey program is identical
    # for all boards — only the label shown differs.
    local waitkey_key_name
    case "$board_profile" in
        mini) waitkey_key_name="KEY_DOWN" ;;  # FOX_22
        max)  waitkey_key_name="KEY1" ;;      # FOX_40
        pi)   waitkey_key_name="KEY3" ;;      # FOX_PI
        *)    print_error "unknown board profile for waitkey key name: $board_profile"; exit 1 ;;
    esac
    # ss-lcd's display control pins (io_config.json 'display' section): DC/RST
    # differ per HAT, and on max the DC sits on a different gpiochip than RST.
    # Without these the boot frames drive the Mini's pins and stay invisible
    # on the other boards — including the red FAILED screen + escape hatch.
    local lcd_dc_chip lcd_dc_line lcd_rst_chip lcd_rst_line lcd_bl_chip lcd_bl_line
    case "$board_profile" in
        mini) lcd_dc_chip="/dev/gpiochip1"; lcd_dc_line=20;  lcd_rst_chip="/dev/gpiochip1"; lcd_rst_line=19; lcd_bl_chip="";          lcd_bl_line="" ;;  # FOX_22 (no BL pin)
        max)  lcd_dc_chip="/dev/gpiochip2"; lcd_dc_line=8;   lcd_rst_chip="/dev/gpiochip1"; lcd_rst_line=24; lcd_bl_chip="/dev/gpiochip1"; lcd_bl_line=25 ;;  # FOX_40
        pi)   lcd_dc_chip="/dev/gpiochip1"; lcd_dc_line=27;  lcd_rst_chip="/dev/gpiochip1"; lcd_rst_line=24; lcd_bl_chip="/dev/gpiochip2"; lcd_bl_line=6  ;;  # FOX_PI
    esac
    # Key class for /init's pass screen (the dev-key indicator): compare the
    # ACTUAL key bytes used for this build against the committed PUBLIC dev
    # keys by SHA-256 — not by path, so a copy of the dev key under another
    # name still gets flagged. FIT: $ubootdir/keys/dev.pubkey was laid down by
    # provision_fit_build_keys (apply_fit_signature_config ran earlier in this
    # profile's build). Rootfs: $keydir/dev.pubkey is exactly what /init
    # verifies with (it becomes /pubkey below). "dev" means that signature
    # grants no protection; the pass screen shows it in yellow.
    local fit_pub="$ubootdir/keys/dev.pubkey"
    [ -f "$fit_pub" ] || { print_error "FIT signing pubkey missing at $fit_pub (apply_fit_signature_config did not run?)"; exit 1; }
    local dev_fit_hash dev_rootfs_hash keyhash fit_key_class rootfs_key_class
    dev_fit_hash="$(sha256sum "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/dev-keys/dev.pubkey" | cut -d' ' -f1)"
    dev_rootfs_hash="$(sha256sum "$SEEDSIGNER_LUCKFOX_DIR/secure-boot/dev-keys-rootfs/dev.pubkey" | cut -d' ' -f1)"
    keyhash="$(sha256sum "$fit_pub" | cut -d' ' -f1)"
    if [ "$keyhash" = "$dev_fit_hash" ]; then fit_key_class="dev"; else fit_key_class="prod"; fi
    keyhash="$(sha256sum "$keydir/dev.pubkey" | cut -d' ' -f1)"
    if [ "$keyhash" = "$dev_rootfs_hash" ]; then rootfs_key_class="dev"; else rootfs_key_class="prod"; fi
    print_info "signature key classes for /init pass screen: FIT=$fit_key_class rootfs=$rootfs_key_class (dev = public dev key, no protection)"
    sed -e "s/__ROOTFS_SIGNED_SIZE__/$signed_size/" \
        -e "s/__WAITKEY_KEY_NAME__/$waitkey_key_name/" \
        -e "s|__LCD_DC_CHIP__|$lcd_dc_chip|" \
        -e "s/__LCD_DC_LINE__/$lcd_dc_line/" \
        -e "s|__LCD_RST_CHIP__|$lcd_rst_chip|" \
        -e "s/__LCD_RST_LINE__/$lcd_rst_line/" \
        -e "s|__LCD_BL_CHIP__|$lcd_bl_chip|" \
        -e "s|__LCD_BL_LINE__|$lcd_bl_line|" \
        -e "s/__FIT_KEY_CLASS__/$fit_key_class/" \
        -e "s/__ROOTFS_KEY_CLASS__/$rootfs_key_class/" "$src/init" > "$stage/init"
    chmod 755 "$stage/init"
    cp "$keydir/dev.pubkey" "$stage/pubkey"
    cp "$sig"               "$stage/rootfs.sig"
    # Opt-in: verify the rootfs even on an UNFUSED board (/init looks for this
    # marker). Harmless, but gives no real protection without the fuse -- see
    # the comment above FORCED_VERIFY in initramfs/init. The SeedSigner
    # "Luckfox Build Tools" can set or clear the same marker after the build.
    if [ "${SEEDSIGNER_ROOTFS_VERIFY_UNFUSED:-0}" = "1" ]; then
        : > "$stage/force-rootfs-verify"
        print_info "SEEDSIGNER_ROOTFS_VERIFY_UNFUSED=1: rootfs is verified even when secure boot is not fused"
    fi

    # --- deterministic cpio.gz ------------------------------------------------
    # newc headers carry inode + device numbers, which vary with the host's
    # filesystem allocation order; --reproducible (GNU cpio >= 2.13) zeroes
    # them along with uid/gid. mtime is pinned to SOURCE_DATE_EPOCH explicitly
    # (touch), gzip -n drops its timestamp header, and LC_ALL=C sort fixes the
    # entry order — so two builds of the same commit produce identical bytes.
    # touch MUST use -h: without it a symlink's own mtime is never touched
    # (the target is), so every busybox applet link kept its ln(1) wall-clock
    # time and desynced the ramdisk on every build.
    # The archive is written OUTSIDE $stage: it must not appear in the tree
    # while find is still enumerating it (a pipeline runs all three at once).
    local work
    work="$(mktemp -d)"
    local epoch="${SOURCE_DATE_EPOCH:-0}"
    (
        cd "$stage"
        find . -exec touch -h -d "@$epoch" {} + 2>/dev/null || true
        LC_ALL=C find . | LC_ALL=C sort | \
            cpio -o -H newc --owner=0:0 --reproducible --quiet 2>/dev/null | gzip -9 -n > "$work/ramdisk"
    )
    local cpio_size
    cpio_size="$(stat -c %s "$work/ramdisk")"
    print_info "initramfs cpio.gz: ${cpio_size} bytes"

    # --- repack boot.img with the ramdisk slot --------------------------------
    ( cd "$ubootdir" && ./scripts/fit-unpack.sh -f "$img" -o "$work/unpack" ) \
        || { print_error "fit-unpack of boot.img failed"; exit 1; }
    cp "$work/ramdisk" "$work/unpack/ramdisk"

    # fit-unpack.sh's gen_its() emits dtc output (tab-indented), so every edit
    # below is whitespace-tolerant. The conf-level signature node carries
    # sign-images = "fdt", "kernel", "multi"; — the list mkimage -r signs from,
    # which is how the new ramdisk gets covered by sign_boot_image's re-sign.
    local its="$work/unpack/image.its"
    python3 - "$its" <<'PYEOF'
import re, sys
path = sys.argv[1]
s = open(path).read()

if re.search(r'\n\s*ramdisk \{', s):
    sys.exit("boot.img already contains a ramdisk node (double embed?)")

# image node: before the resource node (order inside /images is irrelevant to
# u-boot; keeping it last mirrors how fit-core.sh's own ITS templates grow).
# load = <0xffffff02> is NOT a real address — it is fit-core.sh's
# RAMDISK_ADDR_PLACEHOLDER, which sign_boot_image's sed fixup replaces with
# the board's actual ramdisk_addr_r (same convention as fdt=...ff00 /
# kernel=...ff01 in the vendor template). Do not "fix" it to a real address.
node = """
\t\tramdisk {
\t\t\tdata = /incbin/("ramdisk");
\t\t\ttype = "ramdisk";
\t\t\tarch = "arm";
\t\t\tos = "linux";
\t\t\tcompression = "gzip";
\t\t\tload = <0xffffff02>;

\t\t\thash {
\t\t\t\talgo = "sha256";
\t\t\t};
\t\t};
"""
m = re.search(r"(\n[ \t]*resource \{)", s)
if not m:
    sys.exit("resource node not found in image.its (unexpected FIT layout)")
s = s[:m.start()] + node + s[m.start():]

# conf entry, next to kernel/fdt/multi.
m = re.search(r"(kernel = \"kernel\";)", s)
if not m:
    sys.exit("conf kernel entry not found in image.its")
s = s.replace(m.group(1), m.group(1) + "\n\t\t\tramdisk = \"ramdisk\";", 1)

# sign-images: append ramdisk to whatever list is there (do not hardcode the
# rest — a future ITS change must keep working). U-Boot parses this property as
# a sequence of NUL-terminated strings, and BOTH source forms compile to that:
#   hand-written array : "fdt", "kernel", "multi"
#   dtc re-serialization (what fit-unpack.sh emits): "fdt\0kernel\0multi"
# so append in whichever form is present.
m = re.search(r'sign-images\s*=\s*(?:"[^"]*"|\s*"[^"]*"(?:\s*,\s*"[^"]*")*)\s*;', s)
if not m:
    sys.exit("sign-images property not found in image.its (unexpected FIT layout)")
prop = m.group(0).rstrip().rstrip(';')
body = prop.split('=', 1)[1].strip()
if re.fullmatch(r'"[^"]*"', body):
    # single-string (NUL-escaped) form: append \0ramdisk inside the quotes
    if 'ramdisk' in body:
        sys.exit("ramdisk already listed in sign-images (double embed?)")
    new = prop[:-1] + '\\0ramdisk";'   # drop closing quote, add NUL + name
else:
    # array form: append , "ramdisk" before the ;
    if '"ramdisk"' in body:
        sys.exit("ramdisk already listed in sign-images (double embed?)")
    new = prop + ', "ramdisk";'        # prop ends at the last element's closing quote
s = s[:m.start()] + new + s[m.end():]

open(path, "w").write(s)
PYEOF
    [ $? -eq 0 ] || { print_error "failed to add ramdisk node to image.its"; exit 1; }

    # Same mkimage invocation fit-core.sh uses for boot FITs (./tools/mkimage in
    # the u-boot tree, built by the uboot stage): external data at a fixed
    # offset, no signing here — sign_boot_image does that next. dtc is already
    # required on PATH by fit-unpack.sh above, so nothing extra to check.
    local offs="0x1000"
    if grep -q '^CONFIG_FIT_ENABLE_RSA4096_SUPPORT=y' "$ubootdir/.config" 2>/dev/null; then
        offs="0x1200"
    fi
    local mkimage="$ubootdir/tools/mkimage"
    [ -x "$mkimage" ] || { print_error "u-boot tools/mkimage not built at $mkimage (run the uboot stage first)"; exit 1; }
    ( cd "$work/unpack" && "$mkimage" -f image.its -E -p $offs boot.img.new ) \
        || { print_error "mkimage repack of boot.img failed"; exit 1; }

    # --- assertions before the signed image ships ------------------------------
    local newimg="$work/unpack/boot.img.new"
    ( cd "$ubootdir" && ./scripts/fit-unpack.sh -f "$newimg" -o "$work/check" ) >/dev/null \
        || { print_error "repacked boot.img does not unpack cleanly"; exit 1; }
    [ -s "$work/check/ramdisk" ] || { print_error "ramdisk missing from repacked boot.img"; exit 1; }
    cmp -s "$work/check/ramdisk" "$work/ramdisk" \
        || { print_error "ramdisk in repacked boot.img differs from the built cpio.gz"; exit 1; }

    cp -f "$newimg" "$img"
    rm -rf "$stage" "$work"
    print_success "boot.img now carries the rootfs-verifier initramfs (will be signed by sign_boot_image)"
}

export_fit_sign_tree() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local board_profile="$1"
    local src_img="$LUCKFOX_SDK_DIR/output/image"
    local uboot_cfg="$LUCKFOX_SDK_DIR/sysdrv/source/uboot/u-boot/.config"
    local dst="$OUTPUT_DIR/fit-sign-tree-${board_profile}"
    print_step "Exporting fit-sign tree for ${board_profile} -> $dst"
    [ -d "$src_img" ] || { print_error "output/image missing at $src_img"; exit 1; }
    rm -rf "$dst"; mkdir -p "$dst/fit_signcfg"
    cp -a "$src_img/." "$dst/"
    # fit-sign.sh reads <src-dir>/fit_signcfg/sign.readonly_config (it greps
    # CONFIG_* from it). Prefer the SDK's own fit_signcfg if the build produced
    # one; otherwise synthesize it from the built u-boot .config, which carries
    # the same CONFIG_FIT_SIGNATURE / SPL_FIT_HW_CRYPTO / CHIP_NAME symbols.
    local sdk_signcfg
    sdk_signcfg="$(find "$LUCKFOX_SDK_DIR" -type f -name sign.readonly_config 2>/dev/null | head -n1)"
    if [ -n "$sdk_signcfg" ]; then
        cp -a "$(dirname "$sdk_signcfg")/." "$dst/fit_signcfg/"
        print_success "copied SDK fit_signcfg from $(dirname "$sdk_signcfg")"
    elif [ -f "$uboot_cfg" ]; then
        cp "$uboot_cfg" "$dst/fit_signcfg/sign.readonly_config"
        print_success "synthesized fit_signcfg/sign.readonly_config from built u-boot .config"
    else
        print_error "cannot find fit_signcfg or u-boot .config ($uboot_cfg) to build the sign tree"
        exit 1
    fi
    print_success "fit-sign tree ready. On the host, sign it with:"
    print_success "  opt/luckfox/secure-boot/sign-secure-boot.sh sign --keys <dir> \\"
    print_success "     --images <out> --build-tree build-output/fit-sign-tree-${board_profile} --tools <rkbin/tools>"
}

# Install the secure-boot signers as OS-provided tooling, matching what
# opt/build.sh does for the Pi / La Frite images.
#
# The OS owns them and the app imports them at runtime, so there is one copy and
# nothing can drift. Installed outside /opt because the app tree lives there and
# is pruned above. Pure stdlib, ~55 KB, so the app imports them directly rather
# than shelling out, and the same files double as CLIs for checking a release
# on-device.
#
# A board that should not carry them opts out with a `no-secure-boot-tools` file
# in opt/luckfox/; the app's menu entry then simply does not appear, so
# availability is a build-time decision rather than runtime device detection.
#
# The Pico Mini (RV1103, 64 MB) carries them too: they are ~55 KB of stdlib and
# the heavy paths stream (a full mini-bundle re-sign peaks at ~14 MB measured),
# so carrying the modules costs nothing. An earlier OOM on the Mini was a
# full-file read bug since fixed; the app warns when free memory is low before
# running the heavy actions.
install_secure_boot_tools() {
    local src="$SEEDSIGNER_LUCKFOX_DIR/secure-boot"
    local dst="$ROOTFS_DIR/usr/lib/seedsigner/secure-boot"
    local signers="rkloader.py fitsign.py minisign.py luckfox_release.py"
    local f

    # Clear first, so a rebuild that newly opts out leaves no stale copy.
    rm -rf "$dst"

    if [ -f "$SEEDSIGNER_LUCKFOX_DIR/no-secure-boot-tools" ]; then
        print_info "secure-boot signers: skipped (no-secure-boot-tools)"
        return 0
    fi

    for f in $signers; do
        [ -f "$src/$f" ] || { print_error "secure-boot signer missing: $src/$f"; exit 1; }
    done

    mkdir -p "$dst"
    for f in $signers; do
        cp -f "$src/$f" "$dst/$f"
        chmod 755 "$dst/$f"
    done
    find "$dst" -exec touch -d "@${SOURCE_DATE_EPOCH:-0}" {} +
    print_success "Installed secure-boot signers to /usr/lib/seedsigner/secure-boot"
}

build_profile_artifacts() {
    local board_profile="$1"
    local boot_medium="$2"
    local include_nand="$3"

    cd "$LUCKFOX_SDK_DIR"
    select_board_profile "$board_profile" "$boot_medium"

    # DO NOT run `./build.sh clean` here.
    #
    # It was destroying the image. The SDK's clean runs boardtools_clean,
    # `clean drv` and `clean tools which run on pc`, which delete the PREBUILT
    # board tools that ship in the SDK checkout -- udev, mtd-utils, memtester,
    # stressapptest, rockchip_test, adbd and usbdevice. Nothing rebuilds them,
    # so they never reach the rootfs tarball that build_rootfs extracts, and the
    # image silently ships ~84 files lighter than the validated CI build,
    # including fsck.vfat, which S02fsck and fat-fsck-hotplug need.
    #
    # The validated CI workflow never cleans -- it builds one hardware/boot
    # combination per matrix job in a fresh checkout, so it never needs to. This
    # script can build several profiles in one run, which is the only reason the
    # clean was here.
    #
    # So: never clean for the first profile (identical to CI), and between
    # profiles restore the SDK with git instead. That is strictly better than
    # the SDK's clean -- it puts back the prebuilts and the files earlier
    # profiles patched in place, which `./build.sh clean` does not.
    if [[ -n "${SS_PROFILE_BUILT:-}" ]]; then
        print_step "Restoring pristine SDK before ${board_profile}/${boot_medium}"
        bash "$SEEDSIGNER_LUCKFOX_DIR/prepare-sdk-checkout.sh" "$REPOS_DIR" "$LUCKFOX_REPO_URL"
        cd "$LUCKFOX_SDK_DIR"

        # The reset above reverts EVERY in-place patch the previous profile left
        # behind: partition layout, all of patch-fs-determinism (including the
        # rebuilt mkfs.ubifs under output/ss-tools), the sdkinfo/stressapptest
        # timestamp pins, and the Mini CMA size sed. CI never sees this -- it
        # builds one combination per job from a fresh checkout where
        # apply_sdk_patches ran once before the profile. Re-run it here so every
        # profile starts patched exactly like its CI job does; without this,
        # profiles 2..N of a multi-profile run build unpinned (random ubinize
        # image_seq, live timestamps, host-dependent inode numbering) and WITHOUT
        # the userdata partition layout. All four parts are idempotent and
        # self-verifying, so re-running is safe.
        apply_sdk_patches
    else
        print_info "First profile of this run: SDK left as cloned (matches CI, which never cleans)"
    fi
    export SS_PROFILE_BUILT=1

    # The SDK reset above drops board context; force board selection again.
    select_board_profile "$board_profile" "$boot_medium"
    # AFTER the reset, not before it: the pristine-SDK restore reverts this sed
    # (it edits the SDK's BoardConfig in place), so a call earlier would be
    # undone for profiles 2..N and their env.img would ship the upstream CMA
    # size (24M on Mini) instead of $MINI_CMA_SIZE. Idempotent, like the rest.
    apply_mini_cma_profile
    apply_uart2_console_config "$board_profile" "$boot_medium"
    apply_uart2_console_dts_patch "$board_profile"
    apply_uart2_fiq_kernel_patch "$board_profile" "$boot_medium"
    apply_kernel_network_strip "$board_profile" "$boot_medium"
    apply_readonly_rootfs "$board_profile" "$boot_medium"
    apply_spidev_bufsiz "$board_profile"
    apply_spi_display_dts "$board_profile"
    apply_hwrng_kernel_patch "$board_profile" "$boot_medium"
    apply_rng_dts_patch "$board_profile"
    apply_sdmmc_dts_patch "$board_profile" "$boot_medium"
    apply_otp_size_patch
    apply_fit_signature_config   # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise)
    # Signed builds only: strip blkdevparts/mtdparts from U-Boot's env import
    # whitelist so the unsigned env partition cannot reach the kernel cmdline (M1).
    bash "$SEEDSIGNER_LUCKFOX_DIR/lock-kernel-cmdline.sh" "$LUCKFOX_SDK_DIR"
    # Signed builds only: that whitelist is not the only consumer of the env.
    # mtd_part_parse() (board.c CONFIG_MTD_BLK fallback + the SPL) reads the env
    # directly and serialises partition NAMES into the cmdline; sanitise them so
    # SPI-NAND cannot inject tokens (e.g. rdinit=) either.
    bash "$SEEDSIGNER_LUCKFOX_DIR/patch-mtd-part-parse.sh" "$LUCKFOX_SDK_DIR"
    apply_signed_nand_bootargs "$board_profile" "$boot_medium"   # signed NAND: bake root=ubi0 into the DTB (no-op otherwise)

    # Rootfs verification setup, all no-ops unless SEEDSIGNER_FIT_SIGNATURE=1.
    # provision_rootfs_signing_key must run before `build.sh firmware`: the
    # mkfs_ubi.sh fakeroot script inherits SEEDSIGNER_ROOTFS_SIGNING_KEY from
    # this environment to sign the rootfs volume's logical UBIFS contents.
    rebuild_initramfs_binaries   # opt-in: SEEDSIGNER_REBUILD_INITRAMFS_BINARIES=1 (no-op otherwise)
    verify_initramfs_binaries
    provision_rootfs_signing_key
    apply_initramfs_kernel_config "$board_profile" "$boot_medium"

    # USB role (the adb switch) — shared with CI via configure-usb-mode.sh.
    print_step "Configuring USB mode (SEEDSIGNER_USB_MODE=$SEEDSIGNER_USB_MODE, variant=$SEEDSIGNER_BUILD_VARIANT)"
    local usb_hardware
    case "$board_profile" in
        mini) usb_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  usb_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   usb_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)    print_error "Unsupported board profile for USB-mode patch: $board_profile"; exit 1 ;;
    esac
    bash "$SEEDSIGNER_LUCKFOX_DIR/configure-usb-mode.sh" "$LUCKFOX_SDK_DIR" \
        "$usb_hardware" "$SEEDSIGNER_USB_MODE" "$SEEDSIGNER_BUILD_VARIANT"

    print_step "Preparing Buildroot Configuration (${board_profile}/${boot_medium})"
    ensure_buildroot_tree

    print_step "Installing SeedSigner Packages"
    # Converged, toolchain-aware external-packages from this repo (single set),
    # mounted into the container at $SEEDSIGNER_OS_PACKAGES_DIR.
    cp -rv "$SEEDSIGNER_OS_PACKAGES_DIR/"* "$PACKAGE_DIR/"

    print_step "Updating pyzbar Configuration"
    if [[ -f "$PYZBAR_PATCH" ]]; then
        local python_ver
        python_ver=$(grep -oP 'BR2_PACKAGE_PYTHON3_VERSION="\K[^"]+' "$BUILDROOT_DIR/.config" 2>/dev/null || true)
        if [[ -z "$python_ver" ]]; then
            python_ver="$DEFAULT_PYTHON_VERSION"
            print_info "Python version not found in Buildroot config; using default: $python_ver"
        else
            print_info "Detected Python version from Buildroot config: $python_ver"
        fi
        sed -i "s|path = \".*/site-packages/zbar.so\"|path = \"/usr/lib/python${python_ver}/site-packages/zbar.so\"|" "$PYZBAR_PATCH"
    fi

    # Normalize python-pyzbar download source for Buildroot mirror compatibility.
    # Keep the same upstream content/hash, but force a deterministic tag tarball URL.
    local pyzbar_mk="${PACKAGE_DIR}/python-pyzbar/python-pyzbar-ss.mk"
    local pyzbar_hash="${PACKAGE_DIR}/python-pyzbar/python-pyzbar-ss.hash"
    if [[ -f "$pyzbar_mk" ]]; then
        local pyzbar_ver
        local pyzbar_src
        pyzbar_ver=$(sed -n 's/^PYTHON_PYZBAR_VERSION[[:space:]]*=[[:space:]]*//p' "$pyzbar_mk" | head -n 1 | tr -d '[:space:]')
        pyzbar_src="v${pyzbar_ver}.tar.gz"
        sed -i "s|^PYTHON_PYZBAR_SITE[[:space:]]*=.*|PYTHON_PYZBAR_SITE = https://github.com/SeedSigner/pyzbar/archive/refs/tags|" "$pyzbar_mk"
        if grep -q '^PYTHON_PYZBAR_SOURCE[[:space:]]*=' "$pyzbar_mk"; then
            sed -i "s|^PYTHON_PYZBAR_SOURCE[[:space:]]*=.*|PYTHON_PYZBAR_SOURCE = ${pyzbar_src}|" "$pyzbar_mk"
        else
            sed -i "/^PYTHON_PYZBAR_SITE[[:space:]]*=/a PYTHON_PYZBAR_SOURCE = ${pyzbar_src}" "$pyzbar_mk"
        fi
        sed -i '/^PYTHON_PYZBAR_SITE_METHOD[[:space:]]*=/d' "$pyzbar_mk"
        print_info "Normalized python-pyzbar source to ${pyzbar_src}"

        if [[ -f "$pyzbar_hash" ]]; then
            sed -i -E "/^(sha256|md5)[[:space:]]/ s/[[:space:]][^[:space:]]+$/ ${pyzbar_src}/" "$pyzbar_hash"
            print_info "Updated python-pyzbar hash filename to ${pyzbar_src}"
        fi
    fi

    print_step "Adding SeedSigner Menu to Buildroot"
    if ! grep -q '^menu "SeedSigner"$' "$CONFIG_IN"; then
        cat << 'CONFIGMENU' >> "$CONFIG_IN"
menu "SeedSigner"
        source "package/python-urtypes/Config.in"
        source "package/python-pyzbar/Config.in"
        source "package/python-mock/Config.in"
        source "package/python-embit/Config.in"
        source "package/python-mnemonic/Config.in"
        source "package/python-shamir-mnemonic/Config.in"
        source "package/python-pillow/Config.in"
        source "package/zbar/Config.in"
        source "package/jpeg-turbo/Config.in.options"
        source "package/jpeg/Config.in"
        source "package/python-qrcode/Config.in"
        source "package/python-pyqrcode/Config.in"
        source "package/python-pyscard/Config.in"
        source "package/python-pysatochip/Config.in"
        source "package/python-pgpy/Config.in"
        source "package/ccid-sec1210/Config.in"
        source "package/python-ndeflib/Config.in"
        source "package/python-keycard-py/Config.in"
        source "package/python-specter-card/Config.in"
        source "package/python-pygp/Config.in"
        source "package/python-smbus2/Config.in"
        source "package/libraqm/Config.in"
endmenu
CONFIGMENU
    fi

    # Patch Rust Kconfig to support uclibc Tier 3 targets (armv7-unknown-linux-uclibceabihf).
    # Buildroot 2024.11.4 only gates Rust target support for glibc/musl. Without this,
    # BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS is never set for uclibc toolchains,
    # silently disabling python-cryptography and any other Rust-dependent package.
    RUSTC_CONFIG="${PACKAGE_DIR}/rustc/Config.in.host"
    if [[ -f "$RUSTC_CONFIG" ]] && ! grep -q 'BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS' "$RUSTC_CONFIG"; then
        print_step "Patching Rust Config.in.host for uclibc Tier 3 support"
        sed -i '/^# All target rust packages should depend on this option/i\
# Tier 3 uclibc platforms - must be built from source (no pre-built std binaries)\
# When adding new entries below, update RUST_TARGETS in utils/update-rust\
config BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS\
\tbool\
\t# armv7-unknown-linux-uclibceabihf\
\tdefault y if BR2_ARM_CPU_ARMV7A \&\& BR2_ARM_EABIHF \&\& BR2_TOOLCHAIN_USES_UCLIBC\
\t# armv7-unknown-linux-uclibceabihf for armv8 hardware with 32-bit userspace\
\tdefault y if BR2_arm \&\& BR2_ARM_CPU_ARMV8A \&\& BR2_ARM_EABIHF \&\& BR2_TOOLCHAIN_USES_UCLIBC\
' "$RUSTC_CONFIG"
        sed -i '/default y if BR2_PACKAGE_HOST_RUSTC_TARGET_TIER2_PLATFORMS/a\
\tdefault y if BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS' "$RUSTC_CONFIG"
    fi

    # Patch rust-bin.mk to skip downloading/installing pre-built rust-std for uclibc
    # (pre-built binaries don't exist for Tier 3 targets; host-rust builds them from source)
    RUSTBIN_MK="${PACKAGE_DIR}/rust-bin/rust-bin.mk"
    if [[ -f "$RUSTBIN_MK" ]] && ! grep -q 'BR2_TOOLCHAIN_USES_UCLIBC' "$RUSTBIN_MK"; then
        print_step "Patching rust-bin.mk to skip uclibc std download"
        sed -i '/^ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)/{
N
/HOST_RUST_BIN_EXTRA_DOWNLOADS/{
s/ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\n/# Pre-built rust-std is not available for uclibc Tier 3 targets;\n# host-rust (build from source) will compile it instead.\nifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\nifneq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)\n/
}
}' "$RUSTBIN_MK"
        sed -i '/^HOST_RUST_BIN_EXTRA_DOWNLOADS += rust-std/{
N
/^HOST_RUST_BIN_EXTRA_DOWNLOADS.*\nendif/{
s/\nendif/\nendif\nendif/
}
}' "$RUSTBIN_MK"
        sed -i '/^ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)/{
N
/define HOST_RUST_BIN_INSTALL_LIBSTD_TARGET/{
s/ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\n/# Skip installing pre-built target std for uclibc (not available);\n# host-rust (build from source) provides it.\nifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\nifneq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)\n/
}
}' "$RUSTBIN_MK"
        sed -i '/^endef/{
N
/^endef\nendif/{
s/^endef\nendif/endef\nendif\nendif/
}
}' "$RUSTBIN_MK"
    fi

    # Patch rust.mk so x.py honours the memory-based job cap. host-rust's
    # HOST_RUST_BUILD_CMDS runs `x.py build` and HOST_RUST_INSTALL_CMDS runs
    # `x.py dist`, both with no --jobs, so x.py defaults LLVM's
    # cmake --build --parallel to num_cpus() and ignores MAKEFLAGS/BR2_JLEVEL
    # (and CMAKE_BUILD_PARALLEL_LEVEL) entirely -- without this the LLVM
    # compile goes wide-open and OOMs the host. The `--jobs` CLI flag is the
    # only knob rust 1.82's bootstrap still reads (the `jobs` config.toml
    # field was removed -- a previous attempt that injected `echo "jobs = "`
    # into HOST_RUST_CONFIGURE_CMDS made x.py fail with
    # "Failed to parse 'config.toml': unknown field `jobs`").
    RUST_MK="${PACKAGE_DIR}/rust/rust.mk"
    if [[ -f "$RUST_MK" ]]; then
        # Revert any stale `jobs =` config.toml injection left by an earlier
        # build (idempotent: line is absent on a fresh buildroot unpack).
        if grep -q 'echo "jobs = ' "$RUST_MK"; then
            print_step "Removing stale config.toml jobs= injection from rust.mk"
            sed -i '/echo "jobs = /d' "$RUST_MK"
        fi
        # Cap both x.py invocations. `$$` -> `$` after make, so the recipe
        # shell expands ${RUST_BUILD_JOBS} (inherited from this script's
        # export). Guarded so re-runs don't double-append `--jobs`.
        if ! grep -q 'x.py build --jobs' "$RUST_MK"; then
            print_step "Patching rust.mk to cap x.py/LLVM parallelism (--jobs)"
            sed -i 's#x\.py build$#x.py build --jobs $${RUST_BUILD_JOBS}#' "$RUST_MK"
            sed -i 's#x\.py dist$#x.py dist --jobs $${RUST_BUILD_JOBS}#' "$RUST_MK"
        fi
    fi

    print_step "Applying SeedSigner Configuration"
    if [[ -f "/build/configs/luckfox_pico_defconfig" ]]; then
        cp -v "/build/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/configs/luckfox_pico_defconfig"
        # Also copy as luckfox_pico_w_defconfig so the Pi board (RK_BUILDROOT_DEFCONFIG=luckfox_pico_w_defconfig)
        # loads our clean config instead of the SDK's WiFi/BT-enabled config
        cp -v "/build/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/configs/luckfox_pico_w_defconfig"
        cp -v "/build/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/.config"

        # Non-dev (production) hardening: no serial login (getty), no dev/network CLI tools.
        if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
            print_info "non-dev: hardening defconfig (getty off; drop pip/curl/wget)"
            for dc in "$BUILDROOT_DIR/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/configs/luckfox_pico_w_defconfig" "$BUILDROOT_DIR/.config"; do
                [[ -f "$dc" ]] || continue
                sed -i -E \
                    -e 's/^BR2_TARGET_GENERIC_GETTY=y/# BR2_TARGET_GENERIC_GETTY is not set/' \
                    -e 's/^BR2_PACKAGE_PYTHON_PIP=y/# BR2_PACKAGE_PYTHON_PIP is not set/' \
                    -e 's/^BR2_PACKAGE_WGET=y/# BR2_PACKAGE_WGET is not set/' \
                    -e 's/^BR2_PACKAGE_LIBCURL=y/# BR2_PACKAGE_LIBCURL is not set/' \
                    -e 's/^BR2_PACKAGE_LIBCURL_CURL=y/# BR2_PACKAGE_LIBCURL_CURL is not set/' \
                    -e 's/^BR2_OPTIMIZE_3=y/BR2_OPTIMIZE_S=y/' \
                    "$dc"
            done
        fi
    else
        print_error "SeedSigner configuration file not found"
        exit 1
    fi

    # Unset GITHUB_ACTIONS so Rust's x.py bootstrap doesn't enforce --stage 2.
    # Rust 1.82+'s CiEnv::current() checks GITHUB_ACTIONS (not CI) to detect
    # CI environments, and panics if stage != 2. Buildroot's host-rust calls
    # x.py build without --stage 2.
    unset GITHUB_ACTIONS
    # Remove pip/setuptools/git from Mini SPI-NAND builds to save space
    if [[ "$board_profile" == "mini" ]] && [[ "$boot_medium" == "nand" ]]; then
        print_info "Removing python-pip, python-setuptools, and git for Mini SPI-NAND build..."
        sed -i "s/^BR2_PACKAGE_PYTHON_PIP=y/# BR2_PACKAGE_PYTHON_PIP is not set/" "$BUILDROOT_DIR/.config"
        sed -i "s/^BR2_PACKAGE_PYTHON_SETUPTOOLS=y/# BR2_PACKAGE_PYTHON_SETUPTOOLS is not set/" "$BUILDROOT_DIR/.config"
        sed -i "s/^BR2_PACKAGE_GIT=y/# BR2_PACKAGE_GIT is not set/" "$BUILDROOT_DIR/.config"
        print_info "Removed pip/setuptools/git packages for Mini SPI-NAND"
    fi

    # Non-dev U-Boot recovery: bootdelay=0 + memory-backed bootcount → rockusb
    # Loader failover. Shared with CI via uboot-recovery-config.sh.
    if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
        print_step "Applying non-dev U-Boot recovery config (bootcount → loader failover)"
        bash "$SEEDSIGNER_LUCKFOX_DIR/uboot-recovery-config.sh" "$LUCKFOX_SDK_DIR"
    fi

    # Restore the cached host Rust toolchain, if the caller provided a cache.
    # Must land after ensure_buildroot_tree (the tree it unpacks into has to
    # exist) and before the first step that can trigger the Rust build.
    if [[ -n "$RUST_TOOLCHAIN_CACHE" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/rust-toolchain-cache.sh" restore \
            "$LUCKFOX_SDK_DIR" "$RUST_TOOLCHAIN_CACHE"
    fi

    print_step "Building U-Boot"
    sdk_build uboot

    # Assert FIT signature ENFORCEMENT actually landed in the built U-Boot .config
    # (SEEDSIGNER_FIT_SIGNATURE=1 only). apply_fit_signature_config wrote it to the
    # defconfig, but Kconfig silently drops symbols with unmet deps — signing would
    # still pass while the board enforces nothing. Same GENERATED-.config discipline
    # as assert-kernel-network.sh below. No-op on unsigned builds.
    bash "$SEEDSIGNER_LUCKFOX_DIR/assert-uboot-fit-signature.sh" "$LUCKFOX_SDK_DIR"

    print_step "Building Kernel"
    sdk_build kernel

    # Assert the strip took effect against the GENERATED .config — Kconfig
    # silently drops defconfig lines whose symbol/deps don't resolve.
    if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/assert-kernel-network.sh" "$LUCKFOX_SDK_DIR" "${SS_STRIP_NET:-1}" 1 1
        bash "$SEEDSIGNER_LUCKFOX_DIR/assert-readonly-rootfs.sh" "$LUCKFOX_SDK_DIR" "${SS_BOARD_CONFIG:-}" "${SS_RO_ROOTFS:-0}"
    fi

    # Secure-boot fuse readability (dev AND non-dev: /init's "SECURE BOOT not
    # enabled" screen needs it in both). No-op unless FIT signing is on.
    if [[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/assert-otp-size.sh" "$LUCKFOX_SDK_DIR"
    fi

    print_step "Building Rootfs"
    sdk_build rootfs

    # host-rust is built and installed by now, so this is the first point the
    # toolchain can be captured. Runs unconditionally when a cache path is set:
    # the script no-ops when the toolchain came from the cache unchanged.
    if [[ -n "$RUST_TOOLCHAIN_CACHE" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/rust-toolchain-cache.sh" package \
            "$LUCKFOX_SDK_DIR" "$RUST_TOOLCHAIN_CACHE" || \
            print_info "Rust toolchain caching failed (build continues)"
    fi

    print_step "Building Media Support"
    sdk_build media

    # Keep vendor RkLunch.sh camera bring-up behavior on all builds.
    print_info "Keeping RkLunch.sh rkipc autostart enabled"

    print_step "Building Applications"
    sdk_build app

    resolve_rootfs_dir

    print_step "Installing SeedSigner Code"
    # Install the whole app repo to /opt, matching the Raspberry Pi SeedSigner-OS
    # layout: /opt/src runs the app and its sibling resource dirs resolve
    # (/opt/javacard-cap bundled applets, /opt/gpg_keys release keys). Prune below.
    mkdir -p "$ROOTFS_DIR/opt"
    cp -a "$SEEDSIGNER_CODE_DIR/." "$ROOTFS_DIR/opt/"

    # Generate the SeedSigner OS identity + provenance marker. App git data comes
    # from the cloned repo. There is no seedsigner-os checkout inside the
    # container, so the OS fields have to be supplied from outside: build.sh
    # forwards SEEDSIGNER_OS_{REPO,BRANCH,COMMIT,DATE} when the caller sets them
    # (CI does), and gen-os-release.sh reads them straight from the environment.
    # Unset -> "unknown", which is what every Docker build recorded before those
    # variables were forwarded. (gen-os-release.sh is mounted at /build.)
    if [ -f /build/gen-os-release.sh ]; then
        SEEDSIGNER_APP_REPO="$SEEDSIGNER_REPO_URL" \
        SEEDSIGNER_APP_BRANCH="$SEEDSIGNER_BRANCH" \
        SEEDSIGNER_APP_GIT_DIR="$SEEDSIGNER_CODE_DIR" \
          bash /build/gen-os-release.sh "$ROOTFS_DIR/etc/seedsigner-os-release" \
          || print_error "Could not generate seedsigner-os-release"
    fi

    # Bake the default the boot clock is set from. The RV1106 has no RTC and
    # these images have no NTP, so without this the device comes up at whatever
    # the SoC left behind — which broke GPG key generation outright. Derived
    # from the pinned app commit, so it stays reproducible. Shared with CI via
    # install-build-time.sh; fails the build rather than shipping a bad clock.
    if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/install-build-time.sh" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/install-build-time.sh" "$ROOTFS_DIR" "$SEEDSIGNER_CODE_DIR"
    fi

    # Persistent boot log is OFF by default: a production device writes nothing
    # to flash, and the log captures app output that would otherwise sit in
    # /userdata (which survives a reflash) long after the failure. Bake the
    # marker only when explicitly requested (SEEDSIGNER_BOOT_LOG=on).
    if [ "$SEEDSIGNER_BOOT_LOG" = "on" ]; then
        : > "$ROOTFS_DIR/etc/seedsigner-boot-log"
        print_info "Persistent boot log ENABLED (/etc/seedsigner-boot-log)"
    else
        rm -f "$ROOTFS_DIR/etc/seedsigner-boot-log" 2>/dev/null || true
        print_info "persistent boot log disabled (default)"
    fi

    print_step "Cleaning up non-essential files from rootfs"
    # Keep src, javacard-cap, gpg_keys, tools; drop dev/build cruft (mirror opt/build.sh).
    rm -rf "$ROOTFS_DIR/opt/.git" "$ROOTFS_DIR/opt/.github" "$ROOTFS_DIR/opt/.translation-venv"
    rm -rf "$ROOTFS_DIR/opt/docker" "$ROOTFS_DIR/opt/docs" "$ROOTFS_DIR/opt/enclosures" \
           "$ROOTFS_DIR/opt/electronics" "$ROOTFS_DIR/opt/l10n" \
           "$ROOTFS_DIR/opt/seedsigner-screenshots" "$ROOTFS_DIR/opt/tests" \
           "$ROOTFS_DIR/opt/hardware-kicad" "$ROOTFS_DIR/opt/img" "$ROOTFS_DIR/opt/test_suite"
    rm -f  "$ROOTFS_DIR/opt/.gitignore" "$ROOTFS_DIR/opt/.gitmodules" \
           "$ROOTFS_DIR/opt/.gitattributes" "$ROOTFS_DIR/opt/.python-version" \
           "$ROOTFS_DIR/opt/README.md" "$ROOTFS_DIR/opt/LICENSE.md" \
           "$ROOTFS_DIR/opt/docker-compose.yml" "$ROOTFS_DIR/opt/MANIFEST.in" \
           "$ROOTFS_DIR/opt/pyproject.toml" "$ROOTFS_DIR/opt/seedsigner_pubkey.gpg"
    rm -f  "$ROOTFS_DIR/opt/"setup.* "$ROOTFS_DIR/opt/"requirements*.txt
    rm -rf "$ROOTFS_DIR/opt/src/seedsigner/resources/seedsigner-translations/.git"* 2>/dev/null || true
    find "$ROOTFS_DIR/opt/src/seedsigner/resources/seedsigner-translations/l10n" \
         -name '*.po' -delete 2>/dev/null || true
    print_success "Cleaned up non-essential files"

    install_secure_boot_tools

    # Mini hardware_config (FOX_22 vs FOX_40).
    #
    # NOTE: this is currently a NO-OP, deliberately kept in step with CI rather
    # than removed. The app has no checked-in src/settings.json -- it is a
    # RUNTIME file the app writes into the OS data dir -- so there is nothing
    # here to patch, and the inline CI's identical block has only ever printed
    # "settings.json not found" and moved on. The Mini therefore does NOT get
    # its hardware_config from the build, and any theory that it does is wrong.
    #
    # Kept (a) so the two implementations stay comparable, and (b) so that if a
    # future app version does ship a template, both patch it the same way.
    # Explicitly NOT fatal: making it fatal turned a harmless no-op into a
    # failed build 3h46m in.
    local settings_json="$ROOTFS_DIR/opt/src/settings.json"
    if [[ "$board_profile" == "mini" ]]; then
        if [[ -f "$settings_json" ]]; then
            sed -i 's/"hardware_config":[[:space:]]*"FOX_40"/"hardware_config": "FOX_22"/g' "$settings_json"
            print_success "settings.json patched for Mini hardware (FOX_22)"
        else
            print_info "no src/settings.json in the app checkout — nothing to patch (expected)"
        fi
    fi

    # pyzbar dlopens zbar.so by bare name, so it has to be resolvable from the
    # default library path -- the shared object itself is installed under
    # site-packages. Missing here while both the inline CI and build-local.sh
    # created it: without it `import pyzbar` raises at app startup, which again
    # ends as a Loader reboot rather than an error anyone can see.
    local rootfs_python
    rootfs_python="$(ls "$ROOTFS_DIR/usr/lib/" | grep -E '^python3\.[0-9]+$' | head -n 1)"
    if [[ -n "$rootfs_python" ]]; then
        local site_packages="$ROOTFS_DIR/usr/lib/$rootfs_python/site-packages"
        if [[ -f "$site_packages/zbar.so" ]]; then
            # A failure HERE is a real error -- the source exists and the link
            # could not be made. Absence of zbar.so is only a warning, matching
            # CI, so this cannot false-fail a build the validated path allows.
            if ! ln -sf "$rootfs_python/site-packages/zbar.so" "$ROOTFS_DIR/usr/lib/zbar.so"; then
                print_error "Could not create /usr/lib/zbar.so symlink"
                exit 1
            fi
            print_success "Created /usr/lib/zbar.so -> $rootfs_python/site-packages/zbar.so"
        else
            print_warning "zbar.so not found at $site_packages/zbar.so — pyzbar will fail to import"
            find "$ROOTFS_DIR" -name 'zbar.so' 2>/dev/null || true
        fi
    else
        print_warning "Could not detect the python3.x directory in $ROOTFS_DIR/usr/lib/"
    fi

    # Diagnostic aid (off by default): when SEEDSIGNER_ENABLE_ERROR_DIAGNOSTICS=1
    # is set in the build environment, ship the marker that enables the app's
    # opt-in "Save to MicroSD" button on OS/package error screens (see
    # seedsigner repo: helpers/seedsigner_os.py
    # is_error_microsd_export_enabled()). Its presence is also flagged by the
    # app's own hardening self-check.
    if [ "${SEEDSIGNER_ENABLE_ERROR_DIAGNOSTICS:-0}" = "1" ]; then
        mkdir -p "$ROOTFS_DIR/etc"
        touch "$ROOTFS_DIR/etc/seedsigner-error-microsd-export"
    fi

    # Testing build, off by default: when SEEDSIGNER_TESTING_BUILD=1 is set in
    # the build environment, ship the marker that swaps Home's menu for the
    # hardware test menu (see seedsigner repo: helpers/seedsigner_os.py
    # is_testing_build_enabled()).
    if [ "${SEEDSIGNER_TESTING_BUILD:-0}" = "1" ]; then
        mkdir -p "$ROOTFS_DIR/etc"
        touch "$ROOTFS_DIR/etc/seedsigner-testing-build"
    fi

    print_step "Installing SeedSigner Support Files"
    local luckfox_cfg_template="/build/files/luckfox-${board_profile}.cfg"
    if [[ -f "$luckfox_cfg_template" ]]; then
        cp -v "$luckfox_cfg_template" "$ROOTFS_DIR/etc/luckfox.cfg"
    elif [[ -f "/build/files/luckfox.cfg" ]]; then
        print_info "Variant template not found for ${board_profile}, falling back to /build/files/luckfox.cfg"
        cp -v "/build/files/luckfox.cfg" "$ROOTFS_DIR/etc/luckfox.cfg"
    fi
    [[ -f "/build/files/nv12_converter" ]] && cp -v "/build/files/nv12_converter" "$ROOTFS_DIR/"
    [[ -f "/build/files/start-seedsigner.sh" ]] && cp -v "/build/files/start-seedsigner.sh" "$ROOTFS_DIR/"
    if [[ -f "/build/files/configure-gpio.sh" ]]; then
        cp -v "/build/files/configure-gpio.sh" "$ROOTFS_DIR/usr/bin/configure-gpio.sh"
        chmod +x "$ROOTFS_DIR/usr/bin/configure-gpio.sh"
    fi
    # Startup-failure message on the panel (the "loading" mode is no longer
    # called at boot; see files/show-screen-message.py).
    if [[ -f "/build/files/show-screen-message.py" ]]; then
        cp -v "/build/files/show-screen-message.py" "$ROOTFS_DIR/usr/bin/show-screen-message.py"
        chmod +x "$ROOTFS_DIR/usr/bin/show-screen-message.py"
    fi
    # SPI bus-configuration sweep, triggered by a `display-probe` marker file.
    if [[ -f "/build/files/probe-display.py" ]]; then
        cp -v "/build/files/probe-display.py" "$ROOTFS_DIR/usr/bin/probe-display.py"
        chmod +x "$ROOTFS_DIR/usr/bin/probe-display.py"
    fi
    if [[ -f "/build/files/rk-reboot" ]]; then
        cp -v "/build/files/rk-reboot" "$ROOTFS_DIR/usr/bin/rk-reboot"
        chmod +x "$ROOTFS_DIR/usr/bin/rk-reboot"
    fi
    # Must sort before every other init script: luckfox-config rewrites
    # /etc/luckfox.cfg at S99 and needs /etc writable by then.
    [[ -f "/build/files/S01overlay" ]] && cp -v "/build/files/S01overlay" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S02fsck" ]] && cp -v "/build/files/S02fsck" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S10mdev" ]] && cp -v "/build/files/S10mdev" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S60pcscd" ]] && cp -v "/build/files/S60pcscd" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S99seedsigner" ]] && cp -v "/build/files/S99seedsigner" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "$ROOTFS_DIR/etc/init.d/S01overlay" ]] && chmod +x "$ROOTFS_DIR/etc/init.d/S01overlay"
    [[ -f "$ROOTFS_DIR/etc/init.d/S02fsck" ]] && chmod +x "$ROOTFS_DIR/etc/init.d/S02fsck"
    [[ -f "$ROOTFS_DIR/etc/init.d/S10mdev" ]] && chmod +x "$ROOTFS_DIR/etc/init.d/S10mdev"
    [[ -f "$ROOTFS_DIR/etc/init.d/S60pcscd" ]] && chmod +x "$ROOTFS_DIR/etc/init.d/S60pcscd"
    [[ -f "$ROOTFS_DIR/etc/init.d/S99seedsigner" ]] && chmod +x "$ROOTFS_DIR/etc/init.d/S99seedsigner"
    if [[ -f "/build/files/mdev.conf" ]]; then
        cp -v "/build/files/mdev.conf" "$ROOTFS_DIR/etc/mdev.conf"
    fi
    if [[ -f "/build/files/fat-fsck-hotplug" ]]; then
        cp -v "/build/files/fat-fsck-hotplug" "$ROOTFS_DIR/usr/sbin/fat-fsck-hotplug"
        chmod +x "$ROOTFS_DIR/usr/sbin/fat-fsck-hotplug"
    fi
    if [[ -f "/build/files/sec1210" ]]; then
        mkdir -p "$ROOTFS_DIR/etc/reader.conf.d"
        cp -v "/build/files/sec1210" "$ROOTFS_DIR/etc/reader.conf.d/sec1210"
        mkdir -p "$ROOTFS_DIR/etc/readers.d"
        cp -v "/build/files/sec1210" "$ROOTFS_DIR/etc/readers.d/sec1210"
    fi
    if [[ -d "$ROOTFS_DIR/usr/lib/pcsc/drivers/ifd-ccid.bundle" ]]; then
        print_warning "Removing USB CCID bundle as temporary workaround for pcscd SIGTERM issue"
        rm -rf "$ROOTFS_DIR/usr/lib/pcsc/drivers/ifd-ccid.bundle"
    fi
    
    # Install rkaiq camera ISP service script (manual start only, no boot autostart)
    if [[ -f "/build/files/rkaiq-service" ]]; then
        print_info "Installing rkaiq service script..."
        cp -v "/build/files/rkaiq-service" "$ROOTFS_DIR/usr/bin/rkaiq-service"
        chmod +x "$ROOTFS_DIR/usr/bin/rkaiq-service"
        print_success "Installed rkaiq-service to /usr/bin/"
    else
        print_warning "rkaiq-service not found, rkaiq-service will not be available"
    fi

    # USB host-mode fix (all variants; runtime no-op on gadget builds): make
    # S50usbdevice skip the gadget — but still mount configfs (display needs
    # it) — when dr_mode=host. Shared with CI via patch-s50usbdevice.sh.
    if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/patch-s50usbdevice.sh" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/patch-s50usbdevice.sh" "$ROOTFS_DIR"
    fi

    # GnuPG agent/scdaemon config, staged into /usr/share for start-seedsigner.sh
    # to seed into GNUPGHOME on tmpfs. The app never sets GNUPGHOME, so without
    # this gpg writes to /.gnupg on the read-only root and key generation/import
    # both fail. Shared with CI via install-gnupg-home.sh.
    if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/install-gnupg-home.sh" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/install-gnupg-home.sh" "$ROOTFS_DIR"
    fi

    # Non-dev (production) rootfs hardening: serial login, adb artifacts,
    # logging daemons, networking (interface bring-up + DHCP + telnet/ssh).
    if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
        print_step "Applying non-dev rootfs hardening"
        if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/harden-nondev.sh" ]]; then
            # ADB transport removal is the dr_mode=host DTS switch (configure-usb-mode.sh);
            # HARDEN_DISABLE_ADB=1 additionally strips the adb userspace. Networking:
            # SEEDSIGNER_DEBUG_NETWORK on => keep Ethernet+telnet (debug), else disable.
            local harden_net=1
            if [[ "$SEEDSIGNER_DEBUG_NETWORK" == "on" ]]; then harden_net=0; fi
            local harden_adb=1
            if [[ "$SEEDSIGNER_HARDEN_ADB" == "off" ]]; then harden_adb=0; fi
            HARDEN_DISABLE_ADB="$harden_adb" HARDEN_DISABLE_NETWORK="$harden_net" \
                bash "$SEEDSIGNER_LUCKFOX_DIR/harden-nondev.sh" "$ROOTFS_DIR" || print_error "non-dev hardening reported an error"
        fi
        if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/optimize-nondev.sh" ]]; then
            bash "$SEEDSIGNER_LUCKFOX_DIR/optimize-nondev.sh" "$ROOTFS_DIR" || print_error "non-dev optimization reported an error"
        fi
        # /etc/fw_env.config: optional fw_printenv access to the mtd0 U-Boot env
        # (informational only — the failover env is compiled-in, see
        # uboot-recovery-config.sh).
        if [[ -f "$SEEDSIGNER_LUCKFOX_DIR/files/fw_env.config" ]]; then
            cp -v "$SEEDSIGNER_LUCKFOX_DIR/files/fw_env.config" "$ROOTFS_DIR/etc/fw_env.config"
        fi
    else
        print_info "dev build: skipping rootfs hardening/optimization (serial console + adb retained, SDK-default boot)"
    fi

    # Precompile app + site-packages bytecode with the TARGET interpreter's own
    # compileall: the read-only squashfs can never cache __pycache__ at runtime,
    # so every import would otherwise re-compile .py source off xz squashfs on
    # every boot (the Pi profiles precompile at build time for the same reason).
    # Runs after hardening/optimization, which prune parts of the python tree.
    # Shared with CI via precompile-bytecode.sh.
    bash "$SEEDSIGNER_LUCKFOX_DIR/precompile-bytecode.sh" "$ROOTFS_DIR" "$LUCKFOX_SDK_DIR"

    # Drop whitespace-named entries (test fixtures like setuptools' vendored
    # jaraco.text `Lorem ipsum.txt`) before build_mkimg packs the ext4 root:
    # mkfs-ext4-deterministic.sh cannot represent such names and fails the
    # build. No-op for trees without any; every removal is logged.
    bash "$SEEDSIGNER_LUCKFOX_DIR/strip-whitespace-filenames.sh" "$ROOTFS_DIR"

    # Install the oem iqfiles prune + rootfs prep into the SDK's pre-build-OEM
    # hook. The oem tree is assembled by __PACKAGE_OEM inside `build.sh firmware`,
    # so this is the only window where it exists and is still editable (before
    # build_firmware() folds it into the rootfs and packs the squashfs). Shared
    # with CI via patch-oem-pre-hook.sh.
    if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
        local oem_board_config="$LUCKFOX_SDK_DIR/.BoardConfig.mk"
        [[ -e "$oem_board_config" ]] || oem_board_config=""
        if [[ -n "$oem_board_config" ]]; then
            bash "$SEEDSIGNER_LUCKFOX_DIR/patch-oem-pre-hook.sh" \
                "$(readlink -f "$oem_board_config")" \
                "$SEEDSIGNER_LUCKFOX_DIR/prune-oem-iqfiles.sh" \
                || print_error "oem pre-build hook patch reported an error"
        else
            print_info "no .BoardConfig.mk symlink — skipping oem iqfiles prune hook"
        fi
    fi

    print_step "Packaging Firmware"
    sdk_build firmware
    embed_rootfs_verifier "$board_profile" "$boot_medium"   # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise). BEFORE sign_boot_image so the FIT signature covers the new ramdisk.
    sign_boot_image                         # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise). BEFORE deterministic_sign_chain so our re-sign covers the final boot.img.
    deterministic_sign_chain                # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise). Digest-derived salts + zeroed timestamp => byte-reproducible signatures. BEFORE normalise so update.img embeds them.
    normalise_boot_images
    export_fit_sign_tree "$board_profile"   # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise)
    # The SDK emits sd_update.txt/tftp_update.txt staging every partition at
    # ${ramdisk_addr_r} = 0x00E00000, which leaves ~31 MiB below U-Boot's own
    # relocated stack/heap on a 64 MiB Mini. Our 38.6 MiB rootfs.img does not fit
    # there: mw.b overwrote the running loader and the microSD auto-flash hung
    # mid-write with no console output. Restage low and hard-fail if any image
    # ever outgrows the window again. Shared with build-local.sh.
    bash "$SEEDSIGNER_LUCKFOX_DIR/patch-sd-update-scripts.sh" "$LUCKFOX_SDK_DIR" "$board_profile"
    # Re-verify after the fold: the oem tree is now inside the signed rootfs at
    # /oem/usr/ko (apply-partition-layout.sh removes the partition), and its .ko
    # are still loadable by root, so a stray wireless module would be a hole.
    # REQUIRE_OEM=1 (5th arg) makes a missing/moved oem payload or a leftover
    # oem.img a hard failure rather than a silent skip.
    if [[ "$SEEDSIGNER_BUILD_VARIANT" == "non-dev" ]]; then
        bash "$SEEDSIGNER_LUCKFOX_DIR/assert-kernel-network.sh" "$LUCKFOX_SDK_DIR" "${SS_STRIP_NET:-1}" 1 1 1
        bash "$SEEDSIGNER_LUCKFOX_DIR/assert-readonly-rootfs.sh" "$LUCKFOX_SDK_DIR" "${SS_BOARD_CONFIG:-}" "${SS_RO_ROOTFS:-0}"
    fi
    debug_uart_bootargs_outputs

    cd "$LUCKFOX_SDK_DIR/output/image"

    # Artifact name tag. This used to be $(date +%Y%m%d_%H%M%S), which put a
    # wall-clock stamp in the name of every image and bundle -- so two builds of
    # identical source could never even produce the same FILENAME, let alone be
    # compared by hash. Keyed on the app ref instead, exactly as the Pi/La Frite
    # naming does in opt/build.sh (seedsigner_os.<ref>.<config>.img).
    #
    # The tag also carries the OS variant and the secure-boot state, because a
    # bare app ref is ambiguous: "dev" names BOTH the default app branch and the
    # dev build variant, so two files differing only in hardening or signing
    # were pickable apart by name alone (a stale eabace45 dev image was flashed
    # as if it were a fresh non-dev one). The variant is spelled develop/
    # production -- NOT dev/nondev -- precisely to avoid re-colliding with an
    # app ref of "dev". The secure-boot token is safety-relevant: "burnable"
    # images write the OTP fuses on first boot -- irreversibly.
    #   <appref>-os<develop|production>-<unsigned|signed[-devkey|-realkey]|burnable[-devkey|-realkey]>
    # The key class mirrors provision_fit_build_keys: no SEEDSIGNER_FIT_KEY_DIR
    # means the committed PUBLIC dev placeholder (no protection); one supplied
    # means a real secret key.
    #
    # The four LAST_*_BUILD_TS exports that used to live here had no readers
    # anywhere in the repo and are gone.
    local tag variant_tag sb_state
    case "$SEEDSIGNER_BUILD_VARIANT" in
        dev)     variant_tag="develop" ;;
        non-dev) variant_tag="production" ;;
        *) print_error "unknown build variant '$SEEDSIGNER_BUILD_VARIANT' (expected dev or non-dev)"; exit 1 ;;
    esac
    case "${SEEDSIGNER_FIT_SIGNATURE:-0}" in
        1)
            if [ "${SEEDSIGNER_FIT_BURN_KEY_HASH:-0}" = "1" ]; then sb_state="burnable"; else sb_state="signed"; fi
            if [ -n "${SEEDSIGNER_FIT_KEY_DIR:-}" ]; then sb_state="${sb_state}-realkey"; else sb_state="${sb_state}-devkey"; fi
            ;;
        *) sb_state="unsigned" ;;
    esac
    tag="$(printf '%s' "$SEEDSIGNER_BRANCH" | tr -c 'A-Za-z0-9_.-' '_')-os${variant_tag}-${sb_state}"

    if [[ "$boot_medium" == "sd" ]]; then
        print_step "Creating Final SD Image (${board_profile})"

        local sd_image="seedsigner-luckfox-pico-${board_profile}-sd-${tag}.img"

        if [[ -f "/build/blkenvflash" ]]; then
            "/build/blkenvflash" "$sd_image"
        else
            print_error "blkenvflash tool not found"
            exit 1
        fi

        if [[ ! -f "$sd_image" ]]; then
            print_error "Expected SD image not created: $sd_image"
            exit 1
        fi

        cp -v "$sd_image" "$OUTPUT_DIR/"
        print_success "SD image created for ${board_profile}: $OUTPUT_DIR/$sd_image"
    elif [[ "$boot_medium" == "emmc" ]]; then
        print_step "Creating eMMC Bundle (${board_profile})"
        create_emmc_bundle "$board_profile" "$tag"
    fi

    if [[ "$include_nand" == "true" ]]; then
        print_step "Packaging NAND artifacts (${board_profile})"
        create_nand_image_artifacts "$board_profile" "$tag" "$boot_medium"
        export_official_nand_image_dir "$board_profile" "$tag"
    fi

    cd "$LUCKFOX_SDK_DIR"
}

run_automated_build() {
    local build_nand_image="${1:-false}"
    local build_sd_image="${2:-true}"

    print_step "Starting Automated SeedSigner Build"

    print_info "Build Configuration:"
    echo "   CPU Cores Available: $(nproc)"
    echo "   Memory Available: ${_ss_mem_gb:-?} GB"
    echo "   Build Jobs: $BUILD_JOBS"
    echo "   LLVM/Rust Jobs: $RUST_BUILD_JOBS"
    # Say so when memory, not cores, is what limits the job count. Building
    # host-rust compiles LLVM, whose heaviest translation units need ~2 GB each;
    # a silent -j<cores> on a memory-tight host dies at ~97% of the LLVM build
    # with an error that names no cause. Raise with --jobs N if you know better.
    # RUST_BUILD_JOBS (LLVM) is stricter still; override with RUST_BUILD_JOBS=N.
    if [[ "${_ss_mem_gb:-0}" -gt 0 && "$BUILD_JOBS" -lt "$(nproc)" ]]; then
        echo "   (capped by memory: ~2 GB/job for the LLVM build in host-rust;"
        echo "    override with --jobs N)"
    fi
    echo "   BR2_JLEVEL: $BR2_JLEVEL (MAKEFLAGS deliberately unset -- sysdrv is not parallel-safe)"
    echo "   Build Directory: $BUILD_DIR"
    echo "   Output Directory: $OUTPUT_DIR"

    clone_repositories
    apply_sdk_patches
    validate_environment
    setup_sdk_environment

    mkdir -p "$OUTPUT_DIR"

    cd "$LUCKFOX_SDK_DIR"

    # The five valid hardware/boot combinations, in the same order and with the
    # same membership as the CI matrix in build-luckfox.yml. Mini and Max boot
    # from SD or SPI-NAND; the Pico Pi is eMMC-only, because the SDK ships no
    # SD_CARD board config for it.
    #
    # Table-driven rather than an if-chain per board: the old chain had "both"
    # meaning mini+max only, silently excluding the Pi, and there was no way to
    # ask for everything at all.
    local combos=(mini:sd mini:nand max:sd max:nand pi:emmc)
    local built=0 skipped=0
    local combo profile medium is_nand

    for combo in "${combos[@]}"; do
        profile="${combo%%:*}"
        medium="${combo##*:}"

        # Model filter. "all" is every board; "both" is kept as the historical
        # spelling for mini+max so existing invocations behave unchanged.
        case "$BUILD_MODEL" in
            all)  ;;
            both) [[ "$profile" == "mini" || "$profile" == "max" ]] || { skipped=$((skipped+1)); continue; } ;;
            *)    [[ "$profile" == "$BUILD_MODEL" ]] || { skipped=$((skipped+1)); continue; } ;;
        esac

        # Media filter. eMMC is deliberately NOT gated on the sd/nand flags: it
        # is the Pi's only boot medium, so requiring --emmc to get the one image
        # that board can produce would be a trap.
        case "$medium" in
            sd)   [[ "$build_sd_image" == "true" ]]   || { skipped=$((skipped+1)); continue; } ;;
            nand) [[ "$build_nand_image" == "true" ]] || { skipped=$((skipped+1)); continue; } ;;
            emmc) ;;
        esac

        is_nand="false"
        [[ "$medium" == "nand" ]] && is_nand="true"

        print_step "Generating ${medium} output (${profile}, official flow)"
        build_profile_artifacts "$profile" "$medium" "$is_nand"
        built=$((built + 1))
    done

    if [[ "$built" -eq 0 ]]; then
        print_error "No hardware/boot combination matched BUILD_MODEL=$BUILD_MODEL"
        print_error "with sd=$build_sd_image nand=$build_nand_image — nothing was built."
        print_error "Valid: mini(sd,nand) max(sd,nand) pi(emmc); BUILD_MODEL=mini|max|pi|both|all"
        exit 1
    fi

    write_artifact_checksums

    print_success "Build Complete! ($built combination(s) built, $skipped skipped)"
    echo ""
    echo "Build artifacts:"
    ls -la "$OUTPUT_DIR/"
}

# Normalise artifact mtimes and record a checksum manifest.
#
# Luckfox published no hashes at all -- not in the build log, not as a file --
# so there was nothing for a third party to reproduce AGAINST, which makes a
# reproducible build unverifiable even once it is byte-identical. The Pi path
# has printed sha256sum since the beginning (opt/build.sh:331); this also writes
# a manifest, which CI collects across the matrix.
#
# The mtime normalisation matters because the .img files are consumed by `tar`
# and `zip` downstream (the release upload zips bundle directories), and both
# record mtimes.
write_artifact_checksums() {
    local manifest="$OUTPUT_DIR/sha256sums.txt"
    local f

    shopt -s nullglob
    local artifacts=("$OUTPUT_DIR"/*.img "$OUTPUT_DIR"/*.tar.gz)
    shopt -u nullglob

    if [[ ${#artifacts[@]} -eq 0 ]]; then
        print_info "No artifacts to checksum"
        return 0
    fi

    for f in "${artifacts[@]}"; do
        touch -d "@${SOURCE_DATE_EPOCH:-0}" "$f"
    done

    # Also the loose files inside the *-files-* bundle directories. They are not
    # in the manifest (the .tar.gz of the same content is), but the release
    # upload step zips these directories, and zip records mtimes -- so without
    # this the published .zip differs on every build even though the tarball of
    # exactly the same bytes does not.
    find "$OUTPUT_DIR" -mindepth 2 -exec touch -d "@${SOURCE_DATE_EPOCH:-0}" {} +

    # Basenames only, so the manifest does not leak the build directory, and
    # generated from inside $OUTPUT_DIR because a bash glob is already sorted --
    # under LC_ALL=C, deterministically so. The manifest is therefore itself
    # reproducible, which matters as much as the artifacts it lists.
    (
        cd "$OUTPUT_DIR" || exit 1
        shopt -s nullglob
        LC_ALL=C sha256sum -- *.img *.tar.gz > "$(basename "$manifest")"
    )

    print_step "Artifact checksums (sha256)"
    cat "$manifest"
}

start_interactive_mode() {
    print_step "Starting Interactive Mode"
    
    clone_repositories
    apply_sdk_patches
    validate_environment
    setup_sdk_environment
    
    print_success "Environment ready!"
    echo ""
    echo "Available commands:"
    echo "  - cd $LUCKFOX_SDK_DIR && ./build.sh [command]"
    echo "  - /build/docker-automation.sh auto  # Run full build"
    echo "  - exit  # Exit interactive mode"
    echo ""
    echo "Build artifacts will be available in: $OUTPUT_DIR"
    
    # Switch to SDK directory for convenience
    cd "$LUCKFOX_SDK_DIR"
    exec /bin/bash
}

# Fail immediately if any shared script is missing from the image.
#
# These live in opt/luckfox/ next to this file and are copied in by the
# Dockerfile. When they were NOT copied, the call sites guarded with
# `[[ -f ... ]]` silently skipped — a Docker build produced an image with the
# hardening, USB-mode config and translations simply absent, reported success,
# and looked identical to a good one until the device was in someone's hands.
#
# Checking up front turns that into a five-second failure instead: the guards
# exist to tolerate an optional script, not to tolerate a broken image.
assert_shared_build_files() {
    local missing=()
    local checked=0
    local s
    for s in prepare-sdk-checkout.sh rust-toolchain-cache.sh \
             patch-fs-determinism.sh mkfs-ext4-deterministic.sh ss-fs-normalise.sh \
             apply-partition-layout.sh \
              pin-spidev-bufsiz.sh readonly-rootfs.sh \
                assert-readonly-rootfs.sh strip-kernel-network.sh assert-kernel-network.sh \
                assert-uboot-fit-signature.sh lock-kernel-cmdline.sh \
                patch-mtd-part-parse.sh \
                patch-otp-size.sh assert-otp-size.sh \
               harden-nondev.sh optimize-nondev.sh configure-usb-mode.sh \
               strip-whitespace-filenames.sh \
             patch-s50usbdevice.sh patch-oem-pre-hook.sh prune-oem-iqfiles.sh \
               prepare-oem-for-rootfs.sh \
             install-gnupg-home.sh install-build-time.sh \
              uboot-recovery-config.sh compile-translations.sh \
              secure-boot/make-dev-keys.sh \
              secure-boot/dev-keys/dev.key \
              secure-boot/dev-keys/dev.pubkey \
              secure-boot/dev-keys/dev.crt \
              secure-boot/build-initramfs-binaries.sh \
              secure-boot/patch-mkfs-squashfs-signing.sh \
              secure-boot/patch-mkfs-ubi-signing.sh \
              SDK_COMMIT \
              mkfs-ubifs-determinism/build-mkfs-ubifs.sh \
              mkfs-ubifs-determinism/sort-dirents.patch \
              mkfs-ubifs-determinism/lzo/lzo1x.h \
              mkfs-ubifs-determinism/lzo/lzoconf.h \
              mkfs-ubifs-determinism/lzo/lzodefs.h \
              mkfs-ubifs-determinism/uuid.h; do
        checked=$((checked + 1))
        [[ -f "$SEEDSIGNER_LUCKFOX_DIR/$s" ]] || missing+=("$s")
    done

    if [[ ${#missing[@]} -ne 0 ]]; then
        print_error "Shared build files missing from $SEEDSIGNER_LUCKFOX_DIR:"
        for s in "${missing[@]}"; do echo "    - $s"; done
        print_error "The Docker image is stale or incomplete. Rebuild it:"
        print_error "  ./build.sh --luckfox build --force ..."
        exit 1
    fi
    print_info "All $checked shared build files present"
}

# Main entry point
main() {
    local mode="${1:-auto}"

    case "${1:-auto}" in
        auto|auto-nand|auto-nand-only) assert_shared_build_files ;;
    esac

    case "$mode" in
        "auto")
            print_info "Starting automated MicroSD build mode..."
            run_automated_build false true
            ;;
        "auto-nand")
            print_info "Starting automated build mode with MicroSD + NAND packaging..."
            run_automated_build true true
            ;;
        "auto-nand-only")
            print_info "Starting automated NAND-only build mode..."
            run_automated_build true false
            ;;
        "interactive")
            print_info "Starting interactive mode..."
            start_interactive_mode
            ;;
        "shell")
            print_info "Starting direct shell..."
            exec /bin/bash
            ;;
        "clone-only")
            print_info "Cloning repositories only..."
            clone_repositories
            apply_sdk_patches
            print_success "Repositories cloned and patches applied. Container exiting."
            ;;
        "help"|"-h"|"--help")
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown mode: $mode"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
