#!/bin/bash
# SeedSigner Local Build Script (No Docker)
# Automates the complete build process for Ubuntu 22.04
# Mirrors the GitHub Actions workflow

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(dirname "$SCRIPT_DIR")"
# Build variant: non-dev (hardened/air-gapped) or dev. Override via SEEDSIGNER_BUILD_VARIANT env.
BUILD_VARIANT="${SEEDSIGNER_BUILD_VARIANT:-non-dev}"
# USB role (mirrors build-luckfox.yml's usb_mode): gadget|host|otg|auto.
# auto follows the variant: non-dev = host (no adb/RNDIS), dev = gadget (adb).
USB_MODE="${SEEDSIGNER_USB_MODE:-auto}"
# Ethernet debug channel (mirrors build-luckfox.yml's debug_network): on|off|auto.
# auto follows the variant: non-dev = off (no interface bring-up, no telnet), dev = on.
DEBUG_NETWORK="${SEEDSIGNER_DEBUG_NETWORK:-auto}"
# Read-only squashfs rootfs (mirrors build-luckfox.yml's readonly_rootfs): auto|on|off.
READONLY_ROOTFS="${READONLY_ROOTFS:-${SEEDSIGNER_READONLY_ROOTFS:-auto}}"
# Persistent boot log (mirrors build-luckfox.yml's boot_log): on|off. on bakes
# /etc/seedsigner-boot-log so start-seedsigner.sh records every boot to /userdata.
# Default off: a production device must write nothing to flash.
SEEDSIGNER_BOOT_LOG="${SEEDSIGNER_BOOT_LOG:-off}"
# The SeedSigner application repo/branch (mirrors build-luckfox.yml's
# seedsigner_repo_url / seedsigner_branch). The app is the one component this
# repo does not pin, so it has to be selectable or a local build cannot
# reproduce a CI image.
SEEDSIGNER_REPO_URL="${SEEDSIGNER_REPO_URL:-https://github.com/3rdIteration/seedsigner.git}"
SEEDSIGNER_REF="${SEEDSIGNER_REF:-${SEEDSIGNER_BRANCH:-dev}}"

# Secure boot (opt-in, OFF by default): SEEDSIGNER_FIT_SIGNATURE=1 enables FIT
# signature enforcement in U-Boot, signs the rootfs volume at build time and
# embeds a verifying initramfs into boot.img. Every step is a no-op unless it
# is set, so unsigned builds are byte-for-byte unchanged (commit 33c8681).
SEEDSIGNER_FIT_SIGNATURE="${SEEDSIGNER_FIT_SIGNATURE:-0}"
export SEEDSIGNER_FIT_SIGNATURE
# IRREVERSIBLE: when 1, the built loader burns the FIT pubkey hash to OTP on
# first boot and turns secure boot on permanently. Never set in CI or a normal
# build; see arm_fit_burn_key_hash below.
SEEDSIGNER_FIT_BURN_KEY_HASH="${SEEDSIGNER_FIT_BURN_KEY_HASH:-0}"
export SEEDSIGNER_FIT_BURN_KEY_HASH
# Dir holding a real dev.{key,pubkey,crt} FIT signing triple; default: the
# committed PUBLIC dev key in secure-boot/dev-keys/ (placeholder, no protection).
SEEDSIGNER_FIT_KEY_DIR="${SEEDSIGNER_FIT_KEY_DIR:-}"
export SEEDSIGNER_FIT_KEY_DIR
# Rootfs verification (only with SEEDSIGNER_FIT_SIGNATURE=1): dir holding a
# minisign dev.key/dev.pubkey pair used to sign the rootfs volume's logical
# UBIFS contents at build time. Default: the committed PUBLIC dev keypair in
# secure-boot/dev-keys-rootfs/ (see its README — grants no protection, keeps
# signed builds reproducible and the failure mode recoverable).
SEEDSIGNER_ROOTFS_KEY_DIR="${SEEDSIGNER_ROOTFS_KEY_DIR:-}"
export SEEDSIGNER_ROOTFS_KEY_DIR
# Passphrase for that secret key. The committed dev key uses the documented
# public passphrase "seedsigner-dev"; a real key via SEEDSIGNER_ROOTFS_KEY_DIR
# must set this explicitly (no default — an empty prompt would hang the build).
SEEDSIGNER_ROOTFS_KEY_PASSPHRASE="${SEEDSIGNER_ROOTFS_KEY_PASSPHRASE:-}"
export SEEDSIGNER_ROOTFS_KEY_PASSPHRASE
# Rebuild the four vendored initramfs binaries from source at build time and
# overwrite the committed copies before their SHA-256 pins are checked. Off by
# default: the committed binaries ARE the reviewed, pinned artifacts (see
# secure-boot/initramfs-binaries/README.md). When on, a rebuild that does not
# reproduce the pinned bytes exactly fails the build loudly — the pins act as
# a live determinism canary, so they must never be auto-updated. Requires
# network access for the checksum-pinned source downloads.
SEEDSIGNER_REBUILD_INITRAMFS_BINARIES="${SEEDSIGNER_REBUILD_INITRAMFS_BINARIES:-0}"
export SEEDSIGNER_REBUILD_INITRAMFS_BINARIES
# Mini CMA size baked into the signed bootargs (matches apply_mini_cma_config's
# 1M pin); overridable for testing.
MINI_CMA_SIZE="${MINI_CMA_SIZE:-1M}"
export MINI_CMA_SIZE

# Default Python version for buildroot (used if detection fails)
DEFAULT_PYTHON_VERSION="3.12"
DISABLE_UART2_CONSOLE_DEBUG="${DISABLE_UART2_CONSOLE_DEBUG:-1}"
BUILD_RUST_FROM_SOURCE="${BUILD_RUST_FROM_SOURCE:-0}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_header() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }
print_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }
print_info() { echo -e "${YELLOW}[INFO] $1${NC}"; }
# Alias for os-build.sh's print_step (ported secure-boot functions call it).
print_step() { print_info "$*"; }

# Artifact name tag: <appref>-os<develop|production>-<unsigned|signed[-devkey|-realkey]|burnable[-devkey|-realkey]>.
# MUST match os-build.sh's artifact naming byte-for-byte, so a legacy local build and a
# Docker/CI build of the same inputs produce comparable filenames. The variant is spelled
# develop/production (NOT dev/nondev) to avoid colliding with an app ref of "dev"; the
# secure-boot token is safety-relevant: "burnable" images write the OTP fuses on first
# boot -- irreversibly. Computed at call time so CLI-parsed SEEDSIGNER_REF / BUILD_VARIANT
# (set later in main) are honoured.
artifact_tag() {
    local variant_tag sb_state
    case "$BUILD_VARIANT" in
        dev)     variant_tag="develop" ;;
        non-dev) variant_tag="production" ;;
        *) print_error "unknown build variant '$BUILD_VARIANT' (expected dev or non-dev)"; exit 1 ;;
    esac
    case "${SEEDSIGNER_FIT_SIGNATURE:-0}" in
        1)
            if [ "${SEEDSIGNER_FIT_BURN_KEY_HASH:-0}" = "1" ]; then sb_state="burnable"; else sb_state="signed"; fi
            if [ -n "${SEEDSIGNER_FIT_KEY_DIR:-}" ]; then sb_state="${sb_state}-realkey"; else sb_state="${sb_state}-devkey"; fi
            ;;
        *) sb_state="unsigned" ;;
    esac
    printf '%s' "$(printf '%s' "$SEEDSIGNER_REF" | tr -c 'A-Za-z0-9_.-' '_')-os${variant_tag}-${sb_state}"
}

debug_uart_bootargs_file() {
    local file_path="$1"
    local label="$2"
    print_info "UART bootargs debug (${label}): $file_path"
    if [ -f "$file_path" ]; then
        grep -nE 'ttyFIQ0|console=|earlycon=|user_debug=|CMDLINE|BOOTARGS' "$file_path" || echo "  (no matching bootarg tokens)"
    else
        echo "  (file not found)"
    fi
}

