################################################################################
#
# python-pybcj
#
################################################################################

PYTHON_PYBCJ_VERSION = 1.0.6
PYTHON_PYBCJ_SOURCE = pybcj-$(PYTHON_PYBCJ_VERSION).tar.gz
PYTHON_PYBCJ_SITE = https://files.pythonhosted.org/packages/source/p/pybcj
PYTHON_PYBCJ_SETUP_TYPE = setuptools
PYTHON_PYBCJ_LICENSE = LGPL-2.1-or-later
PYTHON_PYBCJ_LICENSE_FILES = LICENSE

$(eval $(python-package))

