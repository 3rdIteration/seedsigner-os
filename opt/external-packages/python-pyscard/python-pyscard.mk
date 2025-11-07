 ################################################################################
 #
 # python-pyscard
 #
 ################################################################################

PYTHON_PYSCARD_VERSION = 2.3.1
PYTHON_PYSCARD_SITE = $(call github,LudovicRousseau,pyscard,$(PYTHON_PYSCARD_VERSION))
PYTHON_PYSCARD_SETUP_TYPE = setuptools
PYTHON_PYSCARD_LICENSE = LGPL
# Ensure the swig host tool is available for wrapper generation
PYTHON_PYSCARD_DEPENDENCIES += host-swig
# Explicitly point setup.py to the host-provided swig binary
PYTHON_PYSCARD_ENV += SWIG="$(HOST_DIR)/bin/swig"

 
 $(eval $(python-package))

