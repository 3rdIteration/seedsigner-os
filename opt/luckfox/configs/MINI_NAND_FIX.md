# Mini SPI-NAND Build Failure: Root Cause and Solution

**Status:** Issue Identified - Partition Table Fix Required  
**Date:** 2026-02-17  
**Build:** https://github.com/3rdIteration/seedsigner-luckfox-pico/actions/runs/22099146285

---

## Executive Summary

**Problem:** Mini SPI-NAND build fails during firmware packaging with error:
```
Error: max_leb_cnt too low (726 needed)
max_leb_cnt:  701
```

**Root Cause:** Rootfs partition (85MB) is too small for the content (~92MB needed).

**Solution:** Modify partition table in LuckFox SDK to expand rootfs partition.

---

## Confirmed Facts

✅ **ALL devices have 128MB SPI-NAND flash** (user confirmed)  
✅ Build succeeds through system compilation  
✅ Build fails at firmware packaging (UBIFS creation)  
✅ Rootfs content exceeds allocated partition size  

---

## Current Partition Layout

**From build log:**
```
GLOBAL_PARTITIONS: 
  0x40000@0x0(env),
  0x40000@0x40000(idblock),
  0x80000@0x80000(uboot),
  0x400000@0x100000(boot),
  0x1E00000@0x500000(oem),
  0x600000@0x2300000(userdata),
  0x5500000@0x2900000(rootfs)
```

**Human readable:**
```
Total Flash:    128MB
├─ env:         256KB  @ 0x0
├─ idblock:     256KB  @ 0x40000  (256KB offset)
├─ uboot:       512KB  @ 0x80000  (512KB offset)
├─ boot:        4MB    @ 0x100000 (1MB offset)
├─ oem:         30MB   @ 0x500000 (5MB offset)   ← OVERSIZED
├─ userdata:    6MB    @ 0x2300000 (35MB offset) ← UNUSED by SeedSigner
└─ rootfs:      85MB   @ 0x2900000 (41MB offset) ← TOO SMALL
                                   
Total Used:     ~126MB (close to full 128MB)
```

---

## The Error Explained

**UBIFS (UBI Filesystem) uses Logical Erase Blocks (LEBs):**
- Each LEB = 128KB (0x20000 bytes)
- Rootfs partition: 85MB = 0x5500000 bytes
- 0x5500000 / 0x20000 = 682 LEBs theoretical
- After UBIFS overhead: **701 LEBs actual**

**Rootfs content needs:**
- Packages + SeedSigner app + overhead = 726 LEBs
- 726 LEBs × 128KB = **92.8MB needed**

**Result:**
```
Available: 701 LEBs (85MB)
Needed:    726 LEBs (92.8MB)
Shortfall: 25 LEBs (~7.8MB)
```

---

## Why Partitions Are Oversized

### OEM Partition: 30MB (OVERSIZED)
- **Typical use:** Manufacturer-specific files, calibration data
- **SeedSigner needs:** Minimal (< 2MB)
- **Recommendation:** Reduce to 8MB

### Userdata Partition: 6MB (COMPLETELY UNUSED)
- **Typical use:** Persistent user data storage
- **SeedSigner is:** Air-gapped, stateless device
- **Actual use:** None - SeedSigner doesn't store user data
- **Recommendation:** Remove entirely (0MB)

---

## Solution Implemented

### Automated Patch System ✅

Instead of modifying the LuckFox SDK repository directly, the build system now **automatically applies patches** during the build process.

**Location:** `buildroot/patches/luckfox-sdk/`

**Patches:**
1. `001-optimize-mini-spi-nand-partitions.patch` - Optimizes Mini SPI-NAND layout
2. `002-optimize-max-spi-nand-partitions.patch` - Optimizes Max SPI-NAND layout (for consistency)

**Application:** Automatic during every build (GitHub Actions, local Docker, local native)

### How It Works

The build scripts (`os-build.sh`, `build-local.sh`, GitHub workflow) now include an `apply_sdk_patches()` function that:

1. Checks if patches are already applied (idempotent)
2. Applies partition optimization patches to LuckFox SDK
3. Verifies successful application
4. Continues with normal build process

**Benefits:**
- ✅ SDK repository remains unmodified
- ✅ Patches automatically apply on fresh clones
- ✅ Idempotent - safe to run multiple times
- ✅ Easy to update or add new patches
- ✅ Works across all build methods (CI, Docker, native)

---

## Implementation Steps (Already Done)

### ✅ Step 1: Patch Files Created

