################################################################################
#
# python-pgpy
#
################################################################################

# Single version for ALL toolchains/platforms. python-cryptography (Rust)
# now builds on uClibc (Tier-3 Rust target patch in the Luckfox build), so
# the pycryptodomex-backed fork split is no longer needed. Toolchain
# compatibility belongs inside the package, never in divergent version pins.
PYTHON_PGPY_VERSION = 0.6.0
PYTHON_PGPY_SITE = $(call github,SecurityInnovation,PGPy,v$(PYTHON_PGPY_VERSION))
PYTHON_PGPY_DEPENDENCIES = python-cryptography python-pyasn1
PYTHON_PGPY_SOURCE = PGPy-$(PYTHON_PGPY_VERSION).tar.gz
PYTHON_PGPY_SETUP_TYPE = setuptools
PYTHON_PGPY_LICENSE = BSD-3-Clause
PYTHON_PGPY_LICENSE_FILES = LICENSE

$(eval $(python-package))

