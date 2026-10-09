#!/bin/sh

set -u
set -e

# Overlay dev-specific startup assets for MicroSD override / dropbear / udhcpc
cp -a "${BR2_EXTERNAL_RPI_SEEDSIGNER_PATH}/../rootfs-overlay-dev/." "${TARGET_DIR}/"

# Desktop boot instead of a plain getty: init respawns the launcher directly
# on tty1, giving it the controlling terminal X needs. Busybox init re-runs it
# when it exits (app crash or quit -> back into the app).
grep -qE '^tty1::respawn:/usr/bin/seedsigner-console$' ${TARGET_DIR}/etc/inittab || \
sed -i 's|^.*respawn:/sbin/getty.*$|tty1::respawn:/usr/bin/seedsigner-console|' ${TARGET_DIR}/etc/inittab

# The shared/dev overlay's /start.sh is superseded by the console launcher on
# this profile; keep it functional for manual invocation (S02seedsigner is
# removed below, so nothing runs it automatically -- X must own the VT, which
# a background init script cannot give it).
cat > "${TARGET_DIR}/start.sh" <<'EOF'
#!/bin/sh
exec /usr/bin/seedsigner-console
EOF
chmod 755 "${TARGET_DIR}/start.sh"

# eudev manages /dev here (X server + libinput require udev; the sd* mount
# rules live in the board overlay). The shared overlay's mdev daemon and the
# headless app-autostart script must not run alongside.
rm -f ${TARGET_DIR}/etc/init.d/S00mdev
rm -f ${TARGET_DIR}/etc/init.d/S02mdev
rm -f ${TARGET_DIR}/etc/init.d/S10mdev
rm -f ${TARGET_DIR}/etc/init.d/S02seedsigner

# Clean up files included in skeleton not needed
rm -f ${TARGET_DIR}/etc/init.d/S01syslogd
rm -f ${TARGET_DIR}/etc/init.d/S02klogd
rm -f ${TARGET_DIR}/etc/init.d/S02sysctl
rm -f ${TARGET_DIR}/etc/init.d/S20seedrng
rm -f ${TARGET_DIR}/etc/init.d/S40network
rm -f ${TARGET_DIR}/etc/init.d/S50pigpio

# Clean up test files included with numpy
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/numpy/tests
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/numpy/testing
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/numpy/core/tests
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/numpy/linalg/tests
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/numpy/f2py/tests
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/numpy/typing/tests

# Clean up files included in embit we don't need.
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/embit/liquid
# embit ships prebuilt libsecp256k1 shared libraries for every platform; this
# is the one x86_64 actually loads, so drop the others (inverse of the Pi
# profiles' cleanup, which keeps linux_aarch64 instead).
PREBUILT_SECP="${TARGET_DIR}/usr/lib/python3.12/site-packages/embit/util/prebuilt"
rm -f "${PREBUILT_SECP}/libsecp256k1_darwin_arm64.dylib"
rm -f "${PREBUILT_SECP}/libsecp256k1_darwin_x86_64.dylib"
rm -f "${PREBUILT_SECP}/libsecp256k1_linux_aarch64.so"
rm -f "${PREBUILT_SECP}/libsecp256k1_windows_amd64.dll"

# Clean up tests/docs in other python included libs
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/pyzbar/tests
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/qrcode/tests

# pygame-ce bundles its examples/tests inside the package when not built
# "stripped"; CONF_OPTS sets -Dstripped=true, this only clears leftovers of
# the doc tree meson-python may install.
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/pygame/docs
rm -rf ${TARGET_DIR}/usr/lib/python3.12/site-packages/pygame/tests

# Remove cryptography metadata that still builds non-deterministically as of 2025-11-11
rm -f ${TARGET_DIR}/usr/lib/python3.12/site-packages/cryptography-43.0.3.dist-info/RECORD

find "${TARGET_DIR}" -name '.DS_Store' -print0 | xargs -0 --no-run-if-empty rm -f

# Hand the BIOS bootstrap sector to genimage. grub.img (the i386-pc core) and
# the EFI binaries already land in BINARIES_DIR via grub2's install-images
# step; boot.img only reaches TARGET_DIR because
# BR2_TARGET_GRUB2_INSTALL_TOOLS=y, exactly like buildroot's own board/pc
# post-build.sh does for pc_x86_64_bios.
cp -f ${TARGET_DIR}/lib/grub/i386-pc/boot.img ${BINARIES_DIR}/boot.img

# Diagnostic aid (off by default): when SEEDSIGNER_ENABLE_ERROR_DIAGNOSTICS=1 is
# set in the build environment, ship the marker that enables the app's opt-in
# "Save to MicroSD" button on OS/package error screens (see seedsigner repo:
# helpers/seedsigner_os.py is_error_microsd_export_enabled()). Its presence is
# also flagged by the app's own hardening self-check.
if [ "${SEEDSIGNER_ENABLE_ERROR_DIAGNOSTICS:-0}" = "1" ]; then
    mkdir -p "${TARGET_DIR}/etc"
    touch "${TARGET_DIR}/etc/seedsigner-error-microsd-export"
fi

# Testing build, off by default: when SEEDSIGNER_TESTING_BUILD=1 is set in the
# build environment, ship the marker that swaps Home's menu for the hardware
# test menu (see seedsigner repo: helpers/seedsigner_os.py is_testing_build_enabled()).
if [ "${SEEDSIGNER_TESTING_BUILD:-0}" = "1" ]; then
    mkdir -p "${TARGET_DIR}/etc"
    touch "${TARGET_DIR}/etc/seedsigner-testing-build"
fi