debug_uart_bootargs_outputs() {
    local image_dir="$WORK_DIR/luckfox-pico/output/image"
    print_info "UART bootargs debug (output image files): $image_dir"
    if [ ! -d "$image_dir" ]; then
        echo "  (output image directory not found)"
        return 0
    fi

    local found=false
    local f
    for f in "$image_dir"/*.txt "$image_dir"/*.cfg "$image_dir"/*.ini "$image_dir"/parameter*; do
        if [ ! -e "$f" ]; then
            continue
        fi
        found=true
        echo "  checking: $(basename "$f")"
        grep -nE 'ttyFIQ0|console=|earlycon=|user_debug=|CMDLINE|BOOTARGS' "$f" || echo "    (no matching bootarg tokens)"
    done

    if [ "$found" != "true" ]; then
        echo "  (no text-like image metadata files found)"
    fi
}

resolve_dts_path_for_hardware() {
    local hardware="$1"
    local dts_dir="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts"
    local dts_file=""

    case "$hardware" in
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
            print_error "Unknown hardware type for DTS patch: $hardware"
            exit 1
            ;;
    esac

    if [ ! -f "$dts_file" ]; then
        print_error "DTS file not found for UART2 console patch: $dts_file"
        exit 1
    fi

    echo "$dts_file"
}

resolve_dtsi_path_for_hardware() {
    local hardware="$1"
    local dts_dir="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts"
    local dtsi_file=""

    case "$hardware" in
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
            print_error "Unknown hardware type for DTSI patch: $hardware"
            exit 1
            ;;
    esac

    if [ ! -f "$dtsi_file" ]; then
        print_error "DTSI file not found for UART2 console patch: $dtsi_file"
        exit 1
    fi

    echo "$dtsi_file"
}

show_usage() {
    cat << 'USAGE'
SeedSigner Local Build System (No Docker)
Tested on Ubuntu 22.04

Usage: ./build-local.sh [options]

Options:
  --hardware TYPE    - Hardware type: mini|max|pi (default: mini)
  --boot MEDIUM      - Boot medium: sd|nand|emmc (default: sd)
  --variant V        - non-dev (hardened) | dev (default: non-dev)
  --readonly-rootfs V - auto|on|off; read-only squashfs root (default: auto)
  --seedsigner-ref R - SeedSigner app branch, release tag or commit (default: dev)
  --seedsigner-repo URL - SeedSigner app repo
  --enable-uart2-console - Keep UART2 console/debug enabled (default: disabled)
  --build-rust-from-source - Build Rust toolchain from source (ignore cached binary)
  --check-deps       - Check and install missing dependencies
  --clone-only       - Only clone repositories and exit
  --clean            - Clean previous build artifacts
  --help, -h         - Show this help

Examples:
  ./build-local.sh                              # Build Mini with SD card
  ./build-local.sh --hardware max --boot sd     # Build Max with SD card
  ./build-local.sh --hardware mini --boot nand  # Build Mini with NAND
  ./build-local.sh --hardware pi --boot emmc    # Build Pico Pi with eMMC
  ./build-local.sh --check-deps                 # Install dependencies
  ./build-local.sh --clone-only                 # Only clone repos

Build Process:
  1. Check/install dependencies (Ubuntu 22.04 required)
  2. Clone required repositories
  3. Set up toolchain environment
  4. Configure board (hardware + boot medium)
  5. Build U-Boot, kernel, rootfs, media, apps
  6. Install SeedSigner application
  7. Package firmware and create flashable images

Output:
  - SD images: luckfox-pico/output/image/*.img
  - NAND bundles: luckfox-pico/output/image/*.tar.gz
  - eMMC bundles: luckfox-pico/output/image/*.tar.gz

Repository Locations:
  - luckfox-pico: $WORK_DIR/luckfox-pico
  - seedsigner: $WORK_DIR/seedsigner
  - seedsigner-os packages: $SCRIPT_DIR/../external-packages (in-repo, no clone)

Performance:
  First build: 60-120 minutes
  Subsequent builds: 30-60 minutes
USAGE
}

check_ubuntu_version() {
    print_header "Checking Ubuntu Version"
    
    if [ ! -f /etc/os-release ]; then
        print_error "Cannot detect OS version"
        exit 1
    fi
    
    . /etc/os-release
    
    if [ "$ID" != "ubuntu" ]; then
        print_warning "This script is tested on Ubuntu 22.04"
        print_warning "Detected OS: $ID $VERSION_ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    elif [ "$VERSION_ID" != "22.04" ]; then
        print_warning "This script is tested on Ubuntu 22.04"
        print_warning "Detected version: $VERSION_ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "Ubuntu 22.04 detected"
    fi
}

check_and_install_dependencies() {
    print_header "Checking Dependencies"
    
    local packages=(
        git ssh make gcc gcc-multilib g++-multilib
        module-assistant expect g++ gawk texinfo
        libssl-dev bison flex fakeroot cmake unzip
        gperf autoconf device-tree-compiler
        libncurses5-dev pkg-config bc python-is-python3
        passwd openssl openssh-server openssh-client
        vim file cpio rsync
    )
    
    local missing_packages=()
    
    for pkg in "${packages[@]}"; do
        # Use dpkg-query for reliable package detection
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [ ${#missing_packages[@]} -eq 0 ]; then
        print_success "All dependencies installed"
        return 0
    fi
    
    print_warning "Missing packages: ${missing_packages[*]}"
    
    if [ "$1" == "auto" ]; then
        print_info "Installing missing packages..."
        sudo apt-get update
        sudo apt-get install -y "${missing_packages[@]}"
        print_success "Dependencies installed"
    else
        echo "Run with --check-deps to install missing packages"
        exit 1
    fi
}

clone_repositories() {
    print_header "Cloning Required Repositories"
    
    cd "$WORK_DIR"
    
    # Clone luckfox-pico SDK
    if [ ! -d "luckfox-pico" ]; then
        print_info "Cloning luckfox-pico SDK..."
        git clone https://github.com/3rdIteration/luckfox-pico.git --depth=1 --single-branch
        print_success "luckfox-pico cloned"
    else
        print_info "luckfox-pico already exists"
    fi
    
    # SeedSigner OS Buildroot packages are part of this repo (opt/external-packages);
    # nothing to clone.

    # Put the app checkout on exactly $SEEDSIGNER_REF. The repo/ref are
    # variables, not literals: this used to hard-code `-b dev`, so a local
    # build could not produce the image CI produces whenever CI was pointed at
    # another branch -- and the app is the one component this repo does not
    # pin. An existing checkout is put ON the requested ref rather than reused
    # as-is (it outlives the build here too, so reuse used to swallow
    # --seedsigner-ref entirely). Shared with CI and os-build.sh.
    bash "$SCRIPT_DIR/prepare-app-checkout.sh" "$WORK_DIR" "$SEEDSIGNER_REF" "$SEEDSIGNER_REPO_URL"

    # The app MUST carry the boot-watchdog liveness signal (it writes
    # /tmp/seedsigner-ready): a signal-less ref builds green, but the image
    # boots the app fine and then reboots into Loader 120 s later, on every
    # boot. Runs after the clone-or-reuse decision so a stale reused checkout
    # is caught too. Shared with CI via assert-app-watchdog-signal.sh.
    bash "$SCRIPT_DIR/assert-app-watchdog-signal.sh" "$WORK_DIR/seedsigner"

    # Compile translation catalogs (.po -> .mo) + slim fonts in the checkout so
    # the image ships multi-language support. Must run before the checkout is
    # copied into the rootfs / l10n/ is pruned. Degrades to English-only if the
    # host python toolchain is unavailable.
    if [[ -f "$SCRIPT_DIR/compile-translations.sh" ]]; then
        bash "$SCRIPT_DIR/compile-translations.sh" "$WORK_DIR/seedsigner" \
          || print_info "Translation compile skipped (image will be English-only)"
    fi

    print_success "All repositories available"
}

apply_sdk_patches() {
    print_header "Applying SeedSigner SDK Patches"

    # Partition layout is shared with CI via apply-partition-layout.sh. It used to
    # be duplicated here, and the copy had drifted badly: this function DELETED the
    # userdata partition (20M(oem),99M(rootfs) plus a sed stripping the
    # userdata@/userdata@ubifs mount) while CI kept it. Locally built images
    # therefore had nowhere to persist settings or write a boot log -- and since
    # the rootfs became read-only squashfs, nowhere writable at all.
    bash "$SCRIPT_DIR/apply-partition-layout.sh" "$WORK_DIR/luckfox-pico"

    # Rootfs minisign hooks for signed builds: sign the rootfs during `build.sh
    # firmware` (same pctools-copy constraint as above). No-op unless
    # SEEDSIGNER_FIT_SIGNATURE=1. The UBI hook covers NAND (squashfs/ubifs packed
    # into a UBI volume by mkfs_ubi.sh's embedded call); the squashfs hook covers
    # MicroSD/eMMC, where build_mkimg writes a raw-partition squashfs through
    # mkfs_squashfs.sh and no UBI is involved. Both write per-image outputs, so a
    # multi-profile run never clobbers another medium's signature.
    if [[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ]]; then
        bash "$SCRIPT_DIR/secure-boot/patch-mkfs-ubi-signing.sh" "$WORK_DIR/luckfox-pico"
        bash "$SCRIPT_DIR/secure-boot/patch-mkfs-squashfs-signing.sh" "$WORK_DIR/luckfox-pico"
    fi

    cd "$WORK_DIR"
}

setup_toolchain() {
    print_header "Setting Up Toolchain Environment"
    
    cd "$WORK_DIR/luckfox-pico"
    
    local toolchain_dir="tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf"
    
    if [ ! -f "$toolchain_dir/env_install_toolchain.sh" ]; then
        print_error "Toolchain environment script not found"
        exit 1
    fi
    
    print_info "Sourcing toolchain environment..."
    cd "$toolchain_dir"
    source env_install_toolchain.sh
    cd "$WORK_DIR/luckfox-pico"
    
    # Verify toolchain
    if ! which arm-rockchip830-linux-uclibcgnueabihf-gcc > /dev/null 2>&1; then
        print_error "Toolchain not found in PATH"
        exit 1
    fi
    
    print_success "Toolchain configured"
}

configure_board() {
    local hardware="$1"
    local boot_medium="$2"
    
    print_header "Configuring Board: $hardware with $boot_medium"
    
    cd "$WORK_DIR/luckfox-pico"
    
    local hw_index
    case "$hardware" in
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
            print_error "Unknown hardware type: $hardware"
            exit 1
            ;;
    esac
    
    local boot_index
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
            print_error "Unknown boot medium: $boot_medium"
            exit 1
            ;;
    esac
    
    print_info "Running SDK board configuration..."
    printf "%s\n%s\n%s\n" "$hw_index" "$boot_index" "0" | ./build.sh lunch
    
    if [ ! -f ".BoardConfig.mk" ]; then
        print_error "Board config file not created"
        exit 1
    fi
    
    print_success "Board configured"
}

apply_mini_cma_config() {
    local hardware="$1"
    local boot_medium="$2"
    
    if [ "$hardware" != "mini" ]; then
        return 0
    fi
    
    print_header "Applying CMA Memory Configuration for Mini"
    
    cd "$WORK_DIR/luckfox-pico"
    
    # Map hardware and boot medium to SDK naming convention (matching GitHub Actions)
    local sdk_hardware
    case "$hardware" in
        mini)
            sdk_hardware="RV1103_Luckfox_Pico_Mini"
            ;;
        max)
            sdk_hardware="RV1106_Luckfox_Pico_Pro_Max"
            ;;
        pi)
            sdk_hardware="RV1106_Luckfox_Pico_Pi"
            ;;
        *)
            print_error "Unknown hardware type: $hardware"
            exit 1
            ;;
    esac
    
    local sdk_boot_medium
    case "$boot_medium" in
        sd)
            sdk_boot_medium="SD_CARD"
            ;;
        nand)
            sdk_boot_medium="SPI_NAND"
            ;;
        emmc)
            sdk_boot_medium="EMMC"
            ;;
        *)
            print_error "Unknown boot medium: $boot_medium"
            exit 1
            ;;
    esac
    
    # Construct board config path matching GitHub Actions workflow
    local board_config="project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    
    if [ ! -f "$board_config" ]; then
        print_error "Board config file not found: $board_config"
        exit 1
    fi
    
    print_info "Using board config: $board_config"
    
    local cma_size="${MINI_CMA_SIZE}"

    if grep -q '^export RK_BOOTARGS_CMA_SIZE=' "$board_config"; then
        sed -i "s|^export RK_BOOTARGS_CMA_SIZE=.*|export RK_BOOTARGS_CMA_SIZE=\"${cma_size}\"|" "$board_config"
        print_info "Updated existing CMA size in: $board_config"
    else
        echo "export RK_BOOTARGS_CMA_SIZE=\"${cma_size}\"" >> "$board_config"
        print_info "Added CMA size to: $board_config"
    fi
    
    # Verify the change
    print_info "Current CMA configuration:"
    grep 'RK_BOOTARGS_CMA_SIZE' "$board_config" || print_warning "No CMA configuration found (will use default)"
    
    print_success "CMA size set to $cma_size"
}

apply_uart2_console_config() {
    local hardware="$1"
    local boot_medium="$2"

    if [ "$DISABLE_UART2_CONSOLE_DEBUG" != "1" ]; then
        print_info "UART2 console debug left enabled (DISABLE_UART2_CONSOLE_DEBUG=${DISABLE_UART2_CONSOLE_DEBUG})"
        return 0
    fi

    print_header "Disabling UART2 Console Debug"

    cd "$WORK_DIR/luckfox-pico"

    local sdk_hardware
    case "$hardware" in
        mini)
            sdk_hardware="RV1103_Luckfox_Pico_Mini"
            ;;
        max)
            sdk_hardware="RV1106_Luckfox_Pico_Pro_Max"
            ;;
        *)
            print_error "Unknown hardware type: $hardware"
            exit 1
            ;;
    esac

    local sdk_boot_medium
    case "$boot_medium" in
        sd)
            sdk_boot_medium="SD_CARD"
            ;;
        nand)
            sdk_boot_medium="SPI_NAND"
            ;;
        emmc)
            sdk_boot_medium="EMMC"
            ;;
        *)
            print_error "Unknown boot medium: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"

    if [ ! -f "$board_config" ] && [ -L ".BoardConfig.mk" ]; then
        board_config="$(readlink -f .BoardConfig.mk)"
    fi

    if [ ! -f "$board_config" ]; then
        print_error "Board config file not found for UART2 console config: $board_config"
        exit 1
    fi

    print_info "Updating board config: $board_config"
    debug_uart_bootargs_file "$board_config" "before patch"
    sed -i 's/\<console=ttyFIQ0[^ "]*\>//g; s/\<earlycon=uart8250,[^ "]*\>//g; s/\<user_debug=[^ "]*\>//g' "$board_config"
    debug_uart_bootargs_file "$board_config" "after patch"

    if grep -Eq '(^|[[:space:]])console=ttyFIQ0([^[:space:]]*)?([[:space:]]|$)' "$board_config"; then
        print_error "UART2 console debug removal verification failed: console=ttyFIQ0 still present in $board_config"
        exit 1
    fi

    print_success "UART2 console debug disabled in $board_config"
}

apply_uart2_console_dts_patch() {
    local hardware="$1"

    if [ "$DISABLE_UART2_CONSOLE_DEBUG" != "1" ]; then
        return 0
    fi

    print_header "Disabling UART2 Console Debug in DTS"

    local dts_file dtsi_file target
    dts_file="$(resolve_dts_path_for_hardware "$hardware")"
    dtsi_file="$(resolve_dtsi_path_for_hardware "$hardware")"
    for target in "$dts_file" "$dtsi_file"; do
        debug_uart_bootargs_file "$target" "dts source before patch"
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
        debug_uart_bootargs_file "$target" "dts source after patch"

        if grep -Eq '(^|[[:space:]])console=ttyFIQ0([^[:space:]]*)?([[:space:]]|$)' "$target"; then
            print_error "UART2 console debug removal verification failed in DTS source: $target"
            exit 1
        fi
    done

    print_success "UART2 console debug disabled in DTS sources: $dts_file, $dtsi_file"
}

apply_uart2_fiq_kernel_patch() {
    local hardware="$1"
    local boot_medium="$2"

    if [ "$DISABLE_UART2_CONSOLE_DEBUG" != "1" ]; then
        return 0
    fi

    print_header "Disabling FIQ Debugger in Kernel Defconfig"

    local sdk_hardware sdk_boot_medium
    case "$hardware" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)
            print_error "Unknown hardware type for kernel FIQ patch: $hardware"
            exit 1
            ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *)
            print_error "Unknown boot medium for kernel FIQ patch: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [ ! -f "$board_config" ] && [ -L ".BoardConfig.mk" ]; then
        board_config="$(readlink -f .BoardConfig.mk)"
    fi
    if [ ! -f "$board_config" ]; then
        print_error "Board config file not found for kernel FIQ patch: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [ -n "$kernel_defconfig" ] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="sysdrv/source/kernel/arch/arm/configs/${kernel_defconfig}"
    if [ ! -f "$kernel_cfg_file" ]; then
        print_error "Kernel defconfig not found for FIQ patch: $kernel_cfg_file"
        exit 1
    fi

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

apply_hwrng_kernel_patch() {
    local hardware="$1"
    local boot_medium="$2"

    print_header "Enabling HWRNG and Hardware Crypto in Kernel Defconfig"

    local sdk_hardware sdk_boot_medium
    case "$hardware" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)
            print_error "Unknown hardware type for HWRNG kernel patch: $hardware"
            exit 1
            ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *)
            print_error "Unknown boot medium for HWRNG kernel patch: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [ ! -f "$board_config" ] && [ -L ".BoardConfig.mk" ]; then
        board_config="$(readlink -f .BoardConfig.mk)"
    fi
    if [ ! -f "$board_config" ]; then
        print_error "Board config file not found for HWRNG kernel patch: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [ -n "$kernel_defconfig" ] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="sysdrv/source/kernel/arch/arm/configs/${kernel_defconfig}"
    if [ ! -f "$kernel_cfg_file" ]; then
        print_error "Kernel defconfig not found for HWRNG patch: $kernel_cfg_file"
        exit 1
    fi

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
# rootfs (root=/dev/mmcblk1p7), so it is configured as storage already and the
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
    local hardware="$1"

    print_header "Enabling RNG DTS Node"

    local dts_file
    dts_file="$(resolve_dts_path_for_hardware "$hardware")"

    if ! enable_dts_node rng "$dts_file"; then
        print_error "rng DTS node enable verification failed in: $dts_file"
        exit 1
    fi
    print_success "rng DTS node enabled in: $dts_file"
}

apply_kernel_network_strip() {
    local hardware="$1"
    local boot_medium="$2"

    if [ "$BUILD_VARIANT" != "non-dev" ]; then
        print_info "dev build: kernel networking/WiFi retained"
        return 0
    fi

    local sdk_hardware sdk_boot_medium
    case "$hardware" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *) print_error "Unknown hardware type for kernel network strip: $hardware"; exit 1 ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *) print_error "Unknown boot medium for kernel network strip: $boot_medium"; exit 1 ;;
    esac

    local board_config="$WORK_DIR/luckfox-pico/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [ ! -f "$board_config" ] && [ -L "$WORK_DIR/luckfox-pico/.BoardConfig.mk" ]; then
        board_config="$(readlink -f "$WORK_DIR/luckfox-pico/.BoardConfig.mk")"
    fi
    if [ ! -f "$board_config" ]; then
        print_error "Board config file not found for kernel network strip: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [ -n "$kernel_defconfig" ] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [ ! -f "$kernel_cfg_file" ]; then
        print_error "Kernel defconfig not found for network strip: $kernel_cfg_file"
        exit 1
    fi

    # Networking gated on debug_network (off -> strip); WiFi always stripped on
    # non-dev. Shared with CI via strip-kernel-network.sh.
    SS_STRIP_NET=1
    if [ "$DEBUG_NETWORK" == "on" ]; then SS_STRIP_NET=0; fi
    export SS_STRIP_NET

    print_header "Stripping Kernel Networking/WiFi (non-dev, net_strip=$SS_STRIP_NET)"
    # The board config is passed too: the SDK builds OUT-OF-TREE wifi drivers when
    # RK_ENABLE_WIFI=y, and they fail modpost once the in-kernel cfg80211 is gone.
    bash "$SCRIPT_DIR/strip-kernel-network.sh" \
        "$kernel_cfg_file" "$SS_STRIP_NET" 1 "$board_config" 1

}

# Read-only rootfs (squashfs + tmpfs overlays). Shared with CI via
# readonly-rootfs.sh.
#
# Deliberately NOT gated on non-dev, unlike apply_kernel_network_strip: a dev
# image with a read-only root is the only configuration where the property can
# actually be TESTED, because a hardened image has no shell to check `mount` or
# prove that a write to /etc is discarded. Gating this would silently ignore
# READONLY_ROOTFS=on for exactly the build used to verify it.
apply_readonly_rootfs() {
    local hardware="$1"
    local boot_medium="$2"

    local sdk_hardware sdk_boot_medium
    case "$hardware" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *) print_error "Unknown hardware type for read-only rootfs: $hardware"; exit 1 ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *) print_error "Unknown boot medium for read-only rootfs: $boot_medium"; exit 1 ;;
    esac

    local board_config="$WORK_DIR/luckfox-pico/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [ ! -f "$board_config" ] && [ -L "$WORK_DIR/luckfox-pico/.BoardConfig.mk" ]; then
        board_config="$(readlink -f "$WORK_DIR/luckfox-pico/.BoardConfig.mk")"
    fi
    if [ ! -f "$board_config" ]; then
        print_error "Board config file not found for read-only rootfs: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [ -n "$kernel_defconfig" ] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [ ! -f "$kernel_cfg_file" ]; then
        print_error "Kernel defconfig not found for read-only rootfs: $kernel_cfg_file"
        exit 1
    fi

    case "${READONLY_ROOTFS:-auto}" in
        on)  SS_RO_ROOTFS=1 ;;
        off) SS_RO_ROOTFS=0 ;;
        # auto: hardened images get an immutable root; dev images keep a writable
        # one so the rootfs can be poked at over the serial console.
        *)   if [ "$BUILD_VARIANT" = "non-dev" ]; then SS_RO_ROOTFS=1; else SS_RO_ROOTFS=0; fi ;;
    esac
    # A signed SD/eMMC build MUST have an immutable root: the initramfs verifier
    # streams the raw partition bytes and only knows how to mount squashfs there
    # (a writable ext4 root would stop verifying after the first runtime write,
    # and /init has no case for it at all). Force it on rather than failing late
    # in apply_signed_nand_bootargs — dev signed builds then match non-dev's
    # stack exactly (the debug access lives in userspace: adb/telnet/serial).
    # NAND is exempt: the verifier handles both squashfs and writable UBIFS.
    if [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] && { [ "$boot_medium" = "sd" ] || [ "$boot_medium" = "emmc" ]; } \
       && [ "$SS_RO_ROOTFS" != 1 ]; then
        print_info "SEEDSIGNER_FIT_SIGNATURE=1 on $boot_medium: forcing read-only squashfs root (the initramfs verifier only supports immutable roots there)"
        SS_RO_ROOTFS=1
    fi
    export SS_RO_ROOTFS
    # Recorded for the post-build assertions, which need the same board config.
    export SS_BOARD_CONFIG="$board_config"

    print_header "Configuring Read-Only Rootfs (enabled=$SS_RO_ROOTFS)"
    bash "$SCRIPT_DIR/readonly-rootfs.sh" \
        "$board_config" "$kernel_cfg_file" "$SS_RO_ROOTFS"
}

# Pin spidev.bufsiz on the kernel command line. Shared with CI via
# pin-spidev-bufsiz.sh — without it the 64 MB Mini fails an order-6 allocation in
# spidev_open() and the display never opens, while the pre-app splash on the same
# boot draws fine. Applies to every board and every variant.
apply_spidev_bufsiz() {
    local hardware="$1"

    local sdk_hardware
    case "$hardware" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *) print_error "Unknown hardware type for spidev bufsiz: $hardware"; exit 1 ;;
    esac

    print_header "Pinning spidev.bufsiz (display SPI open)"
    bash "$SCRIPT_DIR/pin-spidev-bufsiz.sh" "$WORK_DIR/luckfox-pico" "$sdk_hardware" 8192
}

# Extend the RV1106 OTP nvmem region so /init can read the secure-boot enable
# fuse (offset 0x80) and show "SECURE BOOT not enabled" on unfused boards.
# Shared with CI via patch-otp-size.sh; applies to every board — all three use
# rv1106_data in rockchip-otp.c (the Mini's RV1103 includes rv1106.dtsi).
# No-op unless SEEDSIGNER_FIT_SIGNATURE=1: unsigned builds keep the kernel
# byte-identical to before this feature.
apply_otp_size_patch() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    print_header "Extending OTP nvmem region for secure-boot fuse read"
    bash "$SCRIPT_DIR/patch-otp-size.sh" "$WORK_DIR/luckfox-pico"
}

# Opt-in secure-boot support (SEEDSIGNER_FIT_SIGNATURE=1), OFF by default so a
# normal build is byte-for-byte unchanged. Two halves:
#   apply_fit_signature_config  - turn ON FIT signature ENFORCEMENT in the U-Boot
#       defconfig BEFORE the U-Boot build, so SPL/U-Boot require a valid signature.
#   export_fit_sign_tree        - AFTER the build, copy everything fit-sign.sh
#       needs (the packed images from output/image + a fit_signcfg/ holding the
#       built u-boot .config as sign.readonly_config) into the image output dir.
#       Signing then happens on the host with secure-boot/sign-secure-boot.sh
#       --build-tree <that dir>. The build itself never signs and never burns.
# See docs/luckfox/secure-boot-bench-procedure.md.
apply_fit_signature_config() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local ubootdir="$WORK_DIR/luckfox-pico/sysdrv/source/uboot/u-boot"
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
    local devkeys="$SCRIPT_DIR/secure-boot/dev-keys"
    for k in dev.key dev.pubkey dev.crt; do
        [ -f "$devkeys/$k" ] || { print_error "committed public dev key missing: $devkeys/$k (stale checkout?)"; exit 1; }
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
# SD/eMMC default (root=/dev/mmcblk1p7 on mini+max, root=/dev/mmcblk0p7 on pi —
# eMMC is the FIRST block device); on a signed NAND build the SDK's usual
# runtime injection of root=ubi0:rootfs / ubi.mtd / rootfstype / rk_dma_heap_cma
# is dropped, so the board hangs at "Waiting for root device" and comes up with
# the DT-default CMA. Bake the rootfs cmdline (the exact args the SDK computes in
# parse_partition_file/__GET_BOOTARGS_FROM_BOARD_CFG) into /chosen before the
# kernel build. Gated on signed builds, so unsigned ones are untouched (u-boot
# still overrides their /chosen at runtime). This also fixes the
# attacker-controlled-cmdline gap for signed builds: root is now pinned inside
# the signed image, not read from the unsigned env partition. A mismatch is not
# a fallback: it is "Waiting for root device" with no recovery short of a
# reflash.
apply_signed_nand_bootargs() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local profile="$1" medium="$2"
    case "$medium" in
        nand|sd|emmc) ;;
        *) print_info "apply_signed_nand_bootargs: no bootargs baking needed for '$medium'"; return 0 ;;
    esac
    # Per-board DTSI (the one carrying /chosen/bootargs) and the rootfs block
    # device. All three boards share the same 7-partition layout
    # (env,idblock,uboot,boot,oem,userdata,rootfs — apply-partition-layout.sh),
    # so on NAND rootfs is mtd6 everywhere; SD/SDMMC is mmcblk1, eMMC is mmcblk0.
    local dtsi root_dev
    case "$profile" in
        mini) dtsi="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1103-luckfox-pico-ipc.dtsi";      root_dev="mmcblk1p7" ;;
        max)  dtsi="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1106-luckfox-pico-pro-max-ipc.dtsi"; root_dev="mmcblk1p7" ;;
        pi)   dtsi="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1106-luckfox-pico-pi-ipc.dtsi";     root_dev="mmcblk0p7" ;;
        *) print_error "signed bootargs: unsupported board profile '$profile' (expected mini, max or pi)"; exit 1 ;;
    esac
    [ -f "$dtsi" ] || { print_error "signed bootargs: DTS not found: $dtsi"; exit 1; }

    # The CMA size the SDK's env would have injected at runtime (RK_BOOTARGS_CMA_SIZE):
    # a signed FIT never applies it, so bake exactly that value. For mini this is
    # $MINI_CMA_SIZE — apply_mini_cma_config already rewrote the board config to
    # it earlier in main; for max/pi it is the SDK's own 66M. Reading the config
    # (not a per-board constant) keeps one source of truth: whatever an unsigned
    # build would have ended up with, the signed bake matches.
    local cma_size
    cma_size="$(sed -n 's/^export RK_BOOTARGS_CMA_SIZE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$SS_BOARD_CONFIG" 2>/dev/null | head -n1)"
    [ -n "$cma_size" ] \
        || { print_error "signed bootargs: no RK_BOOTARGS_CMA_SIZE in board config ${SS_BOARD_CONFIG:-missing}"; exit 1; }

    if [ "$medium" = "nand" ]; then
        # The baked cmdline must match what mkfs_ubi.sh actually built. readonly-
        # rootfs (resolved by apply_readonly_rootfs, which runs earlier in main)
        # decides: non-dev packs squashfs into a STATIC UBI volume exposed as
        # /dev/ubiblock0_0; dev keeps a writable dynamic UBIFS volume at
        # ubi0:rootfs. Same split the SDK's own __GET_TARGET_PARTITION_FS_TYPE
        # makes for spi_nand.
        local baked_root marker
        if [ "${SS_RO_ROOTFS:-0}" = "1" ]; then
            baked_root="ubi.block=0,rootfs root=/dev/ubiblock0_0 rootfstype=squashfs ubi.mtd=6 rk_dma_heap_cma=$cma_size"
        else
            baked_root="root=ubi0:rootfs ubi.mtd=6 rootfstype=ubifs rk_dma_heap_cma=$cma_size"
        fi
        marker="${baked_root%% *}"
        if grep -qF "$marker" "$dtsi"; then
            print_success "NAND root already baked in $(basename "$dtsi") ($marker)"
            return 0
        fi
        grep -q "root=/dev/$root_dev" "$dtsi" \
            || { print_error "signed-NAND bootargs: expected 'root=/dev/$root_dev' in $(basename "$dtsi") — SDK layout changed (or a different root= was already baked)"; exit 1; }
        # rootfs is mtd6 in our 7-partition NAND layout (env,idblock,uboot,boot,oem,userdata,rootfs).
        sed -i "s|root=/dev/$root_dev|$baked_root|" "$dtsi"
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
        baked="root=/dev/$root_dev rootfstype=squashfs rk_dma_heap_cma=$cma_size"
        marker="rootfstype=squashfs rk_dma_heap_cma=$cma_size"
        if grep -qF "$marker" "$dtsi"; then
            print_success "SD/eMMC bootargs already baked in $(basename "$dtsi") ($marker)"
            return 0
        fi
        grep -q "root=/dev/$root_dev" "$dtsi" \
            || { print_error "signed-$medium bootargs: expected 'root=/dev/$root_dev' in $(basename "$dtsi") — SDK layout changed (or different bootargs already baked)"; exit 1; }
        # The SDK checkout survives between builds, so the DTSI may carry an
        # EARLIER bake of this same line. Replace root= plus any previously-baked
        # trailing tokens, not just bare root=: a plain substitution would leave
        # the old tokens behind, and if the CMA size ever changes the stale
        # rk_dma_heap_cma would win (the kernel takes the LAST occurrence of a
        # cmdline param).
        sed -i -E "s|root=/dev/$root_dev( rootfstype=[A-Za-z0-9]+)?( rk_dma_heap_cma=[A-Za-z0-9]+)?|$baked|" "$dtsi"
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
# the display work regardless. NOT gated on SEEDSIGNER_FIT_SIGNATURE: unsigned
# builds get the same deterministic display bring-up as signed ones.
apply_spi_display_dts() {
    local profile="$1"
    local dts has_fbtft
    case "$profile" in
        mini) dts="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1103g-luckfox-pico-mini.dts";      has_fbtft=1 ;;
        max)  dts="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pro-max.dts"; has_fbtft=1 ;;
        pi)   dts="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pi.dts";      has_fbtft=0 ;;
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

# Sign the FINAL boot.img (opt-in). The u-boot build signs uboot.img
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
# Runs BEFORE package_firmware's normalise step so the update.img repack embeds
# the signed boot.img. fit.sh runs fit_check_sign internally and is `set -e`, so
# a bad sign aborts here rather than shipping an unbootable enforced image.
sign_boot_image() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local ubootdir="$WORK_DIR/luckfox-pico/sysdrv/source/uboot/u-boot"
    local img="$WORK_DIR/luckfox-pico/output/image/boot.img"
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
# AFTER sign_boot_image (all content mutations done) and BEFORE the releaseTime
# normalise step below, so update.img's repack embeds OUR signatures. Mirrors
# deterministic_sign_chain in os-build.sh - keep the two in sync.
deterministic_sign_chain() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local ubootdir="$WORK_DIR/luckfox-pico/sysdrv/source/uboot/u-boot"
    local image_dir="$WORK_DIR/luckfox-pico/output/image"
    print_step "Deterministically re-signing the boot chain (SEEDSIGNER_FIT_SIGNATURE=1)"
    bash "$SCRIPT_DIR/deterministic-sign.sh" \
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
    # Guarded like os-build.sh's: this block can run more than once per process.
    [ "${SS_INITRAMFS_BINARIES_REBUILT:-0}" = "1" ] && return 0
    local tc="$WORK_DIR/luckfox-pico/tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf"
    print_step "Rebuilding vendored initramfs binaries from source (SEEDSIGNER_REBUILD_INITRAMFS_BINARIES=1)"
    bash "$SCRIPT_DIR/secure-boot/build-initramfs-binaries.sh" \
        "$tc" "$SCRIPT_DIR/secure-boot/initramfs-binaries" || exit 1
    SS_INITRAMFS_BINARIES_REBUILT=1
}

verify_initramfs_binaries() {
    [ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || return 0
    local dir="$SCRIPT_DIR/secure-boot/initramfs-binaries" f actual
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
    local keydir="${SEEDSIGNER_ROOTFS_KEY_DIR:-$SCRIPT_DIR/secure-boot/dev-keys-rootfs}" k
    for k in dev.key dev.pubkey; do
        [ -f "$keydir/$k" ] || { print_error "rootfs signing key missing: $keydir/$k (set SEEDSIGNER_ROOTFS_KEY_DIR to a dir with minisign dev.key/dev.pubkey)"; exit 1; }
    done
    if [[ -z "${SEEDSIGNER_ROOTFS_KEY_PASSPHRASE:-}" ]]; then
        if [ "$keydir" = "$SCRIPT_DIR/secure-boot/dev-keys-rootfs" ]; then
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
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$WORK_DIR/luckfox-pico/.BoardConfig.mk" 2>/dev/null | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"
    local kernel_cfg_file="$WORK_DIR/luckfox-pico/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
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
    local imgdir="$WORK_DIR/luckfox-pico/output/image"
    local sig size_file hook_script
    case "$boot_medium" in
        nand)  sig="$imgdir/rootfs.ubifs.minisig";   size_file="$imgdir/rootfs.ubifs.size";   hook_script="mkfs_ubi.sh (patch-mkfs-ubi-signing.sh)" ;;
        sd|emmc) sig="$imgdir/rootfs.img.minisig";    size_file="$imgdir/rootfs.img.size";     hook_script="mkfs_squashfs.sh (patch-mkfs-squashfs-signing.sh)" ;;
        *) print_error "embed_rootfs_verifier: unsupported boot medium '$boot_medium' (expected nand, sd or emmc)"; exit 1 ;;
    esac
    [ -f "$sig" ] || { print_error "rootfs signature missing at $sig -- the $hook_script signing hook did not run (patch applied? SEEDSIGNER_ROOTFS_SIGNING_KEY exported?)"; exit 1; }

    local ubootdir="$WORK_DIR/luckfox-pico/sysdrv/source/uboot/u-boot"
    local img="$imgdir/boot.img"
    [ -f "$img" ] || { print_error "boot.img not found at $img (run 'build.sh firmware' first)"; exit 1; }

    # --- assemble the initramfs staging tree ---------------------------------
    local bin="$SCRIPT_DIR/secure-boot/initramfs-binaries"
    local src="$SCRIPT_DIR/secure-boot/initramfs"
    local keydir="${SEEDSIGNER_ROOTFS_KEY_DIR:-$SCRIPT_DIR/secure-boot/dev-keys-rootfs}"
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
    dev_fit_hash="$(sha256sum "$SCRIPT_DIR/secure-boot/dev-keys/dev.pubkey" | cut -d' ' -f1)"
    dev_rootfs_hash="$(sha256sum "$SCRIPT_DIR/secure-boot/dev-keys-rootfs/dev.pubkey" | cut -d' ' -f1)"
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
    local src_img="$WORK_DIR/luckfox-pico/output/image"
    local uboot_cfg="$WORK_DIR/luckfox-pico/sysdrv/source/uboot/u-boot/.config"
    local dst="$src_img/fit-sign-tree-${board_profile}"
    print_step "Exporting fit-sign tree for ${board_profile} -> $dst"
    [ -d "$src_img" ] || { print_error "output/image missing at $src_img"; exit 1; }
    rm -rf "$dst"; mkdir -p "$dst/fit_signcfg"
    cp -a "$src_img/." "$dst/"
    # fit-sign.sh reads <src-dir>/fit_signcfg/sign.readonly_config (it greps
    # CONFIG_* from it). Prefer the SDK's own fit_signcfg if the build produced
    # one; otherwise synthesize it from the built u-boot .config, which carries
    # the same CONFIG_FIT_SIGNATURE / SPL_FIT_HW_CRYPTO / CHIP_NAME symbols.
    local sdk_signcfg
    sdk_signcfg="$(find "$WORK_DIR/luckfox-pico" -type f -name sign.readonly_config 2>/dev/null | head -n1)"
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
    print_success "     --images <out> --build-tree $dst --tools <rkbin/tools>"
}

apply_usb_mode_config() {
    local hardware="$1"

    print_header "Configuring USB Mode (USB_MODE=$USB_MODE, variant=$BUILD_VARIANT)"

    # USB role (the adb switch) — shared with CI via configure-usb-mode.sh.
    local usb_hardware
    case "$hardware" in
        mini) usb_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  usb_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   usb_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)    print_error "Unknown hardware type for USB-mode patch: $hardware"; exit 1 ;;
    esac
    bash "$SCRIPT_DIR/configure-usb-mode.sh" "$WORK_DIR/luckfox-pico" \
        "$usb_hardware" "$USB_MODE" "$BUILD_VARIANT"
}

prepare_buildroot() {
    print_header "Preparing Buildroot Source Tree"
    
    cd "$WORK_DIR/luckfox-pico"
    
    make buildroot_create -C sysdrv
    
    print_success "Buildroot source tree prepared"
}

install_seedsigner_packages() {
    print_header "Installing SeedSigner Packages"
    
    cd "$WORK_DIR/luckfox-pico"
    
    # Auto-detect buildroot directory
    local buildroot_dir=$(find sysdrv/source/buildroot -maxdepth 1 -type d -name 'buildroot-*' | sort | tail -n 1)
    
    if [ -z "$buildroot_dir" ] || [ ! -d "$buildroot_dir" ]; then
        print_error "Buildroot directory not found"
        exit 1
    fi
    
    print_info "Using buildroot: $buildroot_dir"
    
    local package_dir="${buildroot_dir}/package"
    
    # Copy the converged, toolchain-aware SeedSigner packages from this repo
    # (single set under opt/external-packages).
    local external_packages_dir="$SCRIPT_DIR/../external-packages"
    print_info "Copying SeedSigner packages from $external_packages_dir ..."
    cp -rv "$external_packages_dir/"* "$package_dir/"
    
    # Add SeedSigner menu to Config.in
    local config_in="${package_dir}/Config.in"
    
    if ! grep -q '^menu "SeedSigner"$' "$config_in"; then
        print_info "Adding SeedSigner menu to buildroot..."
        cat >> "$config_in" << 'EOF'
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
EOF
    fi

    # Patch Rust Kconfig to support uclibc Tier 3 targets (armv7-unknown-linux-uclibceabihf).
    # Buildroot 2024.11.4 only gates Rust target support for glibc/musl. Without this,
    # BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS is never set for uclibc toolchains,
    # silently disabling python-cryptography and any other Rust-dependent package.
    local rustc_config="${package_dir}/rustc/Config.in.host"
    if [ -f "$rustc_config" ] && ! grep -q 'BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS' "$rustc_config"; then
        print_info "Patching Rust Config.in.host for uclibc Tier 3 support..."
        sed -i '/^# All target rust packages should depend on this option/i\
# Tier 3 uclibc platforms - must be built from source (no pre-built std binaries)\
# When adding new entries below, update RUST_TARGETS in utils/update-rust\
config BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS\
\tbool\
\t# armv7-unknown-linux-uclibceabihf\
\tdefault y if BR2_ARM_CPU_ARMV7A \&\& BR2_ARM_EABIHF \&\& BR2_TOOLCHAIN_USES_UCLIBC\
\t# armv7-unknown-linux-uclibceabihf for armv8 hardware with 32-bit userspace\
\tdefault y if BR2_arm \&\& BR2_ARM_CPU_ARMV8A \&\& BR2_ARM_EABIHF \&\& BR2_TOOLCHAIN_USES_UCLIBC\
' "$rustc_config"
        sed -i '/default y if BR2_PACKAGE_HOST_RUSTC_TARGET_TIER2_PLATFORMS/a\
\tdefault y if BR2_PACKAGE_HOST_RUSTC_TARGET_TIER3_UCLIBC_PLATFORMS' "$rustc_config"
    fi

    # Patch rust-bin.mk to skip downloading/installing pre-built rust-std for uclibc
    # (pre-built binaries don't exist for Tier 3 targets; host-rust builds them from source)
    local rustbin_mk="${package_dir}/rust-bin/rust-bin.mk"
    if [ -f "$rustbin_mk" ] && ! grep -q 'BR2_TOOLCHAIN_USES_UCLIBC' "$rustbin_mk"; then
        print_info "Patching rust-bin.mk to skip uclibc std download..."
        sed -i '/^ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)/{
N
/HOST_RUST_BIN_EXTRA_DOWNLOADS/{
s/ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\n/# Pre-built rust-std is not available for uclibc Tier 3 targets;\n# host-rust (build from source) will compile it instead.\nifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\nifneq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)\n/
}
}' "$rustbin_mk"
        sed -i '/^HOST_RUST_BIN_EXTRA_DOWNLOADS += rust-std/{
N
/^HOST_RUST_BIN_EXTRA_DOWNLOADS.*\nendif/{
s/\nendif/\nendif\nendif/
}
}' "$rustbin_mk"
        sed -i '/^ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)/{
N
/define HOST_RUST_BIN_INSTALL_LIBSTD_TARGET/{
s/ifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\n/# Skip installing pre-built target std for uclibc (not available);\n# host-rust (build from source) provides it.\nifeq ($(BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS),y)\nifneq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)\n/
}
}' "$rustbin_mk"
        sed -i '/^endef/{
N
/^endef\nendif/{
s/^endef\nendif/endef\nendif\nendif/
}
}' "$rustbin_mk"
    fi
    
    print_success "SeedSigner packages installed"
}

apply_seedsigner_config() {
    local hardware="${1:-}"
    local boot_medium="${2:-}"
    print_header "Applying SeedSigner Buildroot Configuration"
    
    cd "$WORK_DIR/luckfox-pico"
    
    local buildroot_dir=$(find sysdrv/source/buildroot -maxdepth 1 -type d -name 'buildroot-*' | sort | tail -n 1)
    
    # Copy SeedSigner defconfig
    cp -v "$SCRIPT_DIR/configs/luckfox_pico_defconfig" "$buildroot_dir/configs/luckfox_pico_defconfig"
    # Also copy as luckfox_pico_w_defconfig so the Pi board (RK_BUILDROOT_DEFCONFIG=luckfox_pico_w_defconfig)
    # loads our clean config instead of the SDK's WiFi/BT-enabled config
    cp -v "$SCRIPT_DIR/configs/luckfox_pico_defconfig" "$buildroot_dir/configs/luckfox_pico_w_defconfig"
    cp -v "$SCRIPT_DIR/configs/luckfox_pico_defconfig" "$buildroot_dir/.config"

    # Non-dev (production) hardening: no serial login (getty), no dev/network CLI tools.
    if [ "$BUILD_VARIANT" == "non-dev" ]; then
        print_info "non-dev: hardening defconfig (getty off; drop pip/curl/wget)"
        for dc in "$buildroot_dir/configs/luckfox_pico_defconfig" "$buildroot_dir/configs/luckfox_pico_w_defconfig" "$buildroot_dir/.config"; do
            [ -f "$dc" ] || continue
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

    # Remove pip/setuptools/git from Mini SPI-NAND builds to save space
    if [ "$hardware" == "mini" ] && [ "$boot_medium" == "nand" ]; then
        print_info "Removing python-pip, python-setuptools, and git for Mini SPI-NAND build..."
        sed -i "s/^BR2_PACKAGE_PYTHON_PIP=y/# BR2_PACKAGE_PYTHON_PIP is not set/" "$buildroot_dir/.config"
        sed -i "s/^BR2_PACKAGE_PYTHON_SETUPTOOLS=y/# BR2_PACKAGE_PYTHON_SETUPTOOLS is not set/" "$buildroot_dir/.config"
        sed -i "s/^BR2_PACKAGE_GIT=y/# BR2_PACKAGE_GIT is not set/" "$buildroot_dir/.config"
        print_info "Removed pip/setuptools/git packages for Mini SPI-NAND"
    fi
    
    # Update pyzbar patch
    local pyzbar_patch="${buildroot_dir}/package/python-pyzbar/0001-PATH-fixed-by-hand.patch"
    if [ -f "$pyzbar_patch" ] && [ -f "$buildroot_dir/.config" ]; then
        local python_ver=$(grep -oP 'BR2_PACKAGE_PYTHON3_VERSION="\K[^"]+' "$buildroot_dir/.config" 2>/dev/null || echo "")
        
        if [ -z "$python_ver" ]; then
            python_ver="$DEFAULT_PYTHON_VERSION"
            print_warning "Could not detect Python version from buildroot config, using default: $DEFAULT_PYTHON_VERSION"
        else
            print_info "Detected Python version from buildroot config: $python_ver"
        fi
        
        sed -i "s|path = \"/usr/lib/python.*/site-packages/zbar.so\"|path = \"/usr/lib/python${python_ver}/site-packages/zbar.so\"|" "$pyzbar_patch"
        print_info "Updated pyzbar patch for Python $python_ver"
    fi

    # Normalize python-pyzbar download source for Buildroot mirror compatibility.
    # Keep the same upstream content/hash, but force a deterministic tag tarball URL.
    local pyzbar_mk="${buildroot_dir}/package/python-pyzbar/python-pyzbar-ss.mk"
    local pyzbar_hash="${buildroot_dir}/package/python-pyzbar/python-pyzbar-ss.hash"
    if [ -f "$pyzbar_mk" ]; then
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

        if [ -f "$pyzbar_hash" ]; then
            sed -i -E "/^(sha256|md5)[[:space:]]/ s/[[:space:]][^[:space:]]+$/ ${pyzbar_src}/" "$pyzbar_hash"
            print_info "Updated python-pyzbar hash filename to ${pyzbar_src}"
        fi
    fi
    
    print_success "SeedSigner configuration applied"
}

