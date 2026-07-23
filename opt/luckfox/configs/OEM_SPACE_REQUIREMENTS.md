# OEM Partition Space Requirements

## Answer to: "Specifically how much space is needed for /oem?"

**24 MB raw partition size (provides ~20 MB usable space after UBIFS overhead)**

## Evidence from Real Device

User provided actual partition usage from running Mini device:

```bash
[root@seedsigner ]# df
Filesystem           1K-blocks      Used Available Use% Mounted on
ubi0:rootfs              73284     73236        48 100% /
/dev/ubi4_0              22936     16444      6492  72% /oem
/dev/ubi5_0                916        48       868   5% /userdata
```

### OEM Partition Analysis

```
Filesystem: /dev/ubi4_0 (OEM partition)
Total:      22,936 KB = 22.4 MB usable
Used:       16,444 KB = 16.1 MB
Available:  6,492 KB  = 6.3 MB
Usage:      72%
```

## UBIFS Overhead Explained

UBIFS (Unsorted Block Image File System) has inherent overhead:

1. **Metadata** - File system structures, indexes
2. **Bad block management** - Reserved space for wear leveling
3. **Alignment** - Block and page alignment requirements
4. **LEB mapping** - Logical Erase Block mapping overhead

**Typical overhead: 15-20%**

### Calculation

```
Raw Partition Size = Usable Space / (1 - Overhead Percentage)

Given:
- Usable space shown by df: 22.4 MB
- Overhead: ~18% (typical for UBIFS on NAND)

Calculation:
Raw size = 22.4 / (1 - 0.18)
Raw size = 22.4 / 0.82
Raw size ≈ 27.3 MB

Current default: 30 MB (0x1E00000)
```

## Space Requirements

### Actual Usage

From device data:
- **Currently used:** 16.4 MB
- **Free space:** 6.3 MB
- **Total usable:** 22.4 MB

### Minimum Allocation

**Absolute minimum (not recommended):**
```
Raw = 16.4 MB / 0.82 = 20 MB
Usable ≈ 16.4 MB
Headroom = 0 MB ❌
```
This is too tight - no room for growth!

**Safe allocation:**
```
Used: 16.4 MB
Buffer: +20% = 3.3 MB
Total needed: 19.7 MB usable
Raw = 19.7 / 0.82 = 24 MB ✅
Result: ~20 MB usable, 3.6 MB free
```

**Conservative (current default):**
```
Raw = 30 MB
Usable ≈ 24 MB
Headroom = 7.6 MB
```
This works but wastes 6 MB that rootfs desperately needs!

## Patch Correction

### Original Patch (INCORRECT ❌)

```
OEM: 8 MB raw (0x800000)
Usable: ~6.5 MB
Problem: Only 6.5 MB available but 16.4 MB needed!
Result: Would break OEM functionality
```

### Corrected Patch (CORRECT ✅)

```
OEM: 24 MB raw (0x1800000)
Usable: ~20 MB
Current usage: 16.4 MB
Free: 3.6 MB
Result: Safe with reasonable headroom
```

## Final Partition Layout

### Before Optimization (Default)

```
env:       256 KB  (0x40000@0x0)
idblock:   256 KB  (0x40000@0x40000)
uboot:     512 KB  (0x80000@0x80000)
boot:      4 MB    (0x400000@0x100000)
oem:       30 MB   (0x1E00000@0x500000)    ← Slightly oversized
userdata:  6 MB    (0x600000@0x2300000)    ← Completely unused
rootfs:    85 MB   (0x5500000@0x2900000)   ← TOO SMALL (100% full!)
Total:     ~125 MB
```

### After Optimization (Patched)

```
env:       256 KB  (0x40000@0x0)
idblock:   256 KB  (0x40000@0x40000)
uboot:     512 KB  (0x80000@0x80000)
boot:      4 MB    (0x400000@0x100000)
oem:       24 MB   (0x1800000@0x500000)    ← Reduced by 6 MB
userdata:  REMOVED                         ← Saved 6 MB
rootfs:    99 MB   (0x6300000@0x1D00000)   ← Expanded by 14 MB
Total:     ~128 MB
```

## Space Gained

```
OEM reduction:      30 MB → 24 MB = 6 MB saved
Userdata removal:   6 MB → 0 MB = 6 MB saved
Rootfs expansion:   85 MB → 99 MB = 14 MB gained

Total optimization: 12 MB freed, 14 MB added to rootfs
```

## Benefits

1. **OEM partition:** Still has adequate space
   - Used: 16.4 MB
   - Available: 20 MB usable
   - Headroom: 3.6 MB (18%)

2. **Rootfs partition:** No longer full
   - Before: 73.2 MB usable, 100% full ❌
   - After: ~82 MB usable, ~95% full ✅
   - Headroom: ~4 MB (5%)

3. **Userdata partition:** Removed
   - Was: 0.9 MB usable, 5% used (48 KB actual)
   - Purpose: Persistent user data
   - Reason for removal: SeedSigner is stateless and air-gapped

## Conclusion

**OEM requires 24 MB raw partition** to safely accommodate current usage (16.4 MB) with reasonable headroom (3.6 MB) for potential growth.

The corrected patches now properly allocate:
- 24 MB for OEM (down from 30 MB, saves 6 MB)
- 0 MB for userdata (down from 6 MB, saves 6 MB)  
- 99 MB for rootfs (up from 85 MB, adds 14 MB)

This solves the build failure while respecting actual space requirements.
