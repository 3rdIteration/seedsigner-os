################################################################################
#
# host-python-swig-pypi
#
################################################################################

HOST_PYTHON_SWIG_PYPI_VERSION = 4.3.1.post0
HOST_PYTHON_SWIG_PYPI_SOURCE = swig-$(HOST_PYTHON_SWIG_PYPI_VERSION)-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.whl
HOST_PYTHON_SWIG_PYPI_SITE = https://files.pythonhosted.org/packages/ce/45/585b9df85ccd6aadd7eb3b124f79c96242d87b845e33f9fc464e1\
26e63b8
HOST_PYTHON_SWIG_PYPI_SETUP_TYPE = wheel
HOST_PYTHON_SWIG_PYPI_LICENSE = GPL-3.0-or-later
HOST_PYTHON_SWIG_PYPI_LICENSE_FILES = swig-$(HOST_PYTHON_SWIG_PYPI_VERSION).dist-info/licenses/LICENSE

$(eval $(host-python-package))
