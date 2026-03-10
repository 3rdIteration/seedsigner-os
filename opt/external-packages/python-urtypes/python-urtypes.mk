 ################################################################################
 #
 # python-urtypes
 #
 ################################################################################

 PYTHON_URTYPES_VERSION = 7fb280eab3b3563dfc57d2733b0bf5cbc0a96a6a
 PYTHON_URTYPES_SITE = $(call github,selfcustody,urtypes,$(PYTHON_URTYPES_VERSION))
 PYTHON_URTYPES_SETUP_TYPE = setuptools
 PYTHON_URTYPES_LICENSE = MIT

 
 $(eval $(python-package))

