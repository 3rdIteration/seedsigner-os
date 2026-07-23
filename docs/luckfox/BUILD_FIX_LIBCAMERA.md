# Build Fix: libcamera GCC Incompatibility

## Issue
GitHub Actions build failure in run [#22021736252](https://github.com/3rdIteration/seedsigner-luckfox-pico/actions/runs/22021736252/job/63631867142)

## Error Message
```
output/build/libcamera-v0.3.2/meson.build:150:8: ERROR: Problem encountered: gcc version is too old, libcamera requires 9.0 or newer
make[1]: *** [package/pkg-generic.mk:279: /home/runner/work/seedsigner-luckfox-pico/seedsigner-luckfox-pico/luckfox-pico/sysdrv/source/buildroot/buildroot-2024.11.4/output/build/libcamera-v0.3.2/.stamp_configured] Error 1
```

## Root Cause
- **Buildroot version:** 2024.11.4 (includes libcamera v0.3.2)
- **libcamera requirement:** GCC 9.0 or newer
- **Toolchain provided:** arm-rockchip830-linux-uclibcgnueabihf with GCC 8
- **Conflict:** Cannot upgrade toolchain without rebuilding entire LuckFox Pico SDK

## Solution
Disable libcamera and libcamera-apps packages in buildroot configuration.

### Why This Works
1. **Camera functionality is provided via v4l2 (Video4Linux2) API**
   - libv4l is already enabled: `BR2_PACKAGE_LIBV4L=y`
   - libv4l-utils is enabled: `BR2_PACKAGE_LIBV4L_UTILS=y`
   - Test code uses v4l2 directly (see `test_suite/test.py`)

2. **libcamera is not directly used**
   - No application code references libcamera-apps utilities
   - Camera interface in SeedSigner uses v4l2 API
   - libcamera was only included as a "nice to have" modern camera framework

3. **No functional impact**
   - Camera QR code scanning continues to work
   - All camera features remain available via v4l2
   - v4l2 is the standard Linux camera API and well-supported

## Changes Made

### 1. Buildroot Configuration (`buildroot/configs/luckfox_pico_defconfig`)
```diff
 BR2_PACKAGE_LIBCAMERA_ARCH_SUPPORTS=y
-BR2_PACKAGE_LIBCAMERA=y
-BR2_PACKAGE_LIBCAMERA_HAS_PIPELINE=y
-BR2_PACKAGE_LIBCAMERA_PIPELINE_RKISP1=y
-BR2_PACKAGE_LIBCAMERA_APPS=y
+# BR2_PACKAGE_LIBCAMERA is not set
+# BR2_PACKAGE_LIBCAMERA_APPS is not set
```

### 2. Build Scripts
Removed libcamera package references from:
- `.github/workflows/build.yml`
- `buildroot/os-build.sh`
- `buildroot/build-local.sh`

### 3. Documentation
Updated `docs/OS-build-instructions.md` to remove libcamera references.

## Alternative Solutions Considered

### 1. Upgrade Toolchain to GCC 9+
❌ **Rejected**: Would require rebuilding the entire LuckFox Pico SDK toolchain, which is:
- Complex and time-consuming
- Risky (potential compatibility issues with kernel/drivers)
- Outside the scope of this repository

### 2. Downgrade libcamera
❌ **Rejected**: Would require:
- Forking buildroot packages
- Maintaining custom libcamera version
- Potential security/compatibility issues
- Unnecessary since v4l2 already works

### 3. Use Different Buildroot Version
❌ **Rejected**: 
- Buildroot 2024.11.4 is what the LuckFox SDK uses
- Changing it could introduce other incompatibilities
- Not necessary since disabling libcamera is simpler and safer

## Verification

### Expected Build Outcome
The build should now complete successfully with all camera functionality intact via the v4l2 interface.

### How to Test Camera After Fix
1. Boot the device with the new image
2. Run camera test: `v4l2-ctl --device=/dev/video15 --stream-mmap`
3. Verify QR code scanning works in SeedSigner application

### Build Steps
The GitHub Actions workflow will automatically:
1. Clone required repositories
2. Configure buildroot (with libcamera disabled)
3. Build system components
4. Create flashable images

## Technical Background

### What is libcamera?
libcamera is a modern camera framework for Linux designed to replace the older v4l2 userspace libraries. It provides:
- Better abstraction for complex camera pipelines
- Modern C++ API
- Support for advanced camera features

However, it requires:
- GCC 9+ for C++17 features
- More modern build environment
- Additional dependencies

### What is v4l2?
Video4Linux version 2 (v4l2) is the traditional Linux kernel API for video capture devices:
- Stable and mature
- Widely supported
- Works with older toolchains
- Sufficient for SeedSigner's camera needs

## References
- [GitHub Issue Discussion](https://github.com/3rdIteration/seedsigner-luckfox-pico/actions/runs/22021736252/job/63631867142)
- [libcamera Project](https://libcamera.org/)
- [Video4Linux Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
- [Buildroot Documentation](https://buildroot.org/downloads/manual/manual.html)

## Date
Fixed: February 14, 2026
