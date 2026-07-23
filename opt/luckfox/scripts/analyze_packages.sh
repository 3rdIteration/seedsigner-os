#!/bin/bash
# Buildroot Package Analyzer
# Extracts enabled packages from defconfig and provides size estimates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFCONFIG="${1:-$SCRIPT_DIR/../configs/luckfox_pico_defconfig}"
OUTPUT_FILE="${2:-$SCRIPT_DIR/../configs/enabled_packages_analysis.txt}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Buildroot Package Analysis${NC}"
echo -e "${BLUE}========================================${NC}\n"

if [[ ! -f "$DEFCONFIG" ]]; then
    echo "Error: defconfig not found at: $DEFCONFIG"
    exit 1
fi

# Package size estimates (approximate, in KB)
declare -A PKG_SIZES=(
    # Network tools
    ["BR2_PACKAGE_WGET"]="500"
    ["BR2_PACKAGE_LIBCURL"]="1500"
    ["BR2_PACKAGE_LIBCURL_CURL"]="200"
    ["BR2_PACKAGE_GIT"]="15000"
    
    # Python development
    ["BR2_PACKAGE_PYTHON_PIP"]="2500"
    ["BR2_PACKAGE_PYTHON_WHEEL"]="1000"
    ["BR2_PACKAGE_PYTHON_SETUPTOOLS"]="1500"
    
    # Admin/file managers
    ["BR2_PACKAGE_MC"]="2500"
    ["BR2_PACKAGE_NANO"]="200"
    ["BR2_PACKAGE_NANO_TINY"]="100"
    
    # System utilities
    ["BR2_PACKAGE_BASH"]="1500"
    ["BR2_PACKAGE_DIALOG"]="300"
    ["BR2_PACKAGE_RNG_TOOLS"]="100"
    
    # Python packages
    ["BR2_PACKAGE_PYTHON3"]="8000"
    ["BR2_PACKAGE_PYTHON_PYCRYPTODOMEX"]="2000"
    ["BR2_PACKAGE_PYTHON_ECDSA"]="500"
    ["BR2_PACKAGE_PYTHON_PYAES"]="100"
    ["BR2_PACKAGE_PYTHON_PYASN1"]="300"
    ["BR2_PACKAGE_PYTHON_MNEMONIC"]="100"
    ["BR2_PACKAGE_PYTHON_SHAMIR_MNEMONIC"]="150"
    ["BR2_PACKAGE_PYTHON_EMBIT"]="500"
    ["BR2_PACKAGE_PYTHON_URTYPES"]="50"
    ["BR2_PACKAGE_PYTHON_PYZBAR"]="100"
    ["BR2_PACKAGE_PYTHON_PILLOW"]="2000"
    ["BR2_PACKAGE_PYTHON_QRCODE"]="200"
    ["BR2_PACKAGE_PYTHON_PYQRCODE"]="100"
    ["BR2_PACKAGE_PYTHON_PERIPHERY"]="50"
    ["BR2_PACKAGE_PYTHON_SMBUS_CFFI"]="100"
    ["BR2_PACKAGE_PYTHON_SPIDEV"]="50"
    
    # Libraries
    ["BR2_PACKAGE_LIBGPIOD2"]="200"
    ["BR2_PACKAGE_LIBGPIOD2_TOOLS"]="300"
    ["BR2_PACKAGE_OPENSSL"]="3000"
    ["BR2_PACKAGE_LIBOPENSSL"]="2500"
    ["BR2_PACKAGE_ZBAR"]="500"
    ["BR2_PACKAGE_LIBV4L"]="400"
    ["BR2_PACKAGE_LIBV4L_UTILS"]="200"
    ["BR2_PACKAGE_FREETYPE"]="800"
    ["BR2_PACKAGE_JPEG"]="500"
    ["BR2_PACKAGE_JPEG_TURBO"]="700"
    ["BR2_PACKAGE_LIBPNG"]="300"
    ["BR2_PACKAGE_ZLIB"]="100"
    
    # Default for unknown packages
    ["DEFAULT"]="50"
)

# Extract enabled packages
echo -e "${GREEN}Extracting enabled packages from defconfig...${NC}\n"

# Create output file
{
    echo "========================================="
    echo "BUILDROOT PACKAGE ANALYSIS"
    echo "========================================="
    echo "Generated: $(date)"
    echo "Defconfig: $DEFCONFIG"
    echo ""
    echo "========================================="
    echo "ENABLED PACKAGES WITH SIZE ESTIMATES"
    echo "========================================="
    echo ""
} > "$OUTPUT_FILE"

# Categories
categories=(
    "PYTHON3:Python Core"
    "PYTHON_:Python Packages"
    "LIB:Libraries"
    "PACKAGE_BASH\|PACKAGE_DIALOG\|PACKAGE_NANO\|PACKAGE_MC\|PACKAGE_GIT\|PACKAGE_WGET\|PACKAGE_RNG:System Utilities"
    "OPENSSL\|CRYPTO:Cryptography"
    "JPEG\|PNG\|TIFF\|FREETYPE\|PILLOW:Graphics/Image"
    "V4L\|CAMERA:Video/Camera"
    "GPIO\|SPI\|I2C\|PERIPHERY:Hardware I/O"
)

