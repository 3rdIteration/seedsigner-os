################################################################################
#
# python-inflate64
#
################################################################################

PYTHON_INFLATE64_VERSION = 1.0.3
PYTHON_INFLATE64_SOURCE = inflate64-$(PYTHON_INFLATE64_VERSION).tar.gz
PYTHON_INFLATE64_SITE = https://files.pythonhosted.org/packages/source/i/inflate64
PYTHON_INFLATE64_SETUP_TYPE = setuptools
PYTHON_INFLATE64_LICENSE = LGPL-2.1-or-later
PYTHON_INFLATE64_LICENSE_FILES = docs/LICENSES.txt

$(eval $(python-package))

