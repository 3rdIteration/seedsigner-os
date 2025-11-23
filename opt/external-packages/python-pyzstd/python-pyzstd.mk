################################################################################
#
# python-pyzstd
#
################################################################################

PYTHON_PYZSTD_VERSION = 0.18.0
PYTHON_PYZSTD_SOURCE = pyzstd-$(PYTHON_PYZSTD_VERSION).tar.gz
PYTHON_PYZSTD_SITE = https://files.pythonhosted.org/packages/source/p/pyzstd
PYTHON_PYZSTD_SETUP_TYPE = pep517
PYTHON_PYZSTD_LICENSE = BSD-3-Clause
PYTHON_PYZSTD_LICENSE_FILES = LICENSE LICENSE_zstd zstd/LICENSE
PYTHON_PYZSTD_DEPENDENCIES = python-typing-extensions

$(eval $(python-package))

