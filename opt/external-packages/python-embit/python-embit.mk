################################################################################
#
# python-embit
#
################################################################################

PYTHON_EMBIT_VERSION = 0.8.0
PYTHON_EMBIT_SOURCE = embit-$(PYTHON_EMBIT_VERSION).tar.gz
PYTHON_EMBIT_SITE = https://files.pythonhosted.org/packages/83/88/b054b00ade6d2a41749e15976cdcec4b7ec4656ac1cb917ce3de395528d1
PYTHON_EMBIT_LICENSE = MIT
PYTHON_EMBIT_SETUP_TYPE = setuptools

ifeq ($(BR2_aarch64),y)
PYTHON_EMBIT_PATCHES = $(PYTHON_EMBIT_PKGDIR)/0001-SeedSignerOS-AArch64-Arch.patch
else
PYTHON_EMBIT_PATCHES = $(PYTHON_EMBIT_PKGDIR)/0001-SeedSignerOS-RPi-Arch.patch
endif

$(eval $(python-package))
