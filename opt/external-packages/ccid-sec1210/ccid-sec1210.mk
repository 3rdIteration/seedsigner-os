################################################################################
#
# ccid-sec1210
#
################################################################################

CCID_SEC1210_VERSION = 1.7.1
CCID_SEC1210_SITE = $(call github,LudovicRousseau,CCID,$(CCID_SEC1210_VERSION))
CCID_SEC1210_LICENSE = LGPL-2.1+
CCID_SEC1210_LICENSE_FILES = COPYING
CCID_SEC1210_INSTALL_STAGING = YES
CCID_SEC1210_DEPENDENCIES = pcsc-lite host-pkgconf libusb
CCID_SEC1210_CONF_OPTS = -Dserial=true -Dudev-rules=false

ifeq ($(BR2_PACKAGE_HAS_UDEV),y)
define CCID_INSTALL_UDEV_RULES
	if test -d $(TARGET_DIR)/etc/udev/rules.d ; then \
		cp $(@D)/src/92_pcscd_ccid.rules $(TARGET_DIR)/etc/udev/rules.d/ ; \
	fi;
endef

CCID_POST_INSTALL_TARGET_HOOKS += CCID_INSTALL_UDEV_RULES
endif

$(eval $(meson-package))