restore_cached_rust_toolchain() {
    local cache_dir="$SCRIPT_DIR/cache"
    local cache_tar="$cache_dir/rust-toolchain.tar.zst"

    if [ "$BUILD_RUST_FROM_SOURCE" = "1" ]; then
        print_info "🦀 --build-rust-from-source set — will build Rust from source"
        RUST_FROM_CACHE=false
        return
    fi

    if [ ! -f "$cache_tar" ]; then
        print_info "🦀 No cached Rust toolchain found at $cache_tar — will build from source"
        RUST_FROM_CACHE=false
        return
    fi

    local buildroot_dir
    buildroot_dir=$(find sysdrv/source/buildroot -maxdepth 1 -type d -name 'buildroot-*' | sort | tail -n 1)
    if [ -z "$buildroot_dir" ] || [ ! -d "$buildroot_dir" ]; then
        print_warning "Could not locate buildroot directory, skipping cache restore"
        RUST_FROM_CACHE=false
        return
    fi

    print_info "🦀 Restoring cached Rust toolchain from $cache_tar ..."
    ls -lh "$cache_tar"
    mkdir -p "$buildroot_dir/output"
    tar --zstd -xf "$cache_tar" -C "$buildroot_dir/output"

    # Detect Rust version from the extracted binary
    local rust_version=""
    if [ -x "$buildroot_dir/output/host/bin/rustc" ]; then
        rust_version=$("$buildroot_dir/output/host/bin/rustc" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || true)
    fi

    # Create stamp files so buildroot skips the Rust packages entirely.
    # Buildroot uses order-only prerequisites so stamps only need to exist.
    local stamps=".stamp_downloaded .stamp_extracted .stamp_patched .stamp_configured .stamp_built .stamp_host_installed"
    local rust_pkg_dirs="$buildroot_dir/output/build/host-rustc"
    if [ -n "$rust_version" ]; then
        rust_pkg_dirs="$rust_pkg_dirs $buildroot_dir/output/build/host-rust-bin-$rust_version"
        rust_pkg_dirs="$rust_pkg_dirs $buildroot_dir/output/build/host-rust-$rust_version"
    fi

    local pkg_dir
    for pkg_dir in $rust_pkg_dirs; do
        if [ -d "$pkg_dir" ] && [ -f "$pkg_dir/.stamp_host_installed" ]; then
            print_info "  Stamps already present in $(basename "$pkg_dir")"
            continue
        fi
        mkdir -p "$pkg_dir"
        local s
        for s in $stamps; do touch "$pkg_dir/$s"; done
        print_info "  Created stamps for $(basename "$pkg_dir")"
    done

    if [ -x "$buildroot_dir/output/host/bin/rustc" ] && \
       [ -x "$buildroot_dir/output/host/bin/cargo" ] && \
       "$buildroot_dir/output/host/bin/rustc" --version > /dev/null 2>&1; then
        print_success "Cached Rust toolchain restored"
        "$buildroot_dir/output/host/bin/rustc" --version
        RUST_FROM_CACHE=true
    else
        print_warning "Cached toolchain missing binaries or libraries — will build from source"
        # Remove stamps from ALL Rust-related build directories so buildroot
        # rebuilds Rust from source. We must use glob patterns because rust_version
        # may be empty when rustc --version fails (e.g. missing shared libraries).
        for pkg_dir in "$buildroot_dir"/output/build/host-rust-bin-* \
                       "$buildroot_dir"/output/build/host-rust-[0-9]* \
                       "$buildroot_dir"/output/build/host-rustc; do
            if [ -d "$pkg_dir" ]; then
                rm -f "$pkg_dir"/.stamp_*
                print_info "  Removed stamps from $(basename "$pkg_dir")"
            fi
        done
        # Remove broken binaries to avoid confusing buildroot
        rm -rf "$buildroot_dir/output/host/bin/rustc" \
               "$buildroot_dir/output/host/bin/cargo" \
               "$buildroot_dir/output/host/lib/rustlib" 2>/dev/null || true
        RUST_FROM_CACHE=false
    fi
}

