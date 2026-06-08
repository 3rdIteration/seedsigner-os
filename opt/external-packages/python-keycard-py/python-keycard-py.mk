################################################################################
#
# python-keycard-py
#
################################################################################

PYTHON_KEYCARD_PY_VERSION = v0.3.0
PYTHON_KEYCARD_PY_SITE = $(call github,mmlado,keycard-py,$(PYTHON_KEYCARD_PY_VERSION))
PYTHON_KEYCARD_PY_SETUP_TYPE = flit
PYTHON_KEYCARD_PY_LICENSE = MIT

$(eval $(python-package))
