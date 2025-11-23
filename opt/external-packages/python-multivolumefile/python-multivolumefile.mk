################################################################################
#
# python-multivolumefile
#
################################################################################

PYTHON_MULTIVOLUMEFILE_VERSION = 0.2.3
PYTHON_MULTIVOLUMEFILE_SOURCE = multivolumefile-$(PYTHON_MULTIVOLUMEFILE_VERSION).tar.gz
PYTHON_MULTIVOLUMEFILE_SITE = https://files.pythonhosted.org/packages/source/m/multivolumefile
PYTHON_MULTIVOLUMEFILE_SETUP_TYPE = setuptools
PYTHON_MULTIVOLUMEFILE_LICENSE = LGPL-2.1+
PYTHON_MULTIVOLUMEFILE_LICENSE_FILES = LICENSE

$(eval $(python-package))

