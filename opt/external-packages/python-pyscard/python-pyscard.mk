 ################################################################################
 #
 # python-pyscard
 #
 ################################################################################

PYTHON_PYSCARD_VERSION = 2.3.0
PYTHON_PYSCARD_SITE = $(call github,LudovicRousseau,pyscard,$(PYTHON_PYSCARD_VERSION))
PYTHON_PYSCARD_SETUP_TYPE = setuptools
PYTHON_PYSCARD_LICENSE = LGPL
# Ensure the swig host tool is built before running the Python build
PYTHON_PYSCARD_DEPENDENCIES += host-swig
# And expose it on PATH for the metadata generation step
PYTHON_PYSCARD_ENV = PATH="$(HOST_DIR)/bin:$(HOST_DIR)/sbin:$$PATH"

 
 $(eval $(python-package))