save_rust_toolchain_cache() {
    if [ "$RUST_FROM_CACHE" = "true" ]; then
        return  # Already used cache, no need to re-save
    fi

    local buildroot_dir
    buildroot_dir=$(find sysdrv/source/buildroot -maxdepth 1 -type d -name 'buildroot-*' | sort | tail -n 1)
    if [ -z "$buildroot_dir" ] || [ ! -d "$buildroot_dir" ]; then
        return
    fi

    if [ ! -x "$buildroot_dir/output/host/bin/rustc" ]; then
        return
    fi

    local cache_dir="$SCRIPT_DIR/cache"
    local cache_tar="$cache_dir/rust-toolchain.tar.zst"

    print_info "📦 Packaging Rust toolchain for future builds..."
    "$buildroot_dir/output/host/bin/rustc" --version

    cd "$buildroot_dir/output"

    # Collect stamp files for Rust packages
    local stamp_files=""
    local d
    for d in build/host-rust-bin-* build/host-rust-[0-9]* build/host-rustc; do
        if [ -d "$d" ]; then
            stamp_files="$stamp_files $(find "$d" -maxdepth 1 -name '.stamp_*' -type f)"
        fi
    done

    # Collect Rust-specific files from host/
    local file_list
    file_list=$(mktemp)
    {
        for f in host/bin/rustc host/bin/cargo host/bin/rustdoc host/bin/rust-gdb \
                 host/bin/rust-gdbgui host/bin/rust-lldb; do
            [ -e "$f" ] && echo "$f"
        done
        [ -d "host/lib/rustlib" ] && find host/lib/rustlib \( -type f -o -type l \)
        # Include Rust shared libraries required by rustc at runtime
        find host/lib -maxdepth 1 \( -name 'librustc_driver-*.so' -o -name 'libstd-*.so' -o -name 'libtest-*.so' -o -name 'libLLVM-*.so' \) \( -type f -o -type l \) 2>/dev/null || true
        echo "$stamp_files" | tr ' ' '\n' | grep -v '^$'
    } | sort -u > "$file_list"

    mkdir -p "$cache_dir"
    tar --zstd -cf "$cache_tar" --files-from="$file_list"
    rm -f "$file_list"

    ls -lh "$cache_tar"
    print_success "Rust toolchain cached at $cache_tar"
    cd "$WORK_DIR/luckfox-pico"
}

