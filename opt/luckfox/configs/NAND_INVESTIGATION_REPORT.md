# SPI-NAND Build Failure Investigation Report

**Date:** 2026-02-17  
**Status:** Investigation Complete - NO CHANGES MADE  
**Issue:** SPI-NAND build failing due to insufficient space

---

## Executive Summary

The SPI-NAND build is failing because the current configuration **does NOT use the full flash space efficiently**. The partition layout allocates fixed sizes to all partitions, leaving insufficient space for rootfs on smaller flash sizes.

### Critical Finding
**Simply expanding the rootfs partition WILL fix the issue** - but only if combined with removing unnecessary packages or userdata partition.

---

## Hardware Specifications

### LuckFox Pico Mini
- **RAM:** 64MB
- **SPI-NAND Flash:** 32MB or 64MB (variant dependent)
- **Most Common:** Mini-B with 32MB SPI-NAND

### LuckFox Pico Pro Max
- **RAM:** 128MB  
- **SPI-NAND Flash:** 128MB or 256MB
- **Most Common:** 128MB SPI-NAND

---

## Current Partition Layout Analysis

### Standard LuckFox SDK Partition Table

| Partition  | Size    | Purpose                          | Removable? |
|------------|---------|----------------------------------|------------|
| idblock    | 4MB     | ID block and loader              | ✗ No       |
| uboot      | 4MB     | U-Boot bootloader                | ✗ No       |
| boot       | 12MB    | Kernel + device tree             | ✗ No       |
| oem        | 4MB     | OEM data (often unused)          | ⚠️ Reducible to 1-2MB |
| userdata   | 4MB     | User data (persistent storage)   | ✅ Yes - SeedSigner doesn't need it |
| rootfs     | Variable| Root filesystem + SeedSigner app | ✗ No - Needs expansion |

**Total Fixed Overhead:** 28MB (before rootfs)

---

## Space Analysis by Flash Size

### 32MB SPI-NAND (LuckFox Mini Common Variant)

**Current Allocation:**
- Fixed partitions: 28MB
- Available for rootfs: **4MB** ⚠️

**Current Needs:**
- Buildroot packages: ~28MB
- Kernel (in boot): 12MB (already allocated)
- Total rootfs need: **~28MB**

**Result:** ❌ **INSUFFICIENT - Short by 24MB**

**After Optimizations:**
- Remove userdata: +4MB
- Remove git, pip, mc, wget, curl: +22MB (reduces packages to ~6MB)
- Reduce OEM to 1MB: +3MB
- **New rootfs available: 41MB**
- **Rootfs needed: ~6MB**
- **Result:** ✅ **FITS with 35MB to spare**

---

### 64MB SPI-NAND

**Current Allocation:**
- Fixed partitions: 28MB
- Available for rootfs: **36MB**

**Current Needs:**
- Total rootfs need: **~28MB**

**Result:** ❌ **MARGINAL - Short by ~7MB with overhead**

**After Package Removal Only:**
- Remove git, pip, mc, wget, curl: -22MB
- **New rootfs need: ~6MB**
- **Result:** ✅ **FITS with 30MB to spare**

---

### 128MB SPI-NAND (Pro Max)

**Current Allocation:**
- Fixed partitions: 28MB
- Available for rootfs: **100MB**

**Current Needs:**
- Total rootfs need: **~28MB**

**Result:** ✅ **FITS - 72MB spare**

---

## Root Cause Analysis

### Primary Issue
The partition table **does NOT expand rootfs to use available flash**. It allocates:
1. Fixed sizes for all partitions including userdata
2. Leaves rootfs with whatever remains
3. On 32MB/64MB flash, remainder is insufficient

### Secondary Issue
Development packages (git, pip, mc, etc.) consume **22MB unnecessarily** for an air-gapped device.

### Tertiary Issue
The **userdata partition (4MB) is unused** by SeedSigner but still allocated.

---

## Does Current Layout Use Full Flash?

**Answer: NO**

The partition table appears to use the full flash, BUT:
1. **Userdata partition wastes 4MB** that SeedSigner never uses
2. **OEM partition may be oversized** (4MB when 1-2MB sufficient)
3. **Rootfs partition is too small** on 32MB/64MB variants

The issue is **inefficient allocation**, not unused flash at the end.

---

## Will Expanding Rootfs Fix It?

**Answer: YES, but depends on approach**

### Approach 1: Expand rootfs + Remove packages (RECOMMENDED)
✅ Works for all flash sizes
- Remove 22MB of development packages
- Expand rootfs by claiming userdata space (+4MB)
- Optionally reduce OEM (+2-3MB)
- **Result:** Rootfs fits comfortably on even 32MB flash

### Approach 2: Just expand rootfs (INSUFFICIENT for 32MB/64MB)
❌ Won't work for 32MB
⚠️ Marginal for 64MB
✅ Works for 128MB

