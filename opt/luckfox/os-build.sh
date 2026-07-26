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
export SEEDSIGNER_REPO_URL="https://github.com/3rdIteration/seedsigner.git"
export SEEDSIGNER_BRANCH="dev"
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
export BUILDROOT_DIR="${LUCKFOX_SDK_DIR}/sysdrv/source/buildroot/buildroot-2023.02.6"
export PACKAGE_DIR="${BUILDROOT_DIR}/package"
export CONFIG_IN="${PACKAGE_DIR}/Config.in"
export PYZBAR_PATCH="${PACKAGE_DIR}/python-pyzbar/0001-PATH-fixed-by-hand.patch"
export ROOTFS_DIR="${LUCKFOX_SDK_DIR}/output/out/rootfs_uclibc_rv1106"

# Parallel build configuration
export BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
export MAKEFLAGS="-j${BUILD_JOBS}"
export BR2_JLEVEL="${BUILD_JOBS}"
export FORCE_UNSAFE_CONFIGURE=1
export BUILD_MODEL="${BUILD_MODEL:-both}"
export MINI_CMA_SIZE="${MINI_CMA_SIZE:-1M}"
export DISABLE_UART2_CONSOLE_DEBUG="${DISABLE_UART2_CONSOLE_DEBUG:-1}"
export DEFAULT_PYTHON_VERSION="${DEFAULT_PYTHON_VERSION:-3.12}"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_step() { echo -e "\n${BLUE}[STEP] $1${NC}\n"; }
print_success() { echo -e "\n${GREEN}[SUCCESS] $1${NC}\n"; }
print_error() { echo -e "\n${RED}[ERROR] $1${NC}\n"; }
print_info() { echo -e "\n${YELLOW}[INFO] $1${NC}\n"; }

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
    echo "  - UART2 console toggle via DISABLE_UART2_CONSOLE_DEBUG=1|0 (default: 1)"
    echo "  - Rust toolchain: always built from source in Docker (no caching)"
    echo ""
}

