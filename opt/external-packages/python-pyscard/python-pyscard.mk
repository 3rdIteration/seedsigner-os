 ################################################################################
 #
 # python-pyscard
 #
 ################################################################################

 PYTHON_PYSCARD_VERSION = 2.0.7
 PYTHON_PYSCARD_SITE = $(call github,LudovicRousseau,pyscard,$(PYTHON_PYSCARD_VERSION))
 PYTHON_PYSCARD_SETUP_TYPE = setuptools
 PYTHON_PYSCARD_LICENSE = LGPL

 
 $(eval $(python-package))

