################################################################################
#
# python-pygp
#
################################################################################

PYTHON_PYGP_VERSION = 0.2a
PYTHON_PYGP_SITE = $(call github,3rdIteration,PyGP,$(PYTHON_PYGP_VERSION))
PYTHON_PYGP_SETUP_TYPE = setuptools
PYTHON_PYGP_LICENSE = LGPL


$(eval $(python-package))
