################################################################################
#
# host-python-swig-pypi
#
################################################################################

HOST_PYTHON_SWIG_PYPI_VERSION = 4.3.1.post0
HOST_PYTHON_SWIG_PYPI_SOURCE = swig-$(HOST_PYTHON_SWIG_PYPI_VERSION)-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.whl
HOST_PYTHON_SWIG_PYPI_SITE = https://files.pythonhosted.org/packages/ce/45/585b9df85ccd6aadd7eb3b124f79c96242d87b845e33f9fc464e126e63b8
HOST_PYTHON_SWIG_PYPI_LICENSE = GPL-3.0-or-later
HOST_PYTHON_SWIG_PYPI_LICENSE_FILES = swig-$(HOST_PYTHON_SWIG_PYPI_VERSION).dist-info/licenses/LICENSE

define HOST_PYTHON_SWIG_PYPI_EXTRACT_CMDS
unzip -q $(HOST_PYTHON_SWIG_PYPI_DL_DIR)/$(HOST_PYTHON_SWIG_PYPI_SOURCE) -d $(@D)
endef

define HOST_PYTHON_SWIG_PYPI_INSTALL_CMDS
mkdir -p $(HOST_DIR)/bin $(HOST_DIR)/share
cp $(@D)/swig/data/bin/swig $(HOST_DIR)/bin/
cp -r $(@D)/swig/data/share/swig $(HOST_DIR)/share/
endef

$(eval $(host-generic-package))
