 ################################################################################
 #
 # python-pysatochip
 #
 ################################################################################

# Single version for ALL toolchains/platforms. Toolchain compatibility is
# handled inside the package (certificate_validator.py falls back from
# OpenSSL to pycryptodomex automatically), never via divergent version pins.
PYTHON_PYSATOCHIP_VERSION = 0.6a
 PYTHON_PYSATOCHIP_SITE = $(call github,3rdIteration,pysatochip,$(PYTHON_PYSATOCHIP_VERSION))
 PYTHON_PYSATOCHIP_SETUP_TYPE = setuptools
 PYTHON_PYSATOCHIP_LICENSE = LGPL

 
 $(eval $(python-package))