build_system() {
    print_header "Building System Components"
    
    cd "$WORK_DIR/luckfox-pico"
    
    # Unset GITHUB_ACTIONS so Rust's x.py bootstrap doesn't enforce --stage 2.
    # Rust 1.82+'s CiEnv::current() checks GITHUB_ACTIONS (not CI) to detect
    # CI environments, and panics if stage != 2. Buildroot's host-rust calls
    # x.py build without --stage 2.
    unset GITHUB_ACTIONS
    
    # Restore cached Rust toolchain if available
    restore_cached_rust_toolchain

    # Non-dev U-Boot recovery: bootdelay=0 + memory-backed bootcount → rockusb
    # Loader failover. Shared with CI via uboot-recovery-config.sh.
    if [ "$BUILD_VARIANT" == "non-dev" ]; then
        print_info "Applying non-dev U-Boot recovery config (bootcount → loader failover)..."
        bash "$SCRIPT_DIR/uboot-recovery-config.sh" "$WORK_DIR/luckfox-pico"
    fi

    print_info "Building U-Boot..."
    ./build.sh uboot
    
    print_info "Building Kernel..."
    ./build.sh kernel

    # Assert the strip took effect against the GENERATED .config — Kconfig
    # silently drops defconfig lines whose symbol/deps don't resolve.
    if [ "$BUILD_VARIANT" == "non-dev" ]; then
        bash "$SCRIPT_DIR/assert-kernel-network.sh" "$WORK_DIR/luckfox-pico" "${SS_STRIP_NET:-1}" 1 1
        bash "$SCRIPT_DIR/assert-readonly-rootfs.sh" "$WORK_DIR/luckfox-pico" "${SS_BOARD_CONFIG:-}" "${SS_RO_ROOTFS:-0}"
    fi

    # Secure-boot fuse readability (dev AND non-dev: /init's "SECURE BOOT not
    # enabled" screen needs it in both). No-op unless FIT signing is on.
    if [[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ]]; then
        bash "$SCRIPT_DIR/assert-otp-size.sh" "$WORK_DIR/luckfox-pico"
    fi

    print_info "Building Rootfs..."
    ./build.sh rootfs
    
    print_info "Building Media..."
    ./build.sh media
    
    # Keep vendor RkLunch.sh camera bring-up behavior on all builds.
    print_info "Keeping RkLunch.sh rkipc autostart enabled"
    
    print_info "Building Applications..."
    ./build.sh app
    
    # Save Rust toolchain for future builds if it was built from source
    save_rust_toolchain_cache
    
    print_success "System build complete"
}

