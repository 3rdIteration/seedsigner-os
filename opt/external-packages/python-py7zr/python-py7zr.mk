################################################################################
#
# python-py7zr
#
################################################################################

PYTHON_PY7ZR_VERSION = 1.0.0
PYTHON_PY7ZR_SOURCE = py7zr-$(PYTHON_PY7ZR_VERSION).tar.gz
PYTHON_PY7ZR_SITE = https://files.pythonhosted.org/packages/source/p/py7zr
PYTHON_PY7ZR_SETUP_TYPE = pep517
PYTHON_PY7ZR_LICENSE = LGPL-2.1-or-later
PYTHON_PY7ZR_LICENSE_FILES = LICENSE
PYTHON_PY7ZR_DEPENDENCIES = \
host-python-setuptools-scm \
python-texttable \
python-pycryptodomex \
python-brotli \
python-psutil \
python-pyzstd \
python-pyppmd \
python-pybcj \
python-multivolumefile \
python-inflate64

$(eval $(python-package))

