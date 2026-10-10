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

# Absolute board dir: buildroot invokes post-image scripts with CWD = the
# buildroot source tree and passes $0 relative to it, but resolve to an
# absolute path so the cp calls below never depend on that.
BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# buildroot's genimage wrapper resolves everything from the environment
# (BINARIES_DIR exported, BUILD_DIR from EXTRA_ENV) and takes the config via an
# absolute -c path, so it needs no particular CWD. Invoke it from wherever it
# actually lives: prefer the CWD buildroot source tree (the dir buildroot runs
# post-image scripts from, per board/pc/post-image-efi.sh), else fall back to
# the source tree located relative to this board directory (../../buildroot).
if [ -x "./support/scripts/genimage.sh" ]; then
	GENIMAGE_SH="./support/scripts/genimage.sh"
else
	GENIMAGE_SH="${BOARD_DIR}/../../buildroot/support/scripts/genimage.sh"
fi

"${GENIMAGE_SH}" -c "${BINARIES_DIR}/genimage-seedsigner.cfg"

exit $?
