# Common reproducibility tweaks applied to all SeedSigner Buildroot external trees.
#
# When Buildroot is configured for reproducible builds, ensure that any sources
# that originate from the SeedSigner BR2_EXTERNAL tree compile with a stable
# debug-prefix mapping so that absolute build paths do not leak into the
# resulting binaries. This mirrors the mapping Buildroot already applies for the
# main output directory via the toolchain wrapper, but covers the external tree
# itself which otherwise resides outside of $(BASE_DIR).

SEEDSIGNER_NO_DEBUG_ENV = \
CFLAGS="$(TARGET_CFLAGS) -g0" \
CXXFLAGS="$(TARGET_CXXFLAGS) -g0"

ifeq ($(BR2_REPRODUCIBLE),y)

ifeq ($(BR2_TOOLCHAIN_GCC_AT_LEAST_8),y)
SEEDSIGNER_DEBUG_PREFIX_MAP = -ffile-prefix-map=$(BR2_EXTERNAL_RPI_SEEDSIGNER_PATH)=br-external
else
SEEDSIGNER_DEBUG_PREFIX_MAP = -fdebug-prefix-map=$(BR2_EXTERNAL_RPI_SEEDSIGNER_PATH)=br-external
endif

TARGET_CFLAGS += $(SEEDSIGNER_DEBUG_PREFIX_MAP)
TARGET_CXXFLAGS += $(SEEDSIGNER_DEBUG_PREFIX_MAP)

endif
