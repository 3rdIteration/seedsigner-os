# Mini SPI-NAND Build Failure Analysis

**Investigation Date:** 2026-02-17  
**Status:** Investigation Only - NO CODE CHANGES  
**Build:** GitHub Actions run #22103339811

## Executive Summary

The Mini SPI-NAND build continues to fail despite partition optimization patches being in place. Investigation reveals the **patches are not being applied** during the build process, leaving the partition at the original 85MB size instead of the required 99MB.

## Build Results

| Hardware | Boot Medium | Result | Notes |
|----------|-------------|---------|-------|
| Mini | SD_CARD | ✅ SUCCESS | No size constraints |
| Mini | SPI_NAND | ❌ FAILURE | Rootfs partition too small |
| Max | SD_CARD | ✅ SUCCESS | No size constraints |
| Max | SPI_NAND | ✅ SUCCESS | Default partition is larger |

## Error Analysis

### The Error
```
Error: max_leb_cnt too low (726 needed)
mkfs.ubifs
    root:         /home/runner/work/seedsigner-luckfox-pico/seedsigner-luckfox-pico/luckfox-pico/output/out/rootfs_uclibc_rv1106/
    min_io_size:  2048
    leb_size:     126976
    max_leb_cnt:  701
    output:       /home/runner/work/seedsigner-luckfox-pico/seedsigner-luckfox-pico/luckfox-pico/output/image/.ubi_cfg/rootfs_2KB_128KB_85MB.ubifs
```

### What This Means

**LEBs (Logical Erase Blocks):**
- Unit of storage in UBIFS filesystem
- Size: 126,976 bytes (124KB per LEB)

**Required Space:**
- Rootfs content needs: 726 LEBs
- Calculation: 726 × 124KB = 88.0MB minimum
- Safe allocation: 92-99MB (with headroom)

**Available Space:**
- Current partition: 701 LEBs
- Calculation: 701 × 124KB = 84.8MB
- **Shortfall: 25 LEBs = 3.1MB** ❌

### Build Log Evidence

From the build logs:
```
[build.sh:info] part_size=85MB
[mkfs_ubi.sh:info] ubifs_maxlebcnt=701
```

This proves the partition is still at the **default 85MB size**, not the patched 99MB.

## Partition Layout Comparison

### Current (Default - Failing)
```makefile
0x40000@0x0(env),                 # 256KB
0x40000@0x40000(idblock),         # 256KB
0x80000@0x80000(uboot),           # 512KB
0x400000@0x100000(boot),          # 4MB
0x1E00000@0x500000(oem),          # 30MB
0x600000@0x2300000(userdata),     # 6MB
0x5500000@0x2900000(rootfs)       # 85MB ← TOO SMALL
```

**Rootfs allocation:**
- Hex: 0x5500000 = 89,128,960 bytes = 85MB
- LEBs: 701 (85MB ÷ 124KB)
- **Result: FAILS** (needs 726 LEBs)

### Expected (After Patches - Should Work)
```makefile
0x40000@0x0(env),                 # 256KB
0x40000@0x40000(idblock),         # 256KB
0x80000@0x80000(uboot),           # 512KB
0x400000@0x100000(boot),          # 4MB
0x1800000@0x500000(oem),          # 24MB
# userdata removed
0x6300000@0x1D00000(rootfs)       # 99MB ← SUFFICIENT
```

**Rootfs allocation:**
- Hex: 0x6300000 = 103,809,024 bytes = 99MB
- LEBs: ~810 (99MB ÷ 124KB)
- **Result: SUCCEEDS** (has 726 needed + 84 headroom) ✅

## Why Patches Didn't Apply

### Patch Application Status

From GitHub Actions logs:
```
Apply SeedSigner SDK patches
  status: completed
  conclusion: success
```

But the partition size is still 85MB, proving patches didn't actually modify the files.

### Possible Causes

1. **File path mismatch**
   - Patch targets wrong file path
   - BoardConfig file moved/renamed in SDK

2. **Marker check false positive**
   - Patch checks for "SeedSigner optimized" marker
   - Maybe marker exists but actual changes don't

3. **Silent patch failure**
   - Patch command fails but doesn't exit with error
   - Need better error handling

4. **Wrong patch format**
   - Patch syntax error
   - Context lines don't match

### Verification Needed

To debug patch application:

```bash
# Check if file exists
ls -l luckfox-pico/project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk

# Check if marker exists
grep "SeedSigner optimized" luckfox-pico/project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk

# Check actual partition value
grep "RK_PARTITION_CMD_IN_ENV" luckfox-pico/project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk

# Try manual patch
cd luckfox-pico
patch -p1 < ../buildroot/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch
```

## Why Max SPI-NAND Succeeds

The Max build uses a different BoardConfig file with inherently larger partition allocations:
- Different default partition layout
- More space allocated to rootfs by default
- Doesn't hit the size limit with current packages

## Space Requirements Breakdown

### Minimum Requirements
- Rootfs content: 726 LEBs × 124KB = **88.0MB**
- UBIFS overhead: ~4MB
- **Total minimum: 92MB**

### Safe Allocation
- Recommended: **99MB** (as specified in patches)
- Provides: 810 LEBs
- Headroom: 84 LEBs = 10.4MB extra
- Safety margin: 11.8% above minimum

### Current vs Required

| Metric | Current (Failing) | Required (Min) | Patched (Safe) |
|--------|------------------|----------------|----------------|
| Raw size | 85MB | 92MB | 99MB |
| LEBs available | 701 | 742 | 810 |
| LEBs needed | - | 726 | 726 |
| Headroom | -25 LEBs ❌ | 16 LEBs ⚠️ | 84 LEBs ✅ |

## Recommendation

The **patches are correctly designed** with proper calculations:
- OEM: 24MB (sufficient for 16.4MB usage)
- Userdata: Removed (not needed)
- Rootfs: 99MB (sufficient for 88MB content)

**Problem:** Patches aren't being applied during build.

**Solution:** Fix patch application mechanism in next session.

## Next Steps (When Ready)

1. **Debug patch application**
   - Add verbose logging to `apply_sdk_patches()`
   - Print file paths being patched
   - Show patch command output
   - Verify files actually changed

2. **Test patches manually**
   - Clone SDK locally
   - Apply patches with verbose output
   - Confirm changes take effect
   - Check for any patch errors

3. **Alternative approaches**
   - Direct file modification in build script
   - Use sed/awk instead of patch files
   - Create BoardConfig overlay
   - Fork SDK and maintain custom configs

4. **Validate fix**
   - Trigger build after fixing patch application
   - Verify partition size = 99MB in logs
   - Confirm build succeeds
   - Test on actual hardware

## References

- Failed build: https://github.com/3rdIteration/seedsigner-luckfox-pico/actions/runs/22103339811
- Job ID: 63879716873 (Mini SPI_NAND)
- Patch file: `buildroot/patches/luckfox-sdk/001-optimize-mini-spi-nand-partitions.patch`
- Target file: `project/cfg/BoardConfig_IPC/BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk`
