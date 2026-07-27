################################################################################
#
# python-pgpy
#
################################################################################

# No tagged releases available; pinned to latest master commit
PYTHON_PGPY_VERSION = fa98d641c7af26f43564b5f9bf1af2edcdbd5c6f
PYTHON_PGPY_SITE = $(call github,3rdIteration,PGPy,$(PYTHON_PGPY_VERSION))
PYTHON_PGPY_SOURCE = PGPy-$(PYTHON_PGPY_VERSION).tar.gz
PYTHON_PGPY_SETUP_TYPE = setuptools
PYTHON_PGPY_LICENSE = BSD-3-Clause
PYTHON_PGPY_LICENSE_FILES = LICENSE
PYTHON_PGPY_DEPENDENCIES = python-pycryptodomex python-pyasn1

$(eval $(python-package))