install_seedsigner_app() {
    local hardware="$1"
    
    print_header "Installing SeedSigner Application"
    
    cd "$WORK_DIR/luckfox-pico"
    
    # Find rootfs directory
    local rootfs_dir=$(find output/out -maxdepth 1 -type d -name "rootfs_uclibc_*" | head -n 1)
    
    if [ -z "$rootfs_dir" ]; then
        print_error "Rootfs directory not found"
        exit 1
    fi
    
    print_info "Using rootfs: $rootfs_dir"
    
    # Install the whole app repo to /opt, matching the Raspberry Pi SeedSigner-OS
    # layout: /opt/src runs the app and its sibling resource dirs resolve
    # (/opt/javacard-cap bundled applets, /opt/gpg_keys release keys). Prune below.
    print_info "Copying SeedSigner application to /opt..."
    mkdir -p "$rootfs_dir/opt"
    cp -a "$WORK_DIR/seedsigner/." "$rootfs_dir/opt/"

    # Generate the SeedSigner OS identity + provenance marker. The OS fields use
    # the SAME expressions as build.sh and CI (build-luckfox.yml's "Prepare build
    # metadata" step): REPO from the origin remote canonicalised to exactly
    # https://github.com/owner/repo (no ".git", no trailing slash -- CI records
    # github.repository bare, and any other form desyncs the image), BRANCH/COMMIT
    # via rev-parse (a detached checkout records "HEAD", exactly as CI does), DATE
    # as %cI -- the latest commit's committer date, not the build time. App git
    # data comes from the cloned repo. Outside a git checkout with a github.com
    # origin the OS fields stay unset and gen-os-release.sh records "unknown".
    local os_repo_root os_remote_url="" os_repo_path
    os_repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    if git -C "$os_repo_root" rev-parse --git-dir >/dev/null 2>&1; then
        os_remote_url="$(git -C "$os_repo_root" remote get-url origin 2>/dev/null || true)"
        case "$os_remote_url" in
            https://github.com/*) os_repo_path="${os_remote_url#https://github.com/}" ;;
            git@github.com:*)    os_repo_path="${os_remote_url#git@github.com:}" ;;
            *)                   os_repo_path="" ;;
        esac
        if [ -n "$os_repo_path" ]; then
            while [ "${os_repo_path%/}" != "$os_repo_path" ]; do os_repo_path="${os_repo_path%/}"; done
            os_remote_url="https://github.com/${os_repo_path%.git}"
        else
            os_remote_url=""
        fi
        SEEDSIGNER_OS_BRANCH="${SEEDSIGNER_OS_BRANCH:-$(git -C "$os_repo_root" rev-parse --abbrev-ref HEAD)}"
        SEEDSIGNER_OS_COMMIT="${SEEDSIGNER_OS_COMMIT:-$(git -C "$os_repo_root" rev-parse HEAD)}"
        SEEDSIGNER_OS_DATE="${SEEDSIGNER_OS_DATE:-$(git -C "$os_repo_root" log -1 --format=%cI)}"
    fi
    SEEDSIGNER_OS_REPO="${SEEDSIGNER_OS_REPO:-$os_remote_url}" \
    SEEDSIGNER_OS_BRANCH="${SEEDSIGNER_OS_BRANCH:-}" \
    SEEDSIGNER_OS_COMMIT="${SEEDSIGNER_OS_COMMIT:-}" \
    SEEDSIGNER_OS_DATE="${SEEDSIGNER_OS_DATE:-}" \
    SEEDSIGNER_APP_GIT_DIR="$WORK_DIR/seedsigner" \
      bash "$SCRIPT_DIR/../gen-os-release.sh" "$rootfs_dir/etc/seedsigner-os-release" \
      || print_warning "Could not generate seedsigner-os-release"

    # Bake the default the boot clock is set from. The RV1106 has no RTC and
    # these images have no NTP, so without this the device comes up at whatever
    # the SoC left behind — which broke GPG key generation outright. Derived
    # from the pinned app commit, so it stays reproducible. Shared with CI via
    # install-build-time.sh; fails the build rather than shipping a bad clock.
    if [ -f "$SCRIPT_DIR/install-build-time.sh" ]; then
        bash "$SCRIPT_DIR/install-build-time.sh" "$rootfs_dir" "$WORK_DIR/seedsigner"
    fi

    # Persistent boot log is OFF by default: a production device writes nothing
    # to flash, and the log captures app output that would otherwise sit in
    # /userdata (which survives a reflash) long after the failure. Bake the
    # marker only when explicitly requested (SEEDSIGNER_BOOT_LOG=on).
    if [ "$SEEDSIGNER_BOOT_LOG" = "on" ]; then
        : > "$rootfs_dir/etc/seedsigner-boot-log"
        print_info "Persistent boot log ENABLED (/etc/seedsigner-boot-log)"
    else
        rm -f "$rootfs_dir/etc/seedsigner-boot-log" 2>/dev/null || true
        print_info "persistent boot log disabled (default)"
    fi

    # Clean up non-essential files from rootfs
    print_info "Cleaning up non-essential files from rootfs..."
    # Keep src, javacard-cap, gpg_keys, tools; drop dev/build cruft (mirror opt/build.sh).
    rm -rf "$rootfs_dir/opt/.git" "$rootfs_dir/opt/.github" "$rootfs_dir/opt/.translation-venv"
    rm -rf "$rootfs_dir/opt/docker" "$rootfs_dir/opt/docs" "$rootfs_dir/opt/enclosures" \
           "$rootfs_dir/opt/electronics" "$rootfs_dir/opt/l10n" \
           "$rootfs_dir/opt/seedsigner-screenshots" "$rootfs_dir/opt/tests" \
           "$rootfs_dir/opt/hardware-kicad" "$rootfs_dir/opt/img" "$rootfs_dir/opt/test_suite"
    rm -f  "$rootfs_dir/opt/.gitignore" "$rootfs_dir/opt/.gitmodules" \
           "$rootfs_dir/opt/.gitattributes" "$rootfs_dir/opt/.python-version" \
           "$rootfs_dir/opt/README.md" "$rootfs_dir/opt/LICENSE.md" \
           "$rootfs_dir/opt/docker-compose.yml" "$rootfs_dir/opt/MANIFEST.in" \
           "$rootfs_dir/opt/pyproject.toml" "$rootfs_dir/opt/seedsigner_pubkey.gpg"
    rm -f  "$rootfs_dir/opt/"setup.* "$rootfs_dir/opt/"requirements*.txt
    rm -rf "$rootfs_dir/opt/src/seedsigner/resources/seedsigner-translations/.git"* 2>/dev/null || true
    find "$rootfs_dir/opt/src/seedsigner/resources/seedsigner-translations/l10n" \
         -name '*.po' -delete 2>/dev/null || true
    print_success "Cleaned up non-essential files"

    install_secure_boot_tools "$hardware"

    # Diagnostic aid (off by default): when SEEDSIGNER_ENABLE_ERROR_DIAGNOSTICS=1
    # is set in the build environment, ship the marker that enables the app's
    # opt-in "Save to MicroSD" button on OS/package error screens (see
    # seedsigner repo: helpers/seedsigner_os.py
    # is_error_microsd_export_enabled()). Its presence is also flagged by the
    # app's own hardening self-check.
    if [ "${SEEDSIGNER_ENABLE_ERROR_DIAGNOSTICS:-0}" = "1" ]; then
        mkdir -p "$rootfs_dir/etc"
        touch "$rootfs_dir/etc/seedsigner-error-microsd-export"
    fi

    # Testing build, off by default: when SEEDSIGNER_TESTING_BUILD=1 is set in
    # the build environment, ship the marker that swaps Home's menu for the
    # hardware test menu (see seedsigner repo: helpers/seedsigner_os.py
    # is_testing_build_enabled()).
    if [ "${SEEDSIGNER_TESTING_BUILD:-0}" = "1" ]; then
        mkdir -p "$rootfs_dir/etc"
        touch "$rootfs_dir/etc/seedsigner-testing-build"
    fi

    # Patch settings.json for Mini hardware
    if [ "$hardware" == "mini" ]; then
        local settings_json="$rootfs_dir/opt/src/settings.json"
        if [ -f "$settings_json" ]; then
            print_info "Patching settings.json for Mini hardware (FOX_22)..."
            sed -i 's/"hardware_config":[[:space:]]*"FOX_40"/"hardware_config": "FOX_22"/g' "$settings_json"
        fi
    fi
    
    # Fix pyzbar library path
    local python_version=$(ls "$rootfs_dir/usr/lib/" | grep -E '^python3\.[0-9]+$' | head -n 1)
    if [ -n "$python_version" ]; then
        print_info "Detected Python version in rootfs: $python_version"
        local site_packages="$rootfs_dir/usr/lib/$python_version/site-packages"
        if [ -f "$site_packages/zbar.so" ]; then
            print_info "Creating zbar.so symlink..."
            ln -sf "$python_version/site-packages/zbar.so" "$rootfs_dir/usr/lib/zbar.so"
        else
            print_warning "zbar.so not found at $site_packages/zbar.so"
        fi
    else
        print_warning "Could not detect Python version in rootfs at $rootfs_dir/usr/lib/"
    fi
    
    # Copy configuration files
    print_info "Copying configuration files..."
    local luckfox_cfg_template="$SCRIPT_DIR/files/luckfox-${hardware}.cfg"
    if [ -f "$luckfox_cfg_template" ]; then
        cp -v "$luckfox_cfg_template" "$rootfs_dir/etc/luckfox.cfg"
    else
        print_warning "Variant template not found for ${hardware}, falling back to $SCRIPT_DIR/files/luckfox.cfg"
        cp -v "$SCRIPT_DIR/files/luckfox.cfg" "$rootfs_dir/etc/luckfox.cfg"
    fi
    cp -v "$SCRIPT_DIR/files/nv12_converter" "$rootfs_dir/"
    cp -v "$SCRIPT_DIR/files/start-seedsigner.sh" "$rootfs_dir/"
    cp -v "$SCRIPT_DIR/files/configure-gpio.sh" "$rootfs_dir/usr/bin/configure-gpio.sh"
    chmod +x "$rootfs_dir/usr/bin/configure-gpio.sh"
    # Startup-failure message on the panel (the "loading" mode is no longer
    # called at boot; see files/show-screen-message.py).
    cp -v "$SCRIPT_DIR/files/show-screen-message.py" "$rootfs_dir/usr/bin/show-screen-message.py"
    chmod +x "$rootfs_dir/usr/bin/show-screen-message.py"
    # SPI bus-configuration sweep, triggered by a `display-probe` marker file.
    cp -v "$SCRIPT_DIR/files/probe-display.py" "$rootfs_dir/usr/bin/probe-display.py"
    chmod +x "$rootfs_dir/usr/bin/probe-display.py"
    cp -v "$SCRIPT_DIR/files/rk-reboot" "$rootfs_dir/usr/bin/rk-reboot"
    chmod +x "$rootfs_dir/usr/bin/rk-reboot"
    # Must sort before every other init script: luckfox-config rewrites
    # /etc/luckfox.cfg at S99 and needs /etc writable by then.
    cp -v "$SCRIPT_DIR/files/S01overlay" "$rootfs_dir/etc/init.d/"
    cp -v "$SCRIPT_DIR/files/S02fsck" "$rootfs_dir/etc/init.d/"
    cp -v "$SCRIPT_DIR/files/S10mdev" "$rootfs_dir/etc/init.d/"
    cp -v "$SCRIPT_DIR/files/S60pcscd" "$rootfs_dir/etc/init.d/"
    cp -v "$SCRIPT_DIR/files/S99seedsigner" "$rootfs_dir/etc/init.d/"
    chmod +x "$rootfs_dir/etc/init.d/S01overlay"
    chmod +x "$rootfs_dir/etc/init.d/S02fsck"
    chmod +x "$rootfs_dir/etc/init.d/S10mdev"
    chmod +x "$rootfs_dir/etc/init.d/S60pcscd"
    chmod +x "$rootfs_dir/etc/init.d/S99seedsigner"
    if [[ -f "$SCRIPT_DIR/files/mdev.conf" ]]; then
        cp -v "$SCRIPT_DIR/files/mdev.conf" "$rootfs_dir/etc/mdev.conf"
    fi
    if [[ -f "$SCRIPT_DIR/files/fat-fsck-hotplug" ]]; then
        cp -v "$SCRIPT_DIR/files/fat-fsck-hotplug" "$rootfs_dir/usr/sbin/fat-fsck-hotplug"
        chmod +x "$rootfs_dir/usr/sbin/fat-fsck-hotplug"
    fi
    mkdir -p "$rootfs_dir/etc/reader.conf.d"
    cp -v "$SCRIPT_DIR/files/sec1210" "$rootfs_dir/etc/reader.conf.d/sec1210"
    mkdir -p "$rootfs_dir/etc/readers.d"
    cp -v "$SCRIPT_DIR/files/sec1210" "$rootfs_dir/etc/readers.d/sec1210"
    if [[ -d "$rootfs_dir/usr/lib/pcsc/drivers/ifd-ccid.bundle" ]]; then
        print_warning "Removing USB CCID bundle as temporary workaround for pcscd SIGTERM issue"
        rm -rf "$rootfs_dir/usr/lib/pcsc/drivers/ifd-ccid.bundle"
    fi
    
    # Install rkaiq camera ISP service script (manual start only, no boot autostart)
    if [[ -f "$SCRIPT_DIR/files/rkaiq-service" ]]; then
        print_info "Installing rkaiq service script..."
        cp -v "$SCRIPT_DIR/files/rkaiq-service" "$rootfs_dir/usr/bin/rkaiq-service"
        chmod +x "$rootfs_dir/usr/bin/rkaiq-service"
        print_success "Installed rkaiq-service to /usr/bin/"
    else
        print_warning "rkaiq-service not found, rkaiq-service will not be available"
    fi

    # USB host-mode fix (all variants; runtime no-op on gadget builds): make
    # S50usbdevice skip the gadget — but still mount configfs (display needs
    # it) — when dr_mode=host. Shared with CI via patch-s50usbdevice.sh.
    if [ -f "$SCRIPT_DIR/patch-s50usbdevice.sh" ]; then
        bash "$SCRIPT_DIR/patch-s50usbdevice.sh" "$rootfs_dir"
    fi

    # GnuPG agent/scdaemon config, staged into /usr/share for start-seedsigner.sh
    # to seed into GNUPGHOME on tmpfs. The app never sets GNUPGHOME, so without
    # this gpg writes to /.gnupg on the read-only root and key generation/import
    # both fail. Shared with CI via install-gnupg-home.sh.
    if [ -f "$SCRIPT_DIR/install-gnupg-home.sh" ]; then
        bash "$SCRIPT_DIR/install-gnupg-home.sh" "$rootfs_dir"
    fi

    # Non-dev (production) rootfs hardening: serial login, adb artifacts,
    # logging daemons, networking (interface bring-up + DHCP + telnet/ssh).
    if [ "$BUILD_VARIANT" == "non-dev" ]; then
        print_info "Applying non-dev rootfs hardening..."
        if [ -f "$SCRIPT_DIR/harden-nondev.sh" ]; then
            # ADB transport removal is the dr_mode=host DTS switch (configure-usb-mode.sh);
            # HARDEN_DISABLE_ADB=1 additionally strips the adb userspace. Networking:
            # DEBUG_NETWORK=on => keep Ethernet+telnet (debug), else disable.
            local harden_net=1
            if [ "$DEBUG_NETWORK" == "on" ]; then harden_net=0; fi
            HARDEN_DISABLE_ADB=1 HARDEN_DISABLE_NETWORK="$harden_net" \
                bash "$SCRIPT_DIR/harden-nondev.sh" "$rootfs_dir" || print_warning "non-dev hardening reported an error"
        fi
        if [ -f "$SCRIPT_DIR/optimize-nondev.sh" ]; then
            bash "$SCRIPT_DIR/optimize-nondev.sh" "$rootfs_dir" || print_warning "non-dev optimization reported an error"
        fi
        # /etc/fw_env.config: optional fw_printenv access to the mtd0 U-Boot env
        # (informational only — the failover env is compiled-in, see
        # uboot-recovery-config.sh).
        if [ -f "$SCRIPT_DIR/files/fw_env.config" ]; then
            cp -v "$SCRIPT_DIR/files/fw_env.config" "$rootfs_dir/etc/fw_env.config"
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
    bash "$SCRIPT_DIR/precompile-bytecode.sh" "$rootfs_dir" "$WORK_DIR/luckfox-pico"

    print_success "SeedSigner application installed"
}

