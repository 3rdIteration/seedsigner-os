################################################################################
#
# python-shamir-mnemonic
#
################################################################################

PYTHON_SHAMIR_MNEMONIC_VERSION = 0.3.0
PYTHON_SHAMIR_MNEMONIC_SITE = $(call github,trezor,python-shamir-mnemonic,v$(PYTHON_SHAMIR_MNEMONIC_VERSION))
# The project uses poetry-core as its build backend which requires
# Buildroot's pep517 infrastructure. Specify pep517 so the build
# system invokes the PEP517 workflow instead of legacy setuptools.
PYTHON_SHAMIR_MNEMONIC_SETUP_TYPE = pep517
PYTHON_SHAMIR_MNEMONIC_LICENSE = MIT

$(eval $(python-package))
