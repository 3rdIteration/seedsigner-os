#!/bin/bash

set -e

# Dev images are assembled with genimage, which populates the FAT boot partition
# via mtools. mtools honors SOURCE_DATE_EPOCH; build.sh exports it as 0 (epoch
# 1970), and the buildroot mtools wraps that pre-1980 date to 2098 on FAT. A
# post-2038 FAT timestamp makes stat() return EOVERFLOW on the 32-bit kernel,
# which hides every boot file (and breaks diy-tools mounting). Pin a safe
# in-range epoch so FAT dates stay before 2038.
export SOURCE_DATE_EPOCH="1672575305"

BOARD_DIR="$(dirname $0)"
BOARD_NAME="$(basename ${BOARD_DIR})"
GENIMAGE_CFG="${BOARD_DIR}/genimage-rpi-seedsigner.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# Pass an empty rootpath. genimage makes a full copy of the given rootpath to
# ${GENIMAGE_TMP}/root so passing TARGET_DIR would be a waste of time and disk
# space. We don't rely on genimage to build the rootfs image, just to insert a
# pre-built one in the disk image.

trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"

rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}"   \
	--tmppath "${GENIMAGE_TMP}"    \
	--inputpath "${BINARIES_DIR}"  \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"

exit $?