package_firmware() {
    local hardware="$1"
    local boot_medium="$2"

    print_header "Packaging Firmware"

    cd "$WORK_DIR/luckfox-pico"

    # Drop whitespace-named entries (test fixtures like setuptools' vendored
    # jaraco.text `Lorem ipsum.txt`) before build_mkimg packs the ext4 root:
    # mkfs-ext4-deterministic.sh cannot represent such names and fails the
    # build. No-op for trees without any; every removal is logged.
    local rootfs_dir
    rootfs_dir="$(find output/out -maxdepth 1 -type d -name 'rootfs_uclibc_*' | head -n 1)"
    if [ -n "$rootfs_dir" ]; then
        bash "$SCRIPT_DIR/strip-whitespace-filenames.sh" "$rootfs_dir"
    else
        print_warning "no rootfs_uclibc_* dir under output/out — skipping whitespace filename strip"
    fi

    # Install the oem iqfiles prune into the SDK's pre-build-OEM hook. The oem
    # tree is assembled by __PACKAGE_OEM inside `build.sh firmware`, so this is
    # the only window where it exists and is still editable (before build_mkimg
    # makes oem.img). Shared with CI via patch-oem-pre-hook.sh.
    if [ "$BUILD_VARIANT" == "non-dev" ]; then
        if [ -e "$WORK_DIR/luckfox-pico/.BoardConfig.mk" ]; then
            bash "$SCRIPT_DIR/patch-oem-pre-hook.sh" \
                "$(readlink -f "$WORK_DIR/luckfox-pico/.BoardConfig.mk")" \
                "$SCRIPT_DIR/prune-oem-iqfiles.sh" \
                || print_warning "oem pre-build hook patch reported an error"
        else
            print_info "no .BoardConfig.mk symlink — skipping oem iqfiles prune hook"
        fi
    fi

    ./build.sh firmware

    embed_rootfs_verifier "$hardware" "$boot_medium"   # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise). BEFORE sign_boot_image so the FIT signature covers the new ramdisk.
    sign_boot_image                         # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise). BEFORE deterministic_sign_chain so our re-sign covers the final boot.img.
    deterministic_sign_chain                # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise). Digest-derived salts + zeroed timestamp => byte-reproducible signatures. BEFORE normalise so update.img embeds them.

    # Pin the wall-clock releaseTime that boot_merger (download.bin) and
    # rkImageMaker (update.img) stamp into their headers, and repair each file's
    # trailer checksum -- see normalise_boot_images in os-build.sh. Both are
    # prebuilt SDK binaries, so the output is normalized instead of patched.
    # Order matters: update.img embeds a verbatim copy of download.bin, so
    # normalise the LDR first and re-run the pack step before pinning RKFW.
    local image_dir="$WORK_DIR/luckfox-pico/output/image"
    if [ -f "$image_dir/download.bin" ] && [ -f "$image_dir/update.img" ]; then
        bash "$SCRIPT_DIR/ss-fs-normalise.sh" bootimg \
            "$image_dir/download.bin" "${SOURCE_DATE_EPOCH:-0}"

        local chip="rv1106"
        if [ -f "$WORK_DIR/luckfox-pico/.BoardConfig.mk" ]; then
            local cfg_chip
            cfg_chip="$(grep -E '^export RK_CHIP=' "$WORK_DIR/luckfox-pico/.BoardConfig.mk" | head -n 1 | cut -d= -f2)"
            [ -n "$cfg_chip" ] && chip="$cfg_chip"
        fi
        bash "$WORK_DIR/luckfox-pico/tools/linux/Linux_Pack_Firmware/mk-update_pack.sh" \
            -id "$chip" -i "$image_dir"

        bash "$SCRIPT_DIR/ss-fs-normalise.sh" bootimg \
            "$image_dir/update.img" "${SOURCE_DATE_EPOCH:-0}"
    fi

    # The SDK emits sd_update.txt/tftp_update.txt staging every partition at
    # ${ramdisk_addr_r} = 0x00E00000, which leaves ~31 MiB below U-Boot's own
    # relocated stack/heap on a 64 MiB Mini. Our 38.6 MiB rootfs.img does not fit
    # there: mw.b overwrote the running loader and the microSD auto-flash hung
    # mid-write with no console output. Restage low and hard-fail if any image
    # ever outgrows the window again. Shared with os-build.sh.
    # update.img is packed from the partition images and does not contain these
    # text scripts, so this runs after the pack step without changing any hash.
    bash "$SCRIPT_DIR/patch-sd-update-scripts.sh" "$WORK_DIR/luckfox-pico" "$hardware"

    # Re-verify now that the oem partition is staged: every built .ko lands in
    # /oem/usr/ko, which no rootfs hardening touches, so a stray wireless module
    # there would be loadable by root.
    if [ "$BUILD_VARIANT" == "non-dev" ]; then
        bash "$SCRIPT_DIR/assert-kernel-network.sh" "$WORK_DIR/luckfox-pico" "${SS_STRIP_NET:-1}" 1 1
        bash "$SCRIPT_DIR/assert-readonly-rootfs.sh" "$WORK_DIR/luckfox-pico" "${SS_BOARD_CONFIG:-}" "${SS_RO_ROOTFS:-0}"
    fi
    debug_uart_bootargs_outputs

    print_success "Firmware packaged"
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
install_secure_boot_tools() {
    local board="${1:-}"
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
    # The Pico Mini (RV1103, 64 MB) crashes running the app's Luckfox Build
    # Tools, so its image does not carry them; the app then hides the menu and
    # refuses the setting there with an explanation.
    if [ "$board" = "mini" ]; then
        print_info "secure-boot signers: skipped (not supported on the Pico Mini)"
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

create_sd_image() {
    local hardware="$1"
    
    print_header "Creating SD Card Image"
    
    cd "$WORK_DIR/luckfox-pico/output/image"
    
    local board_label
    case "$hardware" in
        mini) board_label="mini" ;;
        max) board_label="max" ;;
        *) board_label="unknown" ;;
    esac
    
    local tag="$(artifact_tag)"
    local image_name="seedsigner-luckfox-pico-${board_label}-sd-${tag}.img"
    
    print_info "Creating image: $image_name"
    
    "$SCRIPT_DIR/blkenvflash" "$image_name"
    
    if [ -f "$image_name" ]; then
        print_success "SD image created: $(pwd)/$image_name"
        ls -lh "$image_name"
    else
        print_error "Failed to create SD image"
        exit 1
    fi
}

