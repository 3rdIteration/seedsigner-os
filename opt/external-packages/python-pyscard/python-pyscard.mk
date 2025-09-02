 ################################################################################
 #
 # python-pyscard
 #
 ################################################################################

PYTHON_PYSCARD_VERSION = 2.3.0
PYTHON_PYSCARD_SITE = $(call github,LudovicRousseau,pyscard,$(PYTHON_PYSCARD_VERSION))
PYTHON_PYSCARD_SETUP_TYPE = pep517
PYTHON_PYSCARD_LICENSE = LGPL-2.1+

# Need SWIG at build time and pcsc-lite headers/libs
PYTHON_PYSCARD_DEPENDENCIES = host-swig pcsc-lite

# Expose the host-provided swig binary and pkg-config path
PYTHON_PYSCARD_ENV = \
	SWIG=$(HOST_DIR)/bin/swig \
	PKG_CONFIG_PATH=$(STAGING_DIR)/usr/lib/pkgconfig

# Disable build isolation so the backend can see host tools
PYTHON_PYSCARD_PEP517_BUILD_OPTS = --no-build-isolation

$(eval $(python-package))