clone_repositories() {
    print_step "Cloning Required Repositories"
    
    mkdir -p "$REPOS_DIR"
    cd "$REPOS_DIR"
    
    # Clone luckfox-pico SDK
    if [[ ! -d "luckfox-pico" ]]; then
        print_info "Cloning luckfox-pico SDK..."
        git clone "$LUCKFOX_REPO_URL" --depth=1 --single-branch luckfox-pico
        print_success "luckfox-pico cloned"
    else
        print_info "luckfox-pico already exists"
    fi
    
    # SeedSigner OS Buildroot packages are part of this repo and mounted at
    # $SEEDSIGNER_OS_PACKAGES_DIR (see build.sh); nothing to clone here.

    # Clone SeedSigner code (specific branch)
    if [[ ! -d "seedsigner" ]]; then
        print_info "Cloning seedsigner code (branch: $SEEDSIGNER_BRANCH)..."
        git clone "$SEEDSIGNER_REPO_URL" --depth=1 -b "$SEEDSIGNER_BRANCH" --single-branch --recurse-submodules seedsigner
        print_success "seedsigner cloned"
    else
        print_info "seedsigner already exists"
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
    
    cd "$LUCKFOX_SDK_DIR"
    
    # Show files before patching
    print_info "Checking target files..."
    if [ -f project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk ]; then
        echo "  ${GREEN}✓${NC} Mini BoardConfig found"
    else
        print_error "Mini BoardConfig NOT FOUND!"
        cd "$REPOS_DIR"
        return 1
    fi
    
    if [ -f project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk ]; then
        echo "  ${GREEN}✓${NC} Max BoardConfig found"
    else
        print_error "Max BoardConfig NOT FOUND!"
        cd "$REPOS_DIR"
        return 1
    fi
    echo ""
    
    # Apply Mini SPI-NAND partition optimization using sed (more reliable than patches)
    print_info "Applying Mini SPI-NAND partition optimization..."
    MINI_FILE="project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk"
    # Remove userdata from partition table and shrink OEM, expand rootfs
    sed -i 's/30M(oem),6M(userdata),85M(rootfs)/20M(oem),99M(rootfs)/' "$MINI_FILE"
    # Remove userdata from filesystem config
    sed -i 's/,userdata@\/userdata@ubifs//' "$MINI_FILE"
    echo "  ${GREEN}✓${NC} Mini SPI-NAND partition modified (sed)"
    echo ""
    
    # Apply Max SPI-NAND partition optimization using sed
    print_info "Applying Max SPI-NAND partition optimization..."
    MAX_FILE="project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk"
    # Remove userdata from partition table and shrink OEM, expand rootfs
    sed -i 's/30M(oem),10M(userdata),210M(rootfs)/20M(oem),227M(rootfs)/' "$MAX_FILE"
    # Remove userdata from filesystem config
    sed -i 's/,userdata@\/userdata@ubifs//' "$MAX_FILE"
    echo "  ${GREEN}✓${NC} Max SPI-NAND partition modified (sed)"
    echo ""
    
    # Apply Pi eMMC partition update to remove userdata.img expectation
    print_info "Applying Pi eMMC partition update..."
    PI_FILE="project/cfg/BoardConfig_IPC/BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Pi-IPC.mk"
    if [ -f "$PI_FILE" ]; then
        sed -i 's/,256M(userdata),/,/' "$PI_FILE"
        sed -i 's/,userdata@\/userdata@ext4//' "$PI_FILE"
        echo "  ${GREEN}✓${NC} Pi eMMC userdata removed from partition/fs config (sed)"
    else
        echo "  ${YELLOW}⚠${NC}  Pi eMMC BoardConfig not found, skipping"
    fi
    echo ""

    # Verify patches were applied by checking partition sizes
    print_info "Verifying patches..."
    MINI_PARTITION=$(grep "RK_PARTITION_CMD_IN_ENV=" project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk | head -1)
    MAX_PARTITION=$(grep "RK_PARTITION_CMD_IN_ENV=" project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk | head -1)
    
    echo "  Mini partition table:"
    echo "    $MINI_PARTITION"
    echo ""
    echo "  Max partition table:"
    echo "    $MAX_PARTITION"
    echo ""
    
    # Check if patches actually modified the files
    if echo "$MINI_PARTITION" | grep -q "99M(rootfs)"; then
        echo "  ${GREEN}✓${NC} Mini partition optimization VERIFIED (rootfs = 103MB)"
    else
        echo "  ${YELLOW}⚠${NC}  WARNING: Mini partition may not be optimized!"
    fi
    
    if echo "$MAX_PARTITION" | grep -q "227M(rootfs)"; then
        echo "  ${GREEN}✓${NC} Max partition optimization VERIFIED (rootfs = 103MB)"
    else
        echo "  ${YELLOW}⚠${NC}  WARNING: Max partition may not be optimized!"
    fi
    echo ""
    
    print_success "Partition layout optimized:"
    echo "  - OEM: 30MB → 20MB (save 10MB, 16.4MB used + 3.6MB headroom)"
    echo "  - Userdata: 6MB → Removed (save 6MB, SeedSigner is stateless)"
    echo "  - Rootfs: 85MB → 103MB (add 18MB, total 34MB gained)"
    echo ""
    
    # Show partition summary
    print_info "SPI-NAND Partition Summary (128MB flash):"
    echo "  ┌─────────────┬──────────┬────────────┬─────────────┐"
    echo "  │ Partition   │ Size     │ Offset     │ Purpose     │"
    echo "  ├─────────────┼──────────┼────────────┼─────────────┤"
    echo "  │ env         │   256 KB │ 0x00000    │ Environment │"
    echo "  │ idblock     │   256 KB │ 0x40000    │ Boot ID     │"
    echo "  │ uboot       │   512 KB │ 0x80000    │ U-Boot      │"
    echo "  │ boot        │     4 MB │ 0x100000   │ Kernel+DTB  │"
    echo "  │ oem         │    20 MB │ 0x500000   │ OEM data    │"
    echo "  │ rootfs      │   103 MB │ 0x1900000  │ Root FS     │"
    echo "  └─────────────┴──────────┴────────────┴─────────────┘"
    echo "  Total allocated: ~128 MB (fits 128MB SPI-NAND)"
    echo ""
    
    cd "$REPOS_DIR"
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

apply_hwrng_crypto_kernel_patch() {
    local board_profile="$1"
    local boot_medium="$2"

    local sdk_hardware sdk_boot_medium
    case "$board_profile" in
        mini) sdk_hardware="RV1103_Luckfox_Pico_Mini" ;;
        max)  sdk_hardware="RV1106_Luckfox_Pico_Pro_Max" ;;
        pi)   sdk_hardware="RV1106_Luckfox_Pico_Pi" ;;
        *)
            print_error "Unsupported board profile for HWRNG/crypto kernel patch: $board_profile"
            exit 1
            ;;
    esac
    case "$boot_medium" in
        sd)   sdk_boot_medium="SD_CARD" ;;
        nand) sdk_boot_medium="SPI_NAND" ;;
        emmc) sdk_boot_medium="EMMC" ;;
        *)
            print_error "Unsupported boot medium for HWRNG/crypto kernel patch: $boot_medium"
            exit 1
            ;;
    esac

    local board_config="$LUCKFOX_SDK_DIR/project/cfg/BoardConfig_IPC/BoardConfig-${sdk_boot_medium}-Buildroot-${sdk_hardware}-IPC.mk"
    if [[ ! -f "$board_config" && -L "$LUCKFOX_SDK_DIR/.BoardConfig.mk" ]]; then
        board_config="$(readlink -f "$LUCKFOX_SDK_DIR/.BoardConfig.mk")"
    fi
    if [[ ! -f "$board_config" ]]; then
        print_error "Board config file not found for HWRNG/crypto kernel patch: $board_config"
        exit 1
    fi

    local kernel_defconfig
    kernel_defconfig="$(sed -n 's/^export RK_KERNEL_DEFCONFIG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$board_config" | head -n1)"
    [[ -n "$kernel_defconfig" ]] || kernel_defconfig="luckfox_rv1106_linux_defconfig"

    local kernel_cfg_file="$LUCKFOX_SDK_DIR/sysdrv/source/kernel/arch/arm/configs/$kernel_defconfig"
    if [[ ! -f "$kernel_cfg_file" ]]; then
        print_error "Kernel defconfig not found for HWRNG/crypto patch: $kernel_cfg_file"
        exit 1
    fi

    print_step "Enabling HWRNG and hardware crypto in kernel defconfig ($kernel_defconfig)"

    # Enable hardware random number generator
    sed -i -E '/^CONFIG_HW_RANDOM(=|_)/d;/^# CONFIG_HW_RANDOM is not set$/d' "$kernel_cfg_file"
    sed -i -E '/^CONFIG_HW_RANDOM_ROCKCHIP(=|_)/d;/^# CONFIG_HW_RANDOM_ROCKCHIP is not set$/d' "$kernel_cfg_file"
    {
        echo 'CONFIG_HW_RANDOM=y'
        echo 'CONFIG_HW_RANDOM_ROCKCHIP=y'
    } >> "$kernel_cfg_file"

    # Enable Rockchip hardware crypto (crypto v3 for RV1106/RV1103)
    sed -i -E '/^CONFIG_CRYPTO_DEV_ROCKCHIP(=|_)/d;/^# CONFIG_CRYPTO_DEV_ROCKCHIP is not set$/d' "$kernel_cfg_file"
    sed -i -E '/^CONFIG_CRYPTO_DEV_ROCKCHIP_DEV(=|_)/d;/^# CONFIG_CRYPTO_DEV_ROCKCHIP_DEV is not set$/d' "$kernel_cfg_file"
    {
        echo 'CONFIG_CRYPTO_DEV_ROCKCHIP=y'
        echo 'CONFIG_CRYPTO_DEV_ROCKCHIP_DEV=y'
    } >> "$kernel_cfg_file"

    if ! grep -Eq '^CONFIG_HW_RANDOM=y$' "$kernel_cfg_file"; then
        print_error "Kernel HWRNG enable verification failed: CONFIG_HW_RANDOM in $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_HW_RANDOM_ROCKCHIP=y$' "$kernel_cfg_file"; then
        print_error "Kernel HWRNG enable verification failed: CONFIG_HW_RANDOM_ROCKCHIP in $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_CRYPTO_DEV_ROCKCHIP=y$' "$kernel_cfg_file"; then
        print_error "Kernel crypto enable verification failed: CONFIG_CRYPTO_DEV_ROCKCHIP in $kernel_cfg_file"
        exit 1
    fi
    if ! grep -Eq '^CONFIG_CRYPTO_DEV_ROCKCHIP_DEV=y$' "$kernel_cfg_file"; then
        print_error "Kernel crypto enable verification failed: CONFIG_CRYPTO_DEV_ROCKCHIP_DEV in $kernel_cfg_file"
        exit 1
    fi
    print_success "HWRNG and hardware crypto enabled in kernel defconfig: $kernel_cfg_file"
}

