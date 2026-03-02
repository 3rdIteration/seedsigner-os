#!/bin/sh

set -u
set -e

# Overlay dev-specific startup script for MicroSD override and networking helpers
cp -a "${BR2_EXTERNAL_RPI_SEEDSIGNER_PATH}/../rootfs-overlay-dev/." "${TARGET_DIR}/"

# Add a console on tty1
if [ -e ${TARGET_DIR}/etc/inittab ]; then
        # if 'tty1::' is not found in inittab, then replace the line containing GENERIC_SERIAL with
        # 'console::respawn:-/bin/sh' + 'tty1::respawn:-/bin/sh'
        grep -qE '^tty1::' ${TARGET_DIR}/etc/inittab || \
	sed -i '/GENERIC_SERIAL/c\
console::respawn:-/bin/sh\
tty1::respawn:-/bin/sh' ${TARGET_DIR}/etc/inittab
fi

# Adding symlink to support upgrade of buildroot python3.10 to python3.12
ln -srf ${TARGET_DIR}/usr/lib/python3.12 ${TARGET_DIR}/usr/lib/python3.10
ln -srf ${TARGET_DIR}/usr/lib/python3.12 ${TARGET_DIR}/usr/lib/python3
ln -srf ${BUILD_DIR}/python3-3.12.10 ${BUILD_DIR}/python3-3.10.10
ln -srf ${BUILD_DIR}/python3-3.12.10 ${BUILD_DIR}/python3

# Clean up test files included with numpy
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/testing
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/core/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/linalg/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/f2py/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/typing/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/ma/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/lib/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/numpy/random/tests/

# Clean up files included in embit we don't need
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/embit/liquid
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/embit/util/prebuilt/libsecp256k1_darwin_arm64.dylib
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/embit/util/prebuilt/libsecp256k1_darwin_x86_64.dylib
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/embit/util/prebuilt/libsecp256k1_linux_aarch64.so
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/embit/util/prebuilt/libsecp256k1_linux_x86_64.so
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/embit/util/prebuilt/libsecp256k1_windows_amd64.dll

# Clean up tests/docs in other python included libs
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/pyzbar/tests
rm -rf ${TARGET_DIR}/usr/lib/python3/site-packages/qrcode/tests

find "${TARGET_DIR}" -name '.DS_Store' -print0 | xargs -0 --no-run-if-empty rm -f

# Add python byte code (aka __pycache__ directories) to increase boot and import module speed
SOURCE_DATE_EPOCH=1 PYTHONHASHSEED=0 ${HOST_DIR}/bin/python3.12 \
  "${BUILD_DIR}/python3-3.12.10/Lib/compileall.py" \
  -f --invalidation-mode=checked-hash "${TARGET_DIR}/opt/src"
