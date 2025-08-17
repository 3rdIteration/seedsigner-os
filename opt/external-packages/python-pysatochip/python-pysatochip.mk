 ################################################################################
 #
 # python-pysatochip
 #
 ################################################################################

 PYTHON_PYSATOCHIP_VERSION = 0.5-alpha
 PYTHON_PYSATOCHIP_SITE = $(call github,3rdIteration,pysatochip,$(PYTHON_PYSATOCHIP_VERSION))
 PYTHON_PYSATOCHIP_SETUP_TYPE = setuptools
 PYTHON_PYSATOCHIP_LICENSE = LGPL

 
 $(eval $(python-package))

