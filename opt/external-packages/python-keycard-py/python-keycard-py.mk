################################################################################
#
# python-keycard-py
#
################################################################################

PYTHON_KEYCARD_PY_VERSION = v0.3.1
PYTHON_KEYCARD_PY_SITE = $(call github,3rdIteration,keycard-py,$(PYTHON_KEYCARD_PY_VERSION))
PYTHON_KEYCARD_PY_SETUP_TYPE = flit
PYTHON_KEYCARD_PY_LICENSE = MIT

$(eval $(python-package))