apply_crypto_dts_patch() {
    local board_profile="$1"

    local dts_file
    dts_file="$(resolve_dts_path_for_profile "$board_profile")"

    print_step "Enabling crypto DTS node (${board_profile})"

    if grep -Eq '&crypto[[:space:]]*\{' "$dts_file"; then
        sed -i '/&crypto[[:space:]]*{/,/};/ s/status[[:space:]]*=[[:space:]]*"[^"]*"/status = "okay"/' "$dts_file"
    else
        printf '\n&crypto {\n\tstatus = "okay";\n};\n' >> "$dts_file"
    fi

    if ! awk '/&crypto[[:space:]]*\{/{found=1} found && /status[[:space:]]*=[[:space:]]*"okay"/{ok=1} /\};/{if(found)exit} END{exit !ok}' "$dts_file"; then
        print_error "Crypto DTS node enable verification failed in: $dts_file"
        exit 1
    fi
    print_success "Crypto DTS node enabled in: $dts_file"
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

create_nand_image_artifacts() {
    local board_profile="$1"
    local ts="$2"
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

    local nand_bundle_dir="$OUTPUT_DIR/seedsigner-luckfox-pico-${board_profile}-nand-files-${ts}"
    mkdir -p "$nand_bundle_dir"

    local required_bundle_files=(
        update.img
        download.bin
        env.img
        idblock.img
        uboot.img
        boot.img
        oem.img
        rootfs.img
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

    local nand_bundle="seedsigner-luckfox-pico-${board_profile}-nand-bundle-${ts}.tar.gz"
    tar -czf "$OUTPUT_DIR/$nand_bundle" -C "$OUTPUT_DIR" "$(basename "$nand_bundle_dir")"
    print_success "NAND bundle folder created: $nand_bundle_dir"
    print_success "NAND bundle archive created: $OUTPUT_DIR/$nand_bundle"
}


create_emmc_bundle() {
    local board_profile="$1"
    local ts="$2"

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

    local emmc_bundle_dir="$OUTPUT_DIR/seedsigner-luckfox-pico-${board_profile}-emmc-files-${ts}"
    mkdir -p "$emmc_bundle_dir"

    local emmc_files=(
        update.img
        download.bin
        env.img
        idblock.img
        uboot.img
        boot.img
        oem.img
        rootfs.img
    )

    for file in "${emmc_files[@]}"; do
        if [[ -f "$file" ]]; then
            cp -v "$file" "$emmc_bundle_dir/"
        else
            print_info "Optional file not found, skipping: $file"
        fi
    done

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

    local emmc_bundle="seedsigner-luckfox-pico-${board_profile}-emmc-bundle-${ts}.tar.gz"
    tar -czf "$OUTPUT_DIR/$emmc_bundle" -C "$OUTPUT_DIR" "$(basename "$emmc_bundle_dir")"
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
    done

    print_success "Validated NAND-oriented update scripts"
}


export_official_nand_image_dir() {
    local board_profile="$1"
    local ts="$2"
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

    local bundle_name="seedsigner-luckfox-pico-${board_profile}-nand-sdk-images-${ts}.tar.gz"
    tar -czf "$OUTPUT_DIR/$bundle_name" -C "$image_root" "$(basename "$latest_dir")"
    print_success "Exported official SDK NAND image directory: $OUTPUT_DIR/$bundle_name"
}

ensure_buildroot_tree() {
    if [[ -d "$BUILDROOT_DIR" ]]; then
        return
    fi

    print_step "Preparing Buildroot Source Tree"
    make buildroot_create -C "$LUCKFOX_SDK_DIR/sysdrv"

    if [[ ! -d "$BUILDROOT_DIR" ]]; then
        print_error "Buildroot directory not found after buildroot_create: $BUILDROOT_DIR"
        exit 1
    fi
}

build_profile_artifacts() {
    local board_profile="$1"
    local boot_medium="$2"
    local include_nand="$3"

    cd "$LUCKFOX_SDK_DIR"
    select_board_profile "$board_profile" "$boot_medium"
    apply_mini_cma_profile

    print_step "Cleaning Previous Build (${board_profile}/${boot_medium})"
    ./build.sh clean

    # Some SDK clean paths may reset board context; force board selection again.
    select_board_profile "$board_profile" "$boot_medium"
    apply_uart2_console_config "$board_profile" "$boot_medium"
    apply_uart2_console_dts_patch "$board_profile"
    apply_uart2_fiq_kernel_patch "$board_profile" "$boot_medium"
    apply_hwrng_crypto_kernel_patch "$board_profile" "$boot_medium"
    apply_crypto_dts_patch "$board_profile"

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

    print_step "Applying SeedSigner Configuration"
    if [[ -f "/build/configs/luckfox_pico_defconfig" ]]; then
        cp -v "/build/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/configs/luckfox_pico_defconfig"
        # Also copy as luckfox_pico_w_defconfig so the Pi board (RK_BUILDROOT_DEFCONFIG=luckfox_pico_w_defconfig)
        # loads our clean config instead of the SDK's WiFi/BT-enabled config
        cp -v "/build/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/configs/luckfox_pico_w_defconfig"
        cp -v "/build/configs/luckfox_pico_defconfig" "$BUILDROOT_DIR/.config"
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

    print_step "Building U-Boot"
    ./build.sh uboot

    print_step "Building Kernel"
    ./build.sh kernel

    print_step "Building Rootfs"
    ./build.sh rootfs

    print_step "Building Media Support"
    ./build.sh media

    # Keep vendor RkLunch.sh camera bring-up behavior on all builds.
    print_info "Keeping RkLunch.sh rkipc autostart enabled"

    print_step "Building Applications"
    ./build.sh app

    resolve_rootfs_dir

    print_step "Installing SeedSigner Code"
    cp -rv "$SEEDSIGNER_CODE_DIR/src/" "$ROOTFS_DIR/seedsigner"

    # Generate the SeedSigner OS identity + provenance marker. App git data comes
    # from the cloned repo; OS git data is unavailable inside the build container,
    # so it falls back to "unknown" (gen-os-release.sh is mounted at /build by build.sh).
    if [ -f /build/gen-os-release.sh ]; then
        SEEDSIGNER_APP_REPO="$SEEDSIGNER_REPO_URL" \
        SEEDSIGNER_APP_BRANCH="$SEEDSIGNER_BRANCH" \
        SEEDSIGNER_APP_GIT_DIR="$SEEDSIGNER_CODE_DIR" \
          bash /build/gen-os-release.sh "$ROOTFS_DIR/etc/seedsigner-os-release" \
          || print_error "Could not generate seedsigner-os-release"
    fi

    print_step "Cleaning up non-essential files from rootfs"
    # Remove documentation, hardware files, git metadata, and test files
    # These are kept in the repo but shouldn't be in the final image
    rm -rf "$ROOTFS_DIR/seedsigner/../docs" 2>/dev/null || true
    rm -rf "$ROOTFS_DIR/seedsigner/../hardware-kicad" 2>/dev/null || true
    rm -rf "$ROOTFS_DIR/seedsigner/../img" 2>/dev/null || true
    rm -rf "$ROOTFS_DIR/seedsigner/../test_suite" 2>/dev/null || true
    rm -rf "$ROOTFS_DIR/seedsigner/../.git" 2>/dev/null || true
    rm -f "$ROOTFS_DIR/seedsigner/../.gitignore" 2>/dev/null || true
    rm -f "$ROOTFS_DIR/seedsigner/../.gitmodules" 2>/dev/null || true
    rm -f "$ROOTFS_DIR/seedsigner/../README.md" 2>/dev/null || true
    print_success "Cleaned up non-essential files"

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
    if [[ -f "/build/files/rk-reboot" ]]; then
        cp -v "/build/files/rk-reboot" "$ROOTFS_DIR/usr/bin/rk-reboot"
        chmod +x "$ROOTFS_DIR/usr/bin/rk-reboot"
    fi
    [[ -f "/build/files/S02fsck" ]] && cp -v "/build/files/S02fsck" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S10mdev" ]] && cp -v "/build/files/S10mdev" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S60pcscd" ]] && cp -v "/build/files/S60pcscd" "$ROOTFS_DIR/etc/init.d/"
    [[ -f "/build/files/S99seedsigner" ]] && cp -v "/build/files/S99seedsigner" "$ROOTFS_DIR/etc/init.d/"
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

    print_step "Packaging Firmware"
    ./build.sh firmware
    debug_uart_bootargs_outputs

    cd "$LUCKFOX_SDK_DIR/output/image"

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    export LAST_PROFILE_BUILD_TS="$ts"
    if [[ "$board_profile" == "mini" ]]; then
        export LAST_MINI_BUILD_TS="$ts"
    elif [[ "$board_profile" == "max" ]]; then
        export LAST_MAX_BUILD_TS="$ts"
    elif [[ "$board_profile" == "pi" ]]; then
        export LAST_PI_BUILD_TS="$ts"
    fi

    if [[ "$boot_medium" == "sd" ]]; then
        print_step "Creating Final SD Image (${board_profile})"

        local sd_image="seedsigner-luckfox-pico-${board_profile}-sd-${ts}.img"

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
        create_emmc_bundle "$board_profile" "$ts"
    fi

    if [[ "$include_nand" == "true" ]]; then
        print_step "Packaging NAND artifacts (${board_profile})"
        create_nand_image_artifacts "$board_profile" "$ts" "$boot_medium"
        export_official_nand_image_dir "$board_profile" "$ts"
    fi

    cd "$LUCKFOX_SDK_DIR"
}

