################################################################################
#
# ifdnfc
#
################################################################################

IFDNFC_VERSION = 0.1-placeholder
IFDNFC_SITE = $(call github,3rdIteration,ifdnfc,$(IFDNFC_VERSION))
IFDNFC_LICENSE = GPL-3.0
IFDNFC_LICENSE_FILES = COPYING
IFDNFC_CPE_ID_VENDOR = opensc_project
IFDNFC_DEPENDENCIES = libnfc pcsc-lite
IFDNFC_INSTALL_STAGING = YES
IFDNFC_CONF_OPTS = 
IFDNFC_AUTORECONF = YES

$(eval $(autotools-package))
