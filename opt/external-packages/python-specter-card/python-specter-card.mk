################################################################################
#
# python-specter-card
#
################################################################################

PYTHON_SPECTER_CARD_VERSION = 0.1-pytest
PYTHON_SPECTER_CARD_SITE = $(call github,3rdIteration,specter-javacard,$(PYTHON_SPECTER_CARD_VERSION))
PYTHON_SPECTER_CARD_SUBDIR = py
PYTHON_SPECTER_CARD_SETUP_TYPE = setuptools
PYTHON_SPECTER_CARD_LICENSE = MIT
PYTHON_SPECTER_CARD_DEPENDENCIES = python-cryptography python-pyscard

$(eval $(python-package))
