#!/bin/bash
# Assemble the hybrid BIOS+EFI bootable USB image (seedsigner_os.img).
#
# Unlike the Pi/La Frite post-image scripts this fetches nothing: no diy-tools
# squashfs (x86_64 has no pinned build), no microsd-images seeds (the app
# reads those from inserted cards), no vendor bootloader blob. Everything it
# needs -- boot.img, grub.img, efi-part/, bzImage, rootfs.ext2 -- was produced
# by the build itself, with post-build.sh staging boot.img for us.

set -e

# mtools honours SOURCE_DATE_EPOCH when stamping FAT entries; build.sh exports
# it as 0 (epoch 1970), which buildroot's mtools wraps to 2098 -- a post-2038
# FAT date. Same clamp as the La Frite script keeps entries in range.
export SOURCE_DATE_EPOCH="1672575305"

BOARD_DIR="$(dirname "$0")"

# Sanity checks first: genimage happily produces a partitioned image out of
# missing pieces only for the inputs it opens late, so verify every artifact
# the boot chain needs before writing anything.
for f in boot.img grub.img efi-part/EFI/BOOT/bootx64.efi efi-part/EFI/BOOT/bootia32.efi bzImage rootfs.ext2; do
    if [ ! -f "${BINARIES_DIR}/${f}" ]; then
        echo "ERROR: missing build artifact ${BINARIES_DIR}/${f}" >&2
        exit 1
    fi
done

cp "${BOARD_DIR}/grub-bios.cfg" "${BINARIES_DIR}/grub-bios.cfg"
cp "${BOARD_DIR}/grub-efi.cfg" "${BINARIES_DIR}/grub-efi.cfg"
cp "${BOARD_DIR}/genimage-seedsigner.cfg" "${BINARIES_DIR}/genimage-seedsigner.cfg"

echo *****Generating Hybrid BIOS+EFI USB Image*****

cd buildroot
support/scripts/genimage.sh -c "${BINARIES_DIR}/genimage-seedsigner.cfg"

exit $?
