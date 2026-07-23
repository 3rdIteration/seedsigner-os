################################################################################
#
# python-pgpy
#
################################################################################

# uClibc toolchains (Rockchip/Luckfox Pico) cannot easily build
# python-cryptography (Rust), so use the pycryptodomex-backed fork there.
# glibc toolchains (Raspberry Pi / La Frite) keep the upstream release.
ifeq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)
PYTHON_PGPY_VERSION = fa98d641c7af26f43564b5f9bf1af2edcdbd5c6f
PYTHON_PGPY_SITE = $(call github,3rdIteration,PGPy,$(PYTHON_PGPY_VERSION))
PYTHON_PGPY_DEPENDENCIES = python-pycryptodomex python-pyasn1 python-ecdsa
else
PYTHON_PGPY_VERSION = 0.6.0
PYTHON_PGPY_SITE = $(call github,SecurityInnovation,PGPy,v$(PYTHON_PGPY_VERSION))
PYTHON_PGPY_DEPENDENCIES = python-cryptography python-pyasn1
endif
PYTHON_PGPY_SOURCE = PGPy-$(PYTHON_PGPY_VERSION).tar.gz
PYTHON_PGPY_SETUP_TYPE = setuptools
PYTHON_PGPY_LICENSE = BSD-3-Clause
PYTHON_PGPY_LICENSE_FILES = LICENSE

$(eval $(python-package))

