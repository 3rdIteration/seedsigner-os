 ################################################################################
 #
 # python-pysatochip
 #
 ################################################################################

 PYTHON_PYSATOCHIP_VERSION = 0.17.0
 PYTHON_PYSATOCHIP_SOURCE = pysatochip-$(PYTHON_PYSATOCHIP_VERSION).tar.gz
 PYTHON_PYSATOCHIP_SITE = https://files.pythonhosted.org/packages/93/ef/c69b13f0082704d3466b94cbea5be3b2b59f562ee9d4df31ccbdcd9b42b9
 PYTHON_PYSATOCHIP_SETUP_TYPE = setuptools
 PYTHON_PYSATOCHIP_LICENSE = LGPL

 
 $(eval $(python-package))