total_size=0
total_packages=0

for category_def in "${categories[@]}"; do
    pattern="${category_def%%:*}"
    name="${category_def##*:}"
    
    echo -e "\n${YELLOW}=== $name ===${NC}" | tee -a "$OUTPUT_FILE"
    category_size=0
    category_count=0
    
    while IFS= read -r line; do
        if [[ $line =~ ^(BR2_PACKAGE_[A-Z0-9_]+)=y ]]; then
            pkg="${BASH_REMATCH[1]}"
            
            # Get size estimate
            if [[ -n "${PKG_SIZES[$pkg]}" ]]; then
                size="${PKG_SIZES[$pkg]}"
            else
                size="${PKG_SIZES[DEFAULT]}"
            fi
            
            # Format size
            if (( size >= 1024 )); then
                size_mb=$(awk "BEGIN {printf \"%.1f\", $size/1024}")
                size_str="${size_mb}MB"
            else
                size_str="${size}KB"
            fi
            
            printf "  %-50s %10s\n" "$pkg" "$size_str" | tee -a "$OUTPUT_FILE"
            
            category_size=$((category_size + size))
            category_count=$((category_count + 1))
            total_size=$((total_size + size))
            total_packages=$((total_packages + 1))
        fi
    done < <(grep "^BR2_PACKAGE.*=y" "$DEFCONFIG" | grep -E "$pattern")
    
    if (( category_count > 0 )); then
        if (( category_size >= 1024 )); then
            cat_mb=$(awk "BEGIN {printf \"%.1f\", $category_size/1024}")
            echo -e "${GREEN}  Category Total: $category_count packages, ~${cat_mb}MB${NC}" | tee -a "$OUTPUT_FILE"
        else
            echo -e "${GREEN}  Category Total: $category_count packages, ~${category_size}KB${NC}" | tee -a "$OUTPUT_FILE"
        fi
    fi
done

# Other packages
echo -e "\n${YELLOW}=== Other Packages ===${NC}" | tee -a "$OUTPUT_FILE"
other_size=0
other_count=0

while IFS= read -r line; do
    if [[ $line =~ ^(BR2_PACKAGE_[A-Z0-9_]+)=y ]]; then
        pkg="${BASH_REMATCH[1]}"
        
        # Check if already counted
        already_counted=false
        for category_def in "${categories[@]}"; do
            pattern="${category_def%%:*}"
            if echo "$pkg" | grep -qE "$pattern"; then
                already_counted=true
                break
            fi
        done
        
        if [[ "$already_counted" == "false" ]]; then
            if [[ -n "${PKG_SIZES[$pkg]}" ]]; then
                size="${PKG_SIZES[$pkg]}"
            else
                size="${PKG_SIZES[DEFAULT]}"
            fi
            
            if (( size >= 1024 )); then
                size_mb=$(awk "BEGIN {printf \"%.1f\", $size/1024}")
                size_str="${size_mb}MB"
            else
                size_str="${size}KB"
            fi
            
            printf "  %-50s %10s\n" "$pkg" "$size_str" | tee -a "$OUTPUT_FILE"
            
            other_size=$((other_size + size))
            other_count=$((other_count + 1))
        fi
    fi
done < <(grep "^BR2_PACKAGE.*=y" "$DEFCONFIG")

if (( other_count > 0 )); then
    if (( other_size >= 1024 )); then
        other_mb=$(awk "BEGIN {printf \"%.1f\", $other_size/1024}")
        echo -e "${GREEN}  Other Total: $other_count packages, ~${other_mb}MB${NC}" | tee -a "$OUTPUT_FILE"
    else
        echo -e "${GREEN}  Other Total: $other_count packages, ~${other_size}KB${NC}" | tee -a "$OUTPUT_FILE"
    fi
fi

# Summary
{
    echo ""
    echo "========================================="
    echo "SUMMARY"
    echo "========================================="
    echo ""
} >> "$OUTPUT_FILE"

total_mb=$(awk "BEGIN {printf \"%.1f\", $total_size/1024}")

echo -e "\n${BLUE}========================================${NC}" | tee -a "$OUTPUT_FILE"
echo -e "${BLUE}SUMMARY${NC}" | tee -a "$OUTPUT_FILE"
echo -e "${BLUE}========================================${NC}" | tee -a "$OUTPUT_FILE"
echo -e "${GREEN}Total Packages: $total_packages${NC}" | tee -a "$OUTPUT_FILE"
echo -e "${GREEN}Estimated Size: ~${total_mb}MB (${total_size}KB)${NC}" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"
echo -e "${YELLOW}Note: Sizes are estimates and may vary based on:${NC}" | tee -a "$OUTPUT_FILE"
echo "  - Compilation options" | tee -a "$OUTPUT_FILE"
echo "  - Architecture (ARM)" | tee -a "$OUTPUT_FILE"
echo "  - Library dependencies" | tee -a "$OUTPUT_FILE"
echo "  - Debug symbols (stripped in production)" | tee -a "$OUTPUT_FILE"
echo "" | tee -a "$OUTPUT_FILE"

echo -e "${GREEN}Analysis complete! Report saved to:${NC}"
echo -e "${BLUE}$OUTPUT_FILE${NC}"
