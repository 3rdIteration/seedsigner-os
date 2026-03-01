################################################################################
#
# libcamera
#
################################################################################

LIBCAMERA_VERSION = v0.7.0
LIBCAMERA_SITE = https://git.linuxtv.org/libcamera.git
LIBCAMERA_SITE_METHOD = git
LIBCAMERA_DEPENDENCIES = \
	host-openssl \
	host-pkgconf \
	host-python-jinja2 \
	host-python-ply \
	host-python-pyyaml \
	libyaml \
	gnutls
LIBCAMERA_CONF_OPTS = \
	-Dauto_features=disabled \
	-Dandroid=disabled \
	-Ddocumentation=disabled \
	-Dtest=false \
	-Dwerror=false
LIBCAMERA_INSTALL_STAGING = YES
LIBCAMERA_LICENSE = \
	BSD-2-Clause (raspberrypi), \
	CC-BY-SA-4.0 (doc), \
	CC0-1.0 (meson build system), \
	GPL-2.0 with Linux-syscall-note or BSD-3-Clause (linux kernel headers), \
	GPL-2.0+ (utils), \
	LGPL-2.1+ (library), \
	MIT (qcam/assets/feathericons)
LIBCAMERA_LICENSE_FILES = \
	LICENSES/BSD-2-Clause.txt \
	LICENSES/BSD-3-Clause.txt \
	LICENSES/CC-BY-SA-4.0.txt \
	LICENSES/CC0-1.0.txt \
	LICENSES/GPL-2.0-only.txt \
	LICENSES/GPL-2.0-or-later.txt \
	LICENSES/LGPL-2.1-or-later.txt \
	LICENSES/Linux-syscall-note.txt \
	LICENSES/MIT.txt

ifeq ($(BR2_TOOLCHAIN_GCC_AT_LEAST_7),y)
LIBCAMERA_CXXFLAGS = -faligned-new
endif

ifeq ($(BR2_PACKAGE_LIBCAMERA_PYTHON),y)
LIBCAMERA_DEPENDENCIES += python3 python-pybind
LIBCAMERA_CONF_OPTS += -Dpycamera=enabled
endif

ifeq ($(BR2_PACKAGE_LIBCAMERA_V4L2),y)
LIBCAMERA_CONF_OPTS += -Dv4l2=enabled
endif

LIBCAMERA_PIPELINES-$(BR2_PACKAGE_LIBCAMERA_PIPELINE_RPI_VC4) += rpi/vc4
LIBCAMERA_PIPELINES-$(BR2_PACKAGE_LIBCAMERA_PIPELINE_SIMPLE) += simple
LIBCAMERA_PIPELINES-$(BR2_PACKAGE_LIBCAMERA_PIPELINE_UVCVIDEO) += uvcvideo

LIBCAMERA_CONF_OPTS += -Dpipelines=$(subst $(space),$(comma),$(LIBCAMERA_PIPELINES-y))

ifeq ($(BR2_PACKAGE_HAS_UDEV),y)
LIBCAMERA_CONF_OPTS += -Dudev=enabled
LIBCAMERA_DEPENDENCIES += udev
endif

# Open-Source IPA shlibs need to be signed in order to be runnable within the
# same process, otherwise they are deemed Closed-Source and run in another
# process and communicate over IPC.
LIBCAMERA_STRIP_FIND_CMD = \
	find $(@D)/buildroot-build/src/ipa \
	$(if $(call qstrip,$(BR2_STRIP_EXCLUDE_FILES)), \
		-not \( $(call findfileclauses,$(call qstrip,$(BR2_STRIP_EXCLUDE_FILES))) \) ) \
	-type f -name 'ipa_*.so' -print0

define LIBCAMERA_BUILD_STRIP_IPA_SO
	$(LIBCAMERA_STRIP_FIND_CMD) | xargs --no-run-if-empty -0 $(STRIPCMD)
endef

LIBCAMERA_POST_BUILD_HOOKS += LIBCAMERA_BUILD_STRIP_IPA_SO

$(eval $(meson-package))
