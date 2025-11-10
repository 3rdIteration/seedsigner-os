 ################################################################################
 #
 # python-mnemonic
 #
 ################################################################################

 PYTHON_MNEMONIC_VERSION = 0.20
 PYTHON_MNEMONIC_SITE = $(call github,trezor,mnemonic,v$(PYTHON_MNEMONIC_VERSION))
 PYTHON_MNEMONIC_SETUP_TYPE = setuptools
 PYTHON_MNEMONIC_LICENSE = MIT

 
 $(eval $(python-package))

