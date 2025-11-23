################################################################################
#
# python-pyppmd
#
################################################################################

PYTHON_PYPPMD_VERSION = 1.2.0
PYTHON_PYPPMD_SOURCE = pyppmd-$(PYTHON_PYPPMD_VERSION).tar.gz
PYTHON_PYPPMD_SITE = https://files.pythonhosted.org/packages/source/p/pyppmd
PYTHON_PYPPMD_SETUP_TYPE = setuptools
PYTHON_PYPPMD_LICENSE = LGPL-2.1-or-later
PYTHON_PYPPMD_LICENSE_FILES = LICENSE

$(eval $(python-package))

