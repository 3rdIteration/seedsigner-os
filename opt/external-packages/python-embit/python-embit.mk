################################################################################
#
# python-embit
#
################################################################################

PYTHON_EMBIT_VERSION = 0.8.0
PYTHON_EMBIT_SOURCE = embit-$(PYTHON_EMBIT_VERSION).tar.gz
PYTHON_EMBIT_SITE = https://files.pythonhosted.org/packages/83/88/b054b00ade6d2a41749e15976cdcec4b7ec4656ac1cb917ce3de395528d1
PYTHON_EMBIT_LICENSE = MIT
PYTHON_EMBIT_SETUP_TYPE = setuptools

# For aarch64 targets, swap the ARM32 prebuilt selected by the RPi arch patch
# with the aarch64 prebuilt. Both patches in the package dir are always applied
# (Buildroot auto-discovers all *.patch files alphabetically), so the hook
# runs after both patches have been applied.
# We also physically remove the ARM32 .so files so that setuptools cannot
# include them via embit.egg-info/SOURCES.txt, which overrides pyproject.toml.
ifeq ($(BR2_aarch64),y)
define PYTHON_EMBIT_FIX_AARCH64_PREBUILT
	rm -f $(@D)/src/embit/util/prebuilt/libsecp256k1_linux_armv6l.so
	rm -f $(@D)/src/embit/util/prebuilt/libsecp256k1_linux_armv7l.so
	$(SED) 's|libsecp256k1_linux_arm\*|libsecp256k1_linux_aarch64.so|g' \
		$(@D)/pyproject.toml
endef
PYTHON_EMBIT_POST_PATCH_HOOKS += PYTHON_EMBIT_FIX_AARCH64_PREBUILT
endif

# Same treatment for x86_64 (desktop profile): without this the RPi patch's
# "libsecp256k1_linux_arm*" glob installs the two ARM32 shared objects into
# the x86_64 rootfs and buildroot's per-package check_bin_arch fails the
# build ("architecture ... is ARM, should be ... X86-64"). Remove the
# foreign .so files from the source tree and point the packaging glob at the
# linux_x86_64 prebuilt that embit ships.
ifeq ($(BR2_x86_64),y)
define PYTHON_EMBIT_FIX_X86_64_PREBUILT
	rm -f $(@D)/src/embit/util/prebuilt/libsecp256k1_linux_armv6l.so
	rm -f $(@D)/src/embit/util/prebuilt/libsecp256k1_linux_armv7l.so
	rm -f $(@D)/src/embit/util/prebuilt/libsecp256k1_linux_aarch64.so
	$(SED) 's|libsecp256k1_linux_arm\*|libsecp256k1_linux_x86_64.so|g' \
		$(@D)/pyproject.toml
endef
PYTHON_EMBIT_POST_PATCH_HOOKS += PYTHON_EMBIT_FIX_X86_64_PREBUILT
endif

$(eval $(python-package))
