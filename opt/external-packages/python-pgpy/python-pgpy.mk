################################################################################
#
# python-pgpy
#
################################################################################

PYTHON_PGPY_VERSION = 1c8d881f84c455472114e5acf1ccdbc8809dd72f
PYTHON_PGPY_SITE = $(call github,3rdIteration,PGPy,$(PYTHON_PGPY_VERSION))
PYTHON_PGPY_SOURCE = PGPy-$(PYTHON_PGPY_VERSION).tar.gz
PYTHON_PGPY_SETUP_TYPE = setuptools
PYTHON_PGPY_LICENSE = BSD-3-Clause
PYTHON_PGPY_LICENSE_FILES = LICENSE
PYTHON_PGPY_DEPENDENCIES = python-cryptography python-pyasn1 python-pycryptodomex python-ecdsa python-embit

$(eval $(python-package))

