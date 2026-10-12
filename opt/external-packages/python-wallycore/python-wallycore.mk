################################################################################
#
# python-wallycore
#
################################################################################

# Must match wallycore== in the SeedSigner app's requirements.txt.
PYTHON_WALLYCORE_VERSION = 1.5.6
PYTHON_WALLYCORE_SOURCE = wallycore-$(PYTHON_WALLYCORE_VERSION).tar.gz
PYTHON_WALLYCORE_SITE = https://files.pythonhosted.org/packages/dd/f1/cc75bc4af58d0769693171a5d085ae01a047f839a1e2b802399890f0159a
PYTHON_WALLYCORE_LICENSE = MIT
PYTHON_WALLYCORE_LICENSE_FILES = LICENSE
PYTHON_WALLYCORE_SETUP_TYPE = setuptools

# The sdist builds one amalgamated C file (libwally + libsecp256k1-zkp) as the
# extension module; only src/config.h is platform specific. setup.py would
# regenerate it by running autogen + configure natively, i.e. for the build
# host. Instead configure is run here for the target, and setup.py is told to
# leave its result alone (see the 0001 patch). Nothing is linked from it: the
# library itself is compiled by setuptools with the target toolchain.
PYTHON_WALLYCORE_ENV = WALLY_SKIP_AUTOTOOLS=1

define PYTHON_WALLYCORE_CONFIGURE_FOR_TARGET
	cd $(@D) && $(TARGET_CONFIGURE_OPTS) ./configure \
		--host=$(GNU_TARGET_NAME) \
		--build=$(GNU_HOST_NAME) \
		--with-pic \
		--disable-shared \
		--enable-static \
		--disable-swig-python \
		--disable-swig-java \
		--disable-tests \
		--disable-dependency-tracking
endef
PYTHON_WALLYCORE_PRE_BUILD_HOOKS += PYTHON_WALLYCORE_CONFIGURE_FOR_TARGET

$(eval $(python-package))
