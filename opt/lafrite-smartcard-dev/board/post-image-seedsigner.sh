#!/bin/sh

set -u
set -e

# Generate the standard La Frite image and then expose it with SeedSigner naming.
"${BASE_DIR}/support/scripts/genimage.sh" \
  -c "${BASE_DIR}/board/librecomputer/lafrite/genimage.cfg"

cp "${BINARIES_DIR}/usb.img" "${BINARIES_DIR}/seedsigner_os.img"
