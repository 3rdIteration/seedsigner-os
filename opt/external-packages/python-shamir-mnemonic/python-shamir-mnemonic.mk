################################################################################
#
# python-shamir-mnemonic
#
################################################################################

PYTHON_SHAMIR_MNEMONIC_VERSION = 0.3.0
PYTHON_SHAMIR_MNEMONIC_SOURCE = shamir_mnemonic-$(PYTHON_SHAMIR_MNEMONIC_VERSION).tar.gz
PYTHON_SHAMIR_MNEMONIC_SITE = https://files.pythonhosted.org/packages/b2/fd/9f5b305b5280795209817efe6b0cd6017f4714e3f36d160b2d4dfcc78c02
PYTHON_SHAMIR_MNEMONIC_SETUP_TYPE = poetry
PYTHON_SHAMIR_MNEMONIC_LICENSE = MIT

$(eval $(python-package))
