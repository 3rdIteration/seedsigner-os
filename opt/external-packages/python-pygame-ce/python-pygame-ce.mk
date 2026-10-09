################################################################################
#
# python-pygame-ce
#
# Community Edition of pygame. The x86_64 desktop profile's display driver
# (seedsigner/hardware/displays/desktop_display.py) and keyboard/mouse input
# (seedsigner/hardware/buttons.py) are pygame-backed.
#
# Built with the meson infrastructure: since 2.5.x upstream builds with meson
# (the setuptools path is legacy), and the fork's meson-python backend needs
# meson-python + a meson >= 1.x toolchain anyway. pkg-config finds SDL2,
# SDL2_image, SDL2_mixer, SDL2_ttf and freetype2 in staging, so no dependency
# autodetection against host paths is involved.
#
################################################################################

PYTHON_PYGAME_CE_VERSION = 2.5.8
PYTHON_PYGAME_CE_SOURCE = pygame_ce-$(PYTHON_PYGAME_CE_VERSION).tar.gz
PYTHON_PYGAME_CE_SITE = https://files.pythonhosted.org/packages/26/2d/0f942ec31d558a6a1f2fd0df9965ff0055f165ed5b8d36f6509b1f3768a2
PYTHON_PYGAME_CE_LICENSE = LGPL-2.1+
# The sdist ships no top-level LICENSE file; PKG-INFO carries the license
# declaration and docs/licenses/ carries the bundled third-party texts.
PYTHON_PYGAME_CE_LICENSE_FILES = PKG-INFO
PYTHON_PYGAME_CE_DEPENDENCIES = \
	python3 \
	sdl2 \
	sdl2_image \
	sdl2_mixer \
	sdl2_ttf \
	freetype \
	host-python-cython

# -Dmidi=disabled: portmidi/porttime do not exist in buildroot.
# -Dstripped=true: keep docs/examples/tests/stubs out of the image.
# Never enable -Dctest: the ctest path resolves the bundled subprojects/unity
# wrap, which is a git wrap and would make meson reach for the network at
# configure time.
PYTHON_PYGAME_CE_CONF_OPTS = \
	-Dimage=enabled \
	-Dfont=enabled \
	-Dmixer=enabled \
	-Dfreetype=enabled \
	-Dmidi=disabled \
	-Dstripped=true

# Meson runs cython to generate the C sources for the _sdl2/pypm/audio/
# controller cython extensions. No explicit PATH override is needed: buildroot
# already has HOST_DIR/bin (host-python-cython installs bin/cython there) on
# PATH for both the meson setup step and ninja.

$(eval $(meson-package))
