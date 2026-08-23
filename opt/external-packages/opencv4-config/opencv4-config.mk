# Improve build reproducibility for OpenCV4.
# OpenCV's cmake build may not fully inherit the toolchain's prefix-map flags
# set by BR2_REPRODUCIBLE, causing non-deterministic build paths embedded in
# the binary (libopencv_core.so). These flags normalise source file references
# so that builds on different machines produce identical output.
OPENCV4_CONF_OPTS += \
	-DCMAKE_C_FLAGS_INIT="-ffile-prefix-map=$(BASE_DIR)=. -fdebug-prefix-map=$(BASE_DIR)=." \
	-DCMAKE_CXX_FLAGS_INIT="-ffile-prefix-map=$(BASE_DIR)=. -fdebug-prefix-map=$(BASE_DIR)=."
OPENCV4_MAKE_ENV += SOURCE_DATE_EPOCH=0

# Strip the build host's kernel uname out of OpenCV's build-information block.
#
# OpenCV compiles a "General configuration for OpenCV" report into
# libopencv_core.so. One line of it is emitted by OpenCV's own CMakeLists.txt:
#
#   status("    Host:"  ${CMAKE_HOST_SYSTEM_NAME} ${CMAKE_HOST_SYSTEM_VERSION} ${CMAKE_HOST_SYSTEM_PROCESSOR})
#
# CMAKE_HOST_SYSTEM_VERSION is `uname -r` of the *build machine*, and Docker
# does not isolate it - a container reports the host's kernel. So the same
# source tree produces, for the same commit:
#
#   Host: Linux 6.6.87.2-microsoft-standard-WSL2 x86_64   (local WSL2 build)
#   Host: Linux 6.17.0-1022-azure x86_64                  (GitHub Actions)
#
# That one string is enough to make the entire image non-reproducible. Its
# 16-byte length difference shifts libopencv_core's .text/.rodata/.dynsym,
# which changes the size of the compressed initramfs, which shifts the kernel's
# post-initramfs layout and so perturbs kallsyms ordering, a handful of AArch64
# load immediates and the GNU build-id.
#
# Verified 2026-08-22 by diffing a local lafrite-smartcard build against the CI
# build with tools/imgdiff.py: of 6769 rootfs entries exactly one file differed
# (libopencv_core.so.4.10.0), and of its ~5720 embedded strings exactly one
# differed - this Host: line. It was the only root cause.
#
# The Timestamp: line next to it is already handled: CMake's string(TIMESTAMP)
# honours SOURCE_DATE_EPOCH, which OPENCV4_MAKE_ENV pins to 0 above.
#
# This applies to every profile that builds opencv4, not just lafrite.
define OPENCV4_NORMALISE_BUILD_HOST
	grep -q '^status("    Host:"' $(@D)/CMakeLists.txt || { \
		echo "ERROR: opencv4-config: OpenCV's 'Host:' build-info line was not found."; \
		echo "       Upstream CMakeLists.txt changed shape; update"; \
		echo "       OPENCV4_NORMALISE_BUILD_HOST in opencv4-config.mk, or the build"; \
		echo "       host's uname silently leaks into libopencv_core.so again."; \
		exit 1; \
	}
	$(SED) 's|^status("    Host:".*|status("    Host:"             "reproducible")|' \
		$(@D)/CMakeLists.txt
	grep -q '^status("    Host:"             "reproducible")$$' $(@D)/CMakeLists.txt || { \
		echo "ERROR: opencv4-config: failed to normalise OpenCV's 'Host:' build-info line."; \
		exit 1; \
	}
endef

OPENCV4_POST_PATCH_HOOKS += OPENCV4_NORMALISE_BUILD_HOST
