################################################################################
#
# python-ndeflib
#
################################################################################

PYTHON_NDEFLIB_VERSION = 0.3.3
PYTHON_NDEFLIB_SITE = $(call github,nfcpy,ndeflib,$(PYTHON_NDEFLIB_VERSION))
PYTHON_NDEFLIB_SETUP_TYPE = setuptools
PYTHON_NDEFLIB_LICENSE = ISCL

$(eval $(python-package))