run_automated_build() {
    local build_nand_image="${1:-false}"
    local build_sd_image="${2:-true}"

    print_step "Starting Automated SeedSigner Build"

    print_info "Build Configuration:"
    echo "   CPU Cores Available: $(nproc)"
    echo "   Build Jobs: $BUILD_JOBS"
    echo "   MAKEFLAGS: $MAKEFLAGS"
    echo "   Build Directory: $BUILD_DIR"
    echo "   Output Directory: $OUTPUT_DIR"

    clone_repositories
    apply_sdk_patches
    validate_environment
    setup_sdk_environment

    mkdir -p "$OUTPUT_DIR"

    cd "$LUCKFOX_SDK_DIR"

    if [[ "$build_sd_image" == "true" ]]; then
        if [[ "$BUILD_MODEL" == "mini" || "$BUILD_MODEL" == "both" ]]; then
            build_profile_artifacts "mini" "sd" "false"
        fi
        if [[ "$BUILD_MODEL" == "max" || "$BUILD_MODEL" == "both" ]]; then
            build_profile_artifacts "max" "sd" "false"
        fi
    fi

    # Pico Pi only supports eMMC boot medium.
    if [[ "$BUILD_MODEL" == "pi" ]]; then
        print_step "Generating eMMC Output (pi, official flow)"
        build_profile_artifacts "pi" "emmc" "false"
    fi

    # Build NAND/flash bundles using official SPI_NAND build flow.
    if [[ "$build_nand_image" == "true" ]]; then
        if [[ "$BUILD_MODEL" == "mini" || "$BUILD_MODEL" == "both" ]]; then
            print_step "Generating NAND-Oriented Output (mini, official flow)"
            build_profile_artifacts "mini" "nand" "true"
        fi

        if [[ "$BUILD_MODEL" == "max" || "$BUILD_MODEL" == "both" ]]; then
            print_step "Generating NAND-Oriented Output (max, official flow)"
            build_profile_artifacts "max" "nand" "true"
        fi
    fi

    print_success "Build Complete!"
    echo ""
    echo "Build artifacts:"
    ls -la "$OUTPUT_DIR/"
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

# Main entry point
main() {
    local mode="${1:-auto}"
    
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