create_nand_bundle() {
    local hardware="$1"
    
    print_header "Creating NAND Flash Bundle"
    
    cd "$WORK_DIR/luckfox-pico/output/image"
    
    if [ ! -f "update.img" ]; then
        print_error "update.img not found"
        exit 1
    fi
    
    local board_label
    case "$hardware" in
        mini) board_label="mini" ;;
        max) board_label="max" ;;
        *) board_label="unknown" ;;
    esac
    
    local tag="$(artifact_tag)"
    local nand_bundle_dir="seedsigner-luckfox-pico-${board_label}-nand-files-${tag}"
    
    mkdir -p "$nand_bundle_dir"
    
    # Copy required files
    local required_files=(
        update.img download.bin env.img idblock.img
        uboot.img boot.img oem.img
        rootfs.img userdata.img sd_update.txt tftp_update.txt
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            cp -v "$file" "$nand_bundle_dir/"
        else
            print_warning "Missing file: $file"
        fi
    done

    # userdata.img is required, not optional: /userdata is the only non-rootfs
    # writable store the app saves settings to, so a bundle without it flashes a
    # board that boots, looks healthy, and silently discards every setting. Both
    # loops above only warn on a missing file, so check explicitly.
    if [ ! -f "$nand_bundle_dir/userdata.img" ]; then
        print_error "userdata.img missing from the NAND bundle."
        echo "   Every board's partition table declares a userdata partition, so the"
        echo "   SDK should have emitted it. Check the partition layout step"
        echo "   (apply-partition-layout.sh)."
        exit 1
    fi
    
    # Create README
    cat > "$nand_bundle_dir/README.txt" << 'EOF'
SeedSigner Luckfox NAND Flash Bundle

Contains SDK-generated NAND flashing files:
- update.img / download.bin
- partition images (*.img)
- U-Boot scripts: sd_update.txt and tftp_update.txt

Flash guidance:
- Use update.img with official Luckfox/Rockchip upgrade tooling, or
- Use sd_update.txt / tftp_update.txt with U-Boot workflows.

For detailed instructions, see:
https://wiki.luckfox.com/Luckfox-Pico/Linux-MacOS-Burn-Image/
EOF
    
    # Create tar.gz archive
    local bundle_name="seedsigner-luckfox-pico-${board_label}-nand-bundle-${tag}.tar.gz"
    tar -czf "$bundle_name" "$nand_bundle_dir"
    
    print_success "NAND bundle created: $(pwd)/$bundle_name"
    ls -lh "$bundle_name"
}

create_emmc_bundle() {
    local hardware="$1"
    
    print_header "Creating eMMC Flash Bundle"
    
    cd "$WORK_DIR/luckfox-pico/output/image"
    
    if [ ! -f "update.img" ]; then
        print_error "update.img not found"
        exit 1
    fi
    
    local board_label
    case "$hardware" in
        pi) board_label="pi" ;;
        *) board_label="unknown" ;;
    esac
    
    local tag="$(artifact_tag)"
    local emmc_bundle_dir="seedsigner-luckfox-pico-${board_label}-emmc-files-${tag}"
    
    mkdir -p "$emmc_bundle_dir"
    
    # Copy available files to bundle
    local emmc_files=(
        update.img download.bin env.img idblock.img
        uboot.img boot.img oem.img rootfs.img userdata.img
    )
    
    for file in "${emmc_files[@]}"; do
        if [ -f "$file" ]; then
            cp -v "$file" "$emmc_bundle_dir/"
        else
            print_info "Optional file not found, skipping: $file"
        fi
    done

    # userdata.img is required, not optional: /userdata is the only non-rootfs
    # writable store the app saves settings to, so a bundle without it flashes a
    # board that boots, looks healthy, and silently discards every setting. Both
    # loops above only warn on a missing file, so check explicitly.
    if [ ! -f "$emmc_bundle_dir/userdata.img" ]; then
        print_error "userdata.img missing from the eMMC bundle."
        echo "   Every board's partition table declares a userdata partition, so the"
        echo "   SDK should have emitted it. Check the partition layout step"
        echo "   (apply-partition-layout.sh)."
        exit 1
    fi
    
    # Create README
    cat > "$emmc_bundle_dir/README.txt" << 'EOF'
SeedSigner Luckfox eMMC Flash Bundle

Contains SDK-generated eMMC flashing files:
- update.img / download.bin
- partition images (*.img)

Flash guidance:
- Use update.img with official Luckfox SocToolKit (Windows) or rkdeveloptool (Linux/Mac)
- Connect the board in MASKROM mode (hold BOOT button while connecting USB)

For detailed instructions, see:
https://wiki.luckfox.com/Luckfox-Pico-Plus-Mini/Flash-image
EOF
    
    # Create tar.gz archive
    local bundle_name="seedsigner-luckfox-pico-${board_label}-emmc-bundle-${tag}.tar.gz"
    tar -czf "$bundle_name" "$emmc_bundle_dir"
    
    print_success "eMMC bundle created: $(pwd)/$bundle_name"
    ls -lh "$bundle_name"
}

# WARNING: the SDK's own clean is destructive in a way that is not obvious.
# boardtools_clean / `clean drv` / `clean tools which run on pc` delete the
# PREBUILT board tools shipped in the SDK checkout (udev, mtd-utils, memtester,
# stressapptest, rockchip_test, adbd, usbdevice, and the dosfstools binaries
# S02fsck needs). Nothing rebuilds them, so a build after this clean ships an
# image ~84 files lighter than the validated CI build. os-build.sh used to call
# this before every profile, which is why its images did not boot.
#
# Prefer restoring the SDK with git (prepare-sdk-checkout.sh does exactly that:
# reset --hard + clean -ffdx), which puts the prebuilts back. Only use this when
# you specifically want the SDK's own clean semantics.
clean_build() {
    print_header "Cleaning Build Artifacts"
    print_warning "The SDK clean removes prebuilt board tools; a build straight"
    print_warning "after this will be missing them. Use prepare-sdk-checkout.sh"
    print_warning "to restore a pristine SDK instead."
    
    if [ -d "$WORK_DIR/luckfox-pico" ]; then
        print_info "Cleaning luckfox-pico build..."
        cd "$WORK_DIR/luckfox-pico"
        ./build.sh clean || true
    fi
    
    print_success "Build artifacts cleaned"
}

# Main execution
main() {
    local hardware="mini"
    local boot_medium="sd"
    local check_deps_only=false
    local clone_only=false
    local clean_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --hardware)
                if [[ -n "$2" && "$2" =~ ^(mini|max|pi)$ ]]; then
                    hardware="$2"
                    shift 2
                else
                    print_error "Invalid hardware type. Use: mini|max|pi"
                    exit 1
                fi
                ;;
            # Mirror the GitHub Actions inputs of the same names, so this script
            # can build the same image CI builds.
            # A ref is a branch, a release tag, or a commit -- `git clone -b`
            # accepts all three. --seedsigner-branch is kept as an alias because
            # it is what the CI input is still called.
            --seedsigner-ref|--seedsigner-branch)
                if [[ -n "$2" ]]; then
                    SEEDSIGNER_REF="$2"; shift 2
                else
                    print_error "Missing argument for $1"; exit 1
                fi
                ;;
            --seedsigner-repo)
                if [[ -n "$2" ]]; then
                    SEEDSIGNER_REPO_URL="$2"; shift 2
                else
                    print_error "Missing argument for --seedsigner-repo"; exit 1
                fi
                ;;
            --variant)
                if [[ -n "$2" && "$2" =~ ^(non-dev|dev)$ ]]; then
                    BUILD_VARIANT="$2"; shift 2
                else
                    print_error "Invalid or missing argument for --variant (use: non-dev|dev)"; exit 1
                fi
                ;;
            --readonly-rootfs)
                if [[ -n "$2" && "$2" =~ ^(auto|on|off)$ ]]; then
                    READONLY_ROOTFS="$2"; shift 2
                else
                    print_error "Invalid or missing argument for --readonly-rootfs (use: auto|on|off)"; exit 1
                fi
                ;;
            --boot)
                if [[ -n "$2" && "$2" =~ ^(sd|nand|emmc)$ ]]; then
                    boot_medium="$2"
                    shift 2
                else
                    print_error "Invalid boot medium. Use: sd|nand|emmc"
                    exit 1
                fi
                ;;
            --check-deps)
                check_deps_only=true
                shift
                ;;
            --enable-uart2-console)
                DISABLE_UART2_CONSOLE_DEBUG=0
                shift
                ;;
            --build-rust-from-source)
                BUILD_RUST_FROM_SOURCE=1
                shift
                ;;
            --clone-only)
                clone_only=true
                shift
                ;;
            --clean)
                clean_only=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    print_header "SeedSigner Local Build System"
    print_info "Hardware: $hardware"
    print_info "Boot Medium: $boot_medium"
    print_info "Disable UART2 Console Debug: $DISABLE_UART2_CONSOLE_DEBUG"
    print_info "Build Rust From Source: $BUILD_RUST_FROM_SOURCE"
    print_info "Working Directory: $WORK_DIR"
    
    # Handle special modes
    if [ "$clean_only" == "true" ]; then
        clean_build
        exit 0
    fi
    
    # Check Ubuntu version
    check_ubuntu_version
    
    # Check/install dependencies
    if [ "$check_deps_only" == "true" ]; then
        check_and_install_dependencies "auto"
        print_success "Dependencies check complete"
        exit 0
    else
        check_and_install_dependencies "check"
    fi
    
    # Clone repositories
    clone_repositories
    
    # Apply SDK patches for SPI-NAND optimization
    apply_sdk_patches
    
    if [ "$clone_only" == "true" ]; then
        print_success "Repositories cloned and patches applied. Exiting."
        exit 0
    fi
    
    # Full build process
    setup_toolchain
    configure_board "$hardware" "$boot_medium"
    apply_uart2_console_config "$hardware" "$boot_medium"
    apply_uart2_console_dts_patch "$hardware"
    apply_uart2_fiq_kernel_patch "$hardware" "$boot_medium"
    apply_hwrng_kernel_patch "$hardware" "$boot_medium"
    apply_rng_dts_patch "$hardware"
    apply_sdmmc_dts_patch "$hardware" "$boot_medium"
    apply_otp_size_patch
    apply_kernel_network_strip "$hardware" "$boot_medium"
    apply_readonly_rootfs "$hardware" "$boot_medium"
    apply_spidev_bufsiz "$hardware"
    apply_spi_display_dts "$hardware"   # static spidev0.0 in the DTB (all builds; signed FITs cannot use the runtime overlay)
    apply_usb_mode_config "$hardware"
    apply_mini_cma_config "$hardware" "$boot_medium"

    # Secure boot (opt-in, no-op unless SEEDSIGNER_FIT_SIGNATURE=1): enable FIT
    # signature enforcement in the U-Boot defconfig and bake the rootfs cmdline
    # into the signed DTB — both must land BEFORE the U-Boot/kernel build. After
    # apply_readonly_rootfs on purpose: apply_signed_nand_bootargs reads its
    # SS_RO_ROOTFS/SS_BOARD_CONFIG exports to pick the baked root= args.
    apply_fit_signature_config   # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise)
    apply_signed_nand_bootargs "$hardware" "$boot_medium"   # signed NAND: bake root=ubi0 into the DTB (no-op otherwise)

    # Rootfs verification setup, all no-ops unless SEEDSIGNER_FIT_SIGNATURE=1.
    # provision_rootfs_signing_key must run before `build.sh firmware`: the
    # mkfs_ubi.sh fakeroot script inherits SEEDSIGNER_ROOTFS_SIGNING_KEY from
    # this environment to sign the rootfs volume's logical UBIFS contents.
    rebuild_initramfs_binaries   # opt-in: SEEDSIGNER_REBUILD_INITRAMFS_BINARIES=1 (no-op otherwise)
    verify_initramfs_binaries
    provision_rootfs_signing_key
    apply_initramfs_kernel_config "$hardware" "$boot_medium"

    prepare_buildroot
    install_seedsigner_packages
    apply_seedsigner_config "$hardware" "$boot_medium"
    
    print_info "Starting build process (this may take 60-120 minutes)..."
    build_system
    
    install_seedsigner_app "$hardware"
    package_firmware "$hardware" "$boot_medium"
    
    # Create output based on boot medium
    if [ "$boot_medium" == "sd" ]; then
        create_sd_image "$hardware"
    elif [ "$boot_medium" == "emmc" ]; then
        create_emmc_bundle "$hardware"
    else
        create_nand_bundle "$hardware"
    fi

    export_fit_sign_tree "$hardware"   # opt-in: SEEDSIGNER_FIT_SIGNATURE=1 (no-op otherwise)

    print_header "Build Complete!"
    print_success "Hardware: $hardware"
    print_success "Boot Medium: $boot_medium"
    print_success "Output location: $WORK_DIR/luckfox-pico/output/image/"
    
    echo ""
    print_info "Next steps:"
    if [ "$boot_medium" == "sd" ]; then
        echo "  1. Flash the .img file to an SD card"
        echo "  2. Insert SD card into LuckFox Pico device"
        echo "  3. Power on and enjoy SeedSigner!"
    elif [ "$boot_medium" == "emmc" ]; then
        echo "  1. Extract the eMMC bundle (.tar.gz)"
        echo "  2. Flash using official LuckFox SocToolKit or rkdeveloptool"
        echo "  3. See: https://wiki.luckfox.com/Luckfox-Pico-Plus-Mini/Flash-image"
    else
        echo "  1. Extract the NAND bundle (.tar.gz)"
        echo "  2. Flash using official LuckFox tools"
        echo "  3. See: https://wiki.luckfox.com/Luckfox-Pico/Linux-MacOS-Burn-Image/"
    fi
}

# Run main with all arguments
main "$@"
