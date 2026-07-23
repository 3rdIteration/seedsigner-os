#!/bin/bash
# SPI-NAND Partition Analysis Script
# Investigates partition layout and space requirements

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}SPI-NAND Partition Layout Analysis${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Typical LuckFox SPI-NAND flash sizes
echo -e "${YELLOW}=== Known Hardware Specifications ===${NC}"
echo "LuckFox Pico Mini:"
echo "  - RAM: 64MB"
echo "  - SPI-NAND options: 32MB or 64MB (depending on variant)"
echo "  - Common: 32MB for Mini-B variant"
echo ""
echo "LuckFox Pico Pro Max:"
echo "  - RAM: 128MB"
echo "  - SPI-NAND: Typically 128MB or 256MB"
echo "  - More common: 128MB"
echo ""

# Standard LuckFox partition layout (from SDK documentation)
echo -e "${YELLOW}=== Standard LuckFox SDK Partition Layout ===${NC}"
echo "Typical partition table for SPI-NAND:"
echo ""
echo "Partition      | Typical Size | Description"
echo "---------------|--------------|------------------------------------------"
echo "idblock        | 4MB          | ID block and loader"
echo "uboot          | 4MB          | U-Boot bootloader"
echo "boot           | 10-16MB      | Kernel + device tree"
echo "oem            | 2-8MB        | OEM data (customizable)"
echo "userdata       | 2-8MB        | User data partition (often unused)"
echo "rootfs         | Remaining    | Root filesystem (SeedSigner application)"
echo ""
echo -e "${GREEN}Total overhead (non-rootfs): ~20-40MB${NC}"
echo ""

# Calculate partition sizes for different flash sizes
echo -e "${YELLOW}=== Space Analysis for Different Flash Sizes ===${NC}"
echo ""

calculate_layout() {
    local flash_size_mb=$1
    local flash_name=$2
    
    # Typical fixed partitions
    local idblock=4
    local uboot=4
    local boot=12
    local oem=4
    local userdata=4
    
    local fixed_total=$((idblock + uboot + boot + oem + userdata))
    local rootfs_available=$((flash_size_mb - fixed_total))
    
    echo -e "${BLUE}${flash_name} (${flash_size_mb}MB total):${NC}"
    echo "  Fixed partitions:"
    echo "    idblock:  ${idblock}MB"
    echo "    uboot:    ${uboot}MB"
    echo "    boot:     ${boot}MB"
    echo "    oem:      ${oem}MB"
    echo "    userdata: ${userdata}MB"
    echo "    Total:    ${fixed_total}MB"
    echo ""
    echo "  Available for rootfs: ${rootfs_available}MB"
    echo ""
    
    # Calculate if it fits current package set
    local pkg_size=28  # From our analysis
    local kernel_boot=12
    local overhead=3
    local total_needed=$((pkg_size + kernel_boot + overhead))
    local remaining=$((rootfs_available - total_needed))
    
    if [ $remaining -lt 0 ]; then
        echo -e "  ${RED}⚠ INSUFFICIENT SPACE${NC}"
        echo "    Current packages need: ~${pkg_size}MB"
        echo "    Total with kernel: ~${total_needed}MB"
        echo "    Shortfall: ${remaining}MB"
    else
        echo -e "  ${GREEN}✓ Sufficient space${NC}"
        echo "    Current packages need: ~${pkg_size}MB"
        echo "    Total with kernel: ~${total_needed}MB"
        echo "    Free space: +${remaining}MB"
    fi
    echo ""
}

# Analyze different configurations
calculate_layout 32 "Mini 32MB SPI-NAND"
calculate_layout 64 "Mini 64MB SPI-NAND / Max variant"
calculate_layout 128 "Pro Max 128MB SPI-NAND"

# Recommendations
echo -e "${YELLOW}=== Optimization Recommendations ===${NC}"
echo ""
echo -e "${GREEN}Option 1: Remove userdata partition (saves 4-8MB)${NC}"
echo "  - SeedSigner is air-gapped and stateless"
echo "  - No need for persistent user data storage"
echo "  - Can be done by modifying SDK partition table"
echo "  - Impact: Would provide 4-8MB more for rootfs"
echo ""

echo -e "${GREEN}Option 2: Reduce OEM partition (saves 2-4MB)${NC}"
echo "  - OEM partition often unused or oversized"
echo "  - Can be reduced from 4MB to 1-2MB"
echo "  - Impact: Would provide 2-3MB more for rootfs"
echo ""

echo -e "${GREEN}Option 3: Remove development packages (saves ~22MB)${NC}"
echo "  - Remove: git (14.6MB), pip (2.4MB), mc (2.4MB)"
echo "  - Remove: wget (500KB), curl (1.7MB), wheel (1MB)"
echo "  - Impact: Reduces package footprint from 28MB to ~6MB"
echo ""

echo -e "${GREEN}Option 4: Expand rootfs into unused space${NC}"
echo "  - If partition table reserves space after rootfs"
echo "  - Some SDKs don't allocate full flash to partitions"
echo "  - Check if rootfs can use more of available flash"
echo ""

echo -e "${YELLOW}=== Recommended Strategy ===${NC}"
echo ""
echo "For 32MB Mini SPI-NAND:"
echo "  1. Remove userdata partition (+4-8MB)"
echo "  2. Remove git, pip, mc, wget, curl (+22MB)"
echo "  3. Reduce OEM to 1MB (+3MB)"
echo "  Result: rootfs has 12MB → 41MB (plenty of space)"
echo ""
echo "For 64MB+ SPI-NAND:"
echo "  1. Just remove development packages (+22MB)"
echo "  Result: Likely sufficient without partition changes"
echo ""

echo -e "${YELLOW}=== Next Steps to Investigate ===${NC}"
echo ""
echo "1. Check actual partition table in LuckFox SDK:"
echo "   Look in: luckfox-pico/project/cfg/BoardConfig_IPC/"
echo "   Files: BoardConfig-SPI_NAND-*.mk"
echo "   Search for: RK_PARTITION_CMD_IN_ENV or parameter.txt"
echo ""
echo "2. Check actual rootfs.img size from build:"
echo "   After build: ls -lh luckfox-pico/output/image/rootfs.img"
echo ""
echo "3. Find partition configuration:"
echo "   grep -r \"mtdparts\|CMDLINE\" luckfox-pico/project/"
echo "   grep -r \"userdata\" luckfox-pico/project/ | grep size"
echo ""
echo "4. Check if rootfs partition is undersized:"
echo "   Compare rootfs.img actual size vs allocated partition size"
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Analysis Complete${NC}"
echo -e "${BLUE}========================================${NC}"
