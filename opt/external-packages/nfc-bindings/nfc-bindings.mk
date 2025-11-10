################################################################################
#
# nfc-bindings
#
################################################################################

NFC_BINDINGS_VERSION = 0.1-placeholder
NFC_BINDINGS_SITE = $(call github,3rdIteration,nfc-bindings,$(NFC_BINDINGS_VERSION))
NFC_BINDINGS_LICENSE = BSD-3
NFC_BINDINGS_LICENSE_FILES = LICENCE
NFC_BINDINGS_DEPENDENCIES = libnfc libusb libusb-compat
NFC_BINDINGS_CONF_OPTS = -DPYTHON_EXECUTABLE=$(HOST_DIR)/bin/python \
	-DPYTHON_INCLUDE_DIRS=$(STAGING_DIR)/usr/include/python$(PYTHON3_VERSION_MAJOR) \
	-DPython_INCLUDE_DIRS=$(STAGING_DIR)/usr/include/python$(PYTHON3_VERSION_MAJOR) \
	-DPYTHON_PATH=$(STAGING_DIR)/usr/lib/python$(PYTHON3_VERSION_MAJOR) \
	-DPYTHON_VER=$(PYTHON3_VERSION_MAJOR)
NFC_BINDINGS_INSTALL_STAGING = YES

$(eval $(cmake-package))
