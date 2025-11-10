################################################################################
#
# python-shamir-mnemonic
#
################################################################################

PYTHON_SHAMIR_MNEMONIC_VERSION = 0.3-setuptools
PYTHON_SHAMIR_MNEMONIC_SITE = $(call github,3rdIteration,python-shamir-mnemonic,$(PYTHON_SHAMIR_MNEMONIC_VERSION))
PYTHON_SHAMIR_MNEMONIC_SETUP_TYPE = setuptools
PYTHON_SHAMIR_MNEMONIC_LICENSE = MIT

$(eval $(python-package))
