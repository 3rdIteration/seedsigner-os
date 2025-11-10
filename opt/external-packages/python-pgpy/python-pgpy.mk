################################################################################
#
# python-pgpy
#
################################################################################

PYTHON_PGPY_VERSION = 0.6.0
PYTHON_PGPY_SITE = $(call github,SecurityInnovation,PGPy,v$(PYTHON_PGPY_VERSION))
PYTHON_PGPY_SOURCE = PGPy-$(PYTHON_PGPY_VERSION).tar.gz
PYTHON_PGPY_SETUP_TYPE = setuptools
PYTHON_PGPY_LICENSE = BSD-3-Clause
PYTHON_PGPY_LICENSE_FILES = LICENSE
PYTHON_PGPY_DEPENDENCIES = python-cryptography python-pyasn1

$(eval $(python-package))

