# LuckFox SDK Patches for SeedSigner

This directory contains patches that are automatically applied to the LuckFox Pico SDK during the build process to optimize it for SeedSigner.

## Patches

### 001-optimize-mini-spi-nand-partitions.patch

**Target:** `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk`

**Purpose:** Optimize SPI-NAND partition layout for Mini hardware (128MB flash)

**Changes:**
- **OEM partition:** 30MB → 24MB (saves 6MB)
  - Default allocates 30MB for manufacturer-specific files
  - SeedSigner OEM usage is 16.4MB, provides 3.6MB headroom
  
- **Userdata partition:** 6MB → Removed (saves 6MB)
  - Default allocates persistent user data storage
  - SeedSigner is air-gapped and stateless - no user data needed
  
- **Rootfs partition:** 85MB → 99MB (adds 14MB)
  - Original allocation was too small for SeedSigner packages (~93MB needed)
  - New size provides ~4MB headroom for future growth

**Result:**
- Build succeeds (was failing with "max_leb_cnt too low" error)
- Efficient use of 128MB flash
- No wasted space on unused partitions

### 002-optimize-max-spi-nand-partitions.patch

**Target:** `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk`

**Purpose:** Apply same optimization to Max hardware for consistency

**Changes:** Identical to Mini patch

**Rationale:**
- Max has 128MB or 256MB flash, so space isn't critical
- Apply same optimization for consistency across builds
- Simplifies maintenance and documentation

## Partition Layout

### Before Patches (Default)

```
Total: 128MB SPI-NAND
├─ env:       256KB  @ 0x0
├─ idblock:   256KB  @ 0x40000
├─ uboot:     512KB  @ 0x80000
├─ boot:      4MB    @ 0x100000
├─ oem:       30MB   @ 0x500000    ← OVERSIZED
├─ userdata:  6MB    @ 0x2300000   ← UNUSED
└─ rootfs:    85MB   @ 0x2900000   ← TOO SMALL
```

**Issue:** Rootfs needs 93MB but only has 85MB allocated  
**Result:** Build fails with "max_leb_cnt too low (726 needed, 701 available)"

### After Patches (Optimized)

```
Total: 128MB SPI-NAND
├─ env:       256KB  @ 0x0
├─ idblock:   256KB  @ 0x40000
├─ uboot:     512KB  @ 0x80000
├─ boot:      4MB    @ 0x100000
├─ oem:       8MB    @ 0x500000    ← REDUCED
├─ rootfs:    115MB  @ 0xD00000    ← EXPANDED
```

**Result:** 
- Rootfs has 115MB (22MB headroom)
- Build succeeds
- Efficient flash usage

## How Patches Are Applied

These patches are automatically applied by the build scripts:

1. **GitHub Actions** (`.github/workflows/build.yml`):
   - After cloning LuckFox SDK
   - Before configuring board
   - Step: "Apply SeedSigner SDK patches"

2. **Local Docker Build** (`buildroot/os-build.sh`):
   - In `clone_repositories()` function
   - After cloning SDK, before any builds

3. **Alternative Build** (`buildroot/build-local.sh`):
   - In `clone_repositories()` function
   - Same timing as os-build.sh

## Patch Application Process

```bash
# The build script runs:
cd luckfox-pico

# Check if patches already applied (idempotent)
if ! grep -q "Optimized partition table for SeedSigner" \
     project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk 2>/dev/null; then
  
  # Apply Mini patch
  patch -p1 < ../seedsigner-os/opt/luckfox/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch
  
  # Apply Max patch
  patch -p1 < ../seedsigner-os/opt/luckfox/patches/luckfox-sdk/002-optimize-max-spi-nand-partitions.patch
  
  echo "✓ SPI-NAND partition optimization patches applied"
else
  echo "✓ SPI-NAND patches already applied"
fi
```

## Creating New Patches

If you need to modify the SDK in other ways:

1. Make changes in your local SDK clone
2. Generate patch:
   ```bash
   cd luckfox-pico
   git diff > ../new-patch.patch
   ```
3. Copy patch to `buildroot/patches/luckfox-sdk/`
4. Update patch application function in build scripts

## Reverting Patches

To build without patches (use SDK defaults):

```bash
cd luckfox-pico
git checkout -- project/cfg/BoardConfig_IPC/
```

## References

- Root cause analysis: `buildroot/configs/MINI_NAND_FIX.md`
- Failed build: https://github.com/3rdIteration/seedsigner-luckfox-pico/actions/runs/22099146285
- UBIFS documentation: https://www.kernel.org/doc/html/latest/filesystems/ubifs.html