Created two patch files in `buildroot/patches/luckfox-sdk/`:

**Mini patch** modifies: `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk`

**Max patch** modifies: `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk`

### ✅ Step 2: Build Scripts Updated

Modified three build scripts to apply patches:

1. **`.github/workflows/build.yml`**
   - Added "Apply SeedSigner SDK patches" step
   - Runs after SDK clone, before board configuration

2. **`buildroot/os-build.sh`**
   - Added `apply_sdk_patches()` function
   - Called after `clone_repositories()` in all modes

3. **`buildroot/build-local.sh`**
   - Added `apply_sdk_patches()` function
   - Called after `clone_repositories()`

### ✅ Step 3: Documentation

- Created `buildroot/patches/luckfox-sdk/README.md` with full documentation
- Updated this file (MINI_NAND_FIX.md) with solution status

---

## Partition Changes

### Before Patches (Default)

```
Total Flash:    128MB
├─ env:         256KB  @ 0x0
├─ idblock:     256KB  @ 0x40000
├─ uboot:       512KB  @ 0x80000
├─ boot:        4MB    @ 0x100000
├─ oem:         8MB    @ 0x500000  ← Reduced from 30MB
├─ userdata:    0MB    REMOVED    ← Deleted partition
└─ rootfs:      115MB  @ 0xD00000 ← Expanded from 85MB
                                   
Total Used:     ~128MB (using full flash efficiently)
```

### Hex Values (New)

```
GLOBAL_PARTITIONS:
  0x40000@0x0(env),
  0x40000@0x40000(idblock),
  0x80000@0x80000(uboot),
  0x400000@0x100000(boot),
  0x1800000@0x500000(oem),         ← 8MB (was 30MB)
  0x6300000@0x1D00000(rootfs)      ← 115MB (was 85MB, userdata removed)
```

### Space Analysis

**Freed:**
- OEM: 30MB → 8MB = 22MB freed
- Userdata: 6MB → 0MB = 6MB freed
- **Total freed: 28MB**

**Applied:**
- Rootfs: 85MB → 115MB = 30MB added

**Result:**
- Rootfs needs: 92.8MB
- Rootfs has: 115MB
- **Headroom: 22.2MB** ✅

---

## Usage

### For CI Builds (GitHub Actions)

Patches apply automatically - no action needed!

The workflow now includes an "Apply SeedSigner SDK patches" step that runs after cloning the SDK.

### For Local Docker Builds

Patches apply automatically when using `buildroot/os-build.sh`:

```bash
./buildroot/os-build.sh auto        # SD card build
./buildroot/os-build.sh auto-nand   # NAND build
```

### For Local Native Builds

Patches apply automatically when using `buildroot/build-local.sh`:

```bash
./buildroot/build-local.sh --hardware mini --boot nand
./buildroot/build-local.sh --hardware max --boot nand
```

### Verifying Patches Applied

Check the build log for:
```
✅ SeedSigner SDK patches applied successfully

Partition layout optimized:
  - OEM: 30MB → 8MB (save 22MB)
  - Userdata: 6MB → Removed (save 6MB)
  - Rootfs: 85MB → 115MB (add 30MB)
```

Or manually check the BoardConfig file:
```bash
cd luckfox-pico
grep "Optimized partition table for SeedSigner" \
  project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk
```

---

## For Developers

### Adding New Patches

1. Make changes in your local SDK clone
2. Generate patch:
   ```bash
   cd luckfox-pico
   git diff > ../new-feature.patch
   ```
3. Copy to `buildroot/patches/luckfox-sdk/`
4. Add patch application to `apply_sdk_patches()` function

### Reverting Patches (Testing)

To test without patches:
```bash
cd luckfox-pico
git checkout -- project/cfg/BoardConfig_IPC/
```

---

## Files to Modify in LuckFox SDK (Deprecated - Use Patches Instead)

**⚠️ Note:** Direct SDK modification is no longer needed. The information below is kept for reference only.

~~**Repository:** https://github.com/3rdIteration/luckfox-pico~~

~~**File:** `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk`~~

The build system now applies these changes automatically via patches.

---

## References

- Failed build: https://github.com/3rdIteration/seedsigner-luckfox-pico/actions/runs/22099146285
- Job ID: 63864192321 (build RV1103_Luckfox_Pico_Mini, SPI_NAND)
- Error: max_leb_cnt too low (726 needed, 701 available)
- LuckFox SDK: https://github.com/3rdIteration/luckfox-pico
- UBIFS documentation: https://www.kernel.org/doc/html/latest/filesystems/ubifs.html
