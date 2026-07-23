 ################################################################################
 #
 # python-pysatochip
 #
 ################################################################################

# uClibc toolchains (Luckfox Pico) use the pycryptodome-backed release;
# glibc toolchains (Raspberry Pi / La Frite) use the mainline release.
ifeq ($(BR2_TOOLCHAIN_USES_UCLIBC),y)
PYTHON_PYSATOCHIP_VERSION = 0.5-alpha-pycryptodome
else
PYTHON_PYSATOCHIP_VERSION = 0.6a
endif
 PYTHON_PYSATOCHIP_SITE = $(call github,3rdIteration,pysatochip,$(PYTHON_PYSATOCHIP_VERSION))
 PYTHON_PYSATOCHIP_SETUP_TYPE = setuptools
 PYTHON_PYSATOCHIP_LICENSE = LGPL

 
 $(eval $(python-package))
