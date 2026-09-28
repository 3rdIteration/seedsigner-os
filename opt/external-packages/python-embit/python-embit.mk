################################################################################
#
# python-embit
#
################################################################################

# v0.8.2. Not published to PyPI, so it is fetched from GitHub by the tag's commit
# (the tag's pyproject.toml still says 0.8.1).
PYTHON_EMBIT_VERSION = eb6104fd85d3becabba628756cd5e1b75619f3a1
PYTHON_EMBIT_SITE = $(call github,diybitcoinhardware,embit,$(PYTHON_EMBIT_VERSION))
PYTHON_EMBIT_LICENSE = MIT
PYTHON_EMBIT_LICENSE_FILES = LICENSE secp256k1/secp256k1-zkp/COPYING
PYTHON_EMBIT_SETUP_TYPE = setuptools

# embit 0.8.1 stopped shipping prebuilt libsecp256k1 binaries. Without one it falls
# back to a pure-Python secp256k1, far too slow for a Pi Zero, so the library is
# built here from the secp256k1-zkp commit embit's own `secp256k1` submodule pins,
# with embit's own Makefile and config (which enables the ecdh, recovery,
# extrakeys, schnorrsig and zkp modules embit prefers).
PYTHON_EMBIT_SECP256K1_ZKP_VERSION = d9560e0af78d9059bba0c4845a310387abfa4e5e
PYTHON_EMBIT_SECP256K1_ZKP_SOURCE = secp256k1-zkp-$(PYTHON_EMBIT_SECP256K1_ZKP_VERSION).tar.gz
PYTHON_EMBIT_EXTRA_DOWNLOADS = \
	$(call github,ElementsProject,secp256k1-zkp,$(PYTHON_EMBIT_SECP256K1_ZKP_VERSION))/$(PYTHON_EMBIT_SECP256K1_ZKP_SOURCE)

# A GitHub archive does not include submodules; unpack secp256k1-zkp where the
# submodule would be.
define PYTHON_EMBIT_EXTRACT_SECP256K1_ZKP
	mkdir -p $(@D)/secp256k1/secp256k1-zkp
	$(call suitable-extractor,$(PYTHON_EMBIT_SECP256K1_ZKP_SOURCE)) \
		$(PYTHON_EMBIT_DL_DIR)/$(PYTHON_EMBIT_SECP256K1_ZKP_SOURCE) | \
		$(TAR) --strip-components=1 -C $(@D)/secp256k1/secp256k1-zkp $(TAR_OPTIONS) -
endef
PYTHON_EMBIT_POST_EXTRACT_HOOKS += PYTHON_EMBIT_EXTRACT_SECP256K1_ZKP

# pyproject.toml pins exact build tools (setuptools==80.9.0, wheel==0.47.0) and
# `python -m build -n` refuses to run when the host's differ. Nothing in embit's
# metadata needs more than PEP 621 support.
define PYTHON_EMBIT_RELAX_BUILD_REQUIRES
	$(SED) '/^\[build-system\]/,/^\]/{s/"setuptools==[^"]*"/"setuptools>=61"/;/"wheel==[^"]*"/d}' \
		$(@D)/pyproject.toml
endef
PYTHON_EMBIT_POST_PATCH_HOOKS += PYTHON_EMBIT_RELAX_BUILD_REQUIRES

# No pure-Python secp256k1 in the image, so a library that fails to load stops the
# app instead of silently signing in Python (SeedSigner/seedsigner-os #117).
# Removed from the source so it never reaches the wheel; the post-build scripts'
# rm lines and verify-secp256k1-binary.sh stay as the check that it did not.
# 0001-SeedSignerOS-secp256k1-compiled-library-only.patch is what makes this
# possible on 0.8.2, whose secp256k1.py otherwise imports it unconditionally.
define PYTHON_EMBIT_REMOVE_PY_SECP256K1
	rm -f $(@D)/src/embit/util/py_secp256k1.py
endef
PYTHON_EMBIT_POST_PATCH_HOOKS += PYTHON_EMBIT_REMOVE_PY_SECP256K1

# embit's Makefile flags, minus -Werror (a newer target compiler's warnings must
# not fail the build), plus the target's own CFLAGS.
PYTHON_EMBIT_SECP256K1_CFLAGS = \
	$(TARGET_CFLAGS) -fPIC -Wno-unused-function \
	-Isecp256k1-zkp -Isecp256k1-zkp/src -Iconfig -DHAVE_CONFIG_H

define PYTHON_EMBIT_BUILD_SECP256K1
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/secp256k1 \
		CC="$(TARGET_CC)" PLATFORM=linux ARCH=target \
		CFLAGS="$(PYTHON_EMBIT_SECP256K1_CFLAGS)"
endef
PYTHON_EMBIT_POST_BUILD_HOOKS += PYTHON_EMBIT_BUILD_SECP256K1

# With no fallback, a symbol the library lacks would only surface as a crash on
# the device the first time it is called. Every symbol ctypes_secp256k1.py binds
# (secp256k1.secp256k1_*) must be exported; the list is read from the bindings
# themselves so it follows embit bumps. An empty list fails too: that means the
# bindings changed shape and this check would pass vacuously.
PYTHON_EMBIT_SECP256K1_BUILD_DIR = $(@D)/secp256k1/build
define PYTHON_EMBIT_CHECK_SECP256K1_SYMBOLS
	$(TARGET_NM) -D --defined-only $(PYTHON_EMBIT_SECP256K1_BUILD_DIR)/libsecp256k1_linux_target.so | \
		awk '{print $$3}' | LC_ALL=C sort -u > $(PYTHON_EMBIT_SECP256K1_BUILD_DIR)/exported.txt
	grep -o 'secp256k1\.secp256k1_[a-z0-9_]*' $(@D)/src/embit/util/ctypes_secp256k1.py | \
		cut -d. -f2 | LC_ALL=C sort -u > $(PYTHON_EMBIT_SECP256K1_BUILD_DIR)/required.txt
	[ -s $(PYTHON_EMBIT_SECP256K1_BUILD_DIR)/required.txt ] || { \
		echo "python-embit: no secp256k1_* symbols found in ctypes_secp256k1.py" >&2; exit 1; }
	missing="$$(LC_ALL=C comm -23 $(PYTHON_EMBIT_SECP256K1_BUILD_DIR)/required.txt \
		$(PYTHON_EMBIT_SECP256K1_BUILD_DIR)/exported.txt)"; \
	if [ -n "$$missing" ]; then \
		echo "python-embit: libsecp256k1 lacks symbols embit binds:" $$missing >&2; \
		exit 1; \
	fi
endef
PYTHON_EMBIT_POST_BUILD_HOOKS += PYTHON_EMBIT_CHECK_SECP256K1_SYMBOLS

# embit looks for libsecp256k1.so in its own util/prebuilt directory, after the
# system loader. A path it finds for certain, where ctypes.util.find_library would
# need an ldconfig cache or a compiler on the device.
define PYTHON_EMBIT_INSTALL_SECP256K1
	$(INSTALL) -D -m 0755 $(@D)/secp256k1/build/libsecp256k1_linux_target.so \
		$(TARGET_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR)/site-packages/embit/util/prebuilt/libsecp256k1.so
endef
PYTHON_EMBIT_POST_INSTALL_TARGET_HOOKS += PYTHON_EMBIT_INSTALL_SECP256K1

$(eval $(python-package))