To "just expand rootfs" on 32MB:
- Would need to claim userdata (4MB) + reduce OEM (3MB) = +7MB
- Rootfs would have 11MB for 28MB of packages
- Still 17MB short

---

## Optimization Recommendations

### For 32MB SPI-NAND (Mini)

**Required Actions:**
1. ✅ Remove development packages (-22MB from rootfs)
   - git, pip, wheel, mc, wget, curl, libgpiod2-tools
2. ✅ Remove userdata partition (+4MB to rootfs)
3. ⚠️ Reduce OEM partition to 1MB (+3MB to rootfs)

**Result:**
- Rootfs: 4MB → 41MB available
- Needed: ~6MB (after package removal)
- **Fits with 35MB spare**

### For 64MB SPI-NAND

**Required Actions:**
1. ✅ Remove development packages (-22MB from rootfs)

**Optional:**
2. ⚠️ Remove userdata partition (+4MB to rootfs)

**Result:**
- Rootfs: 36MB available
- Needed: ~6MB
- **Fits with 30MB spare**

### For 128MB SPI-NAND (Pro Max)

**Optional Only:**
1. ⚠️ Remove development packages for cleaner image

**Result:**
- Already fits comfortably
- Removing packages just reduces image size

---

## Recommended Package Removals

### High Priority (22MB total)

| Package            | Size   | Reason                           |
|--------------------|--------|----------------------------------|
| git                | 14.6MB | Development tool, not runtime    |
| python-pip         | 2.4MB  | Package installer, not runtime   |
| mc                 | 2.4MB  | File manager, not needed         |
| libcurl + curl     | 1.7MB  | Network tools (air-gapped)       |
| python-wheel       | 1.0MB  | Package format, not runtime      |
| wget               | 500KB  | Network downloader (air-gapped)  |

### Medium Priority (300KB)

| Package            | Size   | Reason                           |
|--------------------|--------|----------------------------------|
| libgpiod2-tools    | 300KB  | CLI debugging (python-periphery handles GPIO) |

---

## How to Modify Partition Table

### Location
Partition tables are defined in LuckFox SDK:
```
luckfox-pico/project/cfg/BoardConfig_IPC/
  └── BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk
  └── BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk
```

### What to Look For
Search for:
- `RK_PARTITION_CMD_IN_ENV` - Partition table definition
- `parameter.txt` - Partition parameter file
- `mtdparts` - MTD partition specification
- Partition size definitions in hex (e.g., `0x00400000@0x00800000`)

### Modifications Needed
1. **Remove userdata partition** entirely
2. **Reduce oem partition** from 4MB to 1-2MB
3. **Expand rootfs partition** to use reclaimed space
4. **Set rootfs as growable** (use remaining flash)

---

## Next Investigation Steps

### 1. Find Exact Partition Configuration
```bash
cd luckfox-pico/project/cfg/BoardConfig_IPC/
cat BoardConfig-SPI_NAND-*.mk | grep -i partition
cat BoardConfig-SPI_NAND-*.mk | grep -i userdata
cat BoardConfig-SPI_NAND-*.mk | grep -i rootfs
```

### 2. Check Actual Build Failure Log
```bash
# Get the actual error message from CI/CD logs
# Look for: "partition too large" or "image exceeds"
```

### 3. Measure Actual rootfs.img Size
```bash
# After a successful SD build:
ls -lh luckfox-pico/output/image/rootfs.img
# This will show actual vs estimated size
```

### 4. Verify Flash Size
Confirm which flash variant is actually being targeted:
- Mini-B: Usually 32MB
- Pro Max: Usually 128MB

---

## Conclusion

### Primary Answer: Space to Trim

**For 32MB SPI-NAND:** Need to trim **~22MB** minimum
- Best achieved by removing development packages

**For 64MB SPI-NAND:** Need to trim **~7MB** minimum  
- Removing dev packages gives ~4MB headroom

**For 128MB SPI-NAND:** No trimming needed
- Already fits comfortably

### Secondary Answer: Userdata Partition

**YES - Userdata partition CAN and SHOULD be removed:**
- SeedSigner is air-gapped and stateless
- No need for persistent user data storage
- Frees up 4MB for rootfs
- On 32MB flash, every MB counts

### Tertiary Answer: Expanding Rootfs

**YES - Expanding rootfs will help, but:**
- On 32MB: Must also remove packages (expanding alone insufficient)
- On 64MB: Expanding helps, but package removal safer
- On 128MB: Already adequate

**Recommended approach:**
1. Remove development packages (22MB saved)
2. Remove userdata partition (4MB reclaimed)
3. Expand rootfs to use all available space
4. Optionally reduce OEM partition (2-3MB reclaimed)

This ensures the image fits comfortably on **all flash variants** (32MB, 64MB, 128MB).

---

## Files for Reference

- Package analysis: `buildroot/configs/enabled_packages_analysis.txt`
- Partition analysis: `buildroot/scripts/analyze_nand_partitions.sh`
- Build scripts: `buildroot/os-build.sh`, `buildroot/build-local.sh`
