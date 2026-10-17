#!/bin/bash
# Assemble the hybrid BIOS+EFI bootable USB image (seedsigner_os.img).
#
# Unlike the Pi/La Frite post-image scripts this fetches nothing: no diy-tools
# squashfs (x86_64 has no pinned build), no microsd-images seeds (the app
# reads those from inserted cards), no vendor bootloader blob. Everything it
# needs -- boot.img, grub.img, efi-part/, bzImage, rootfs.cpio.gz -- was produced
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
for f in boot.img grub.img efi-part/EFI/BOOT/bootx64.efi efi-part/EFI/BOOT/bootia32.efi bzImage rootfs.cpio.gz; do
    if [ ! -f "${BINARIES_DIR}/${f}" ]; then
        echo "ERROR: missing build artifact ${BINARIES_DIR}/${f}" >&2
        exit 1
    fi
done

cp "${BOARD_DIR}/grub-bios.cfg" "${BINARIES_DIR}/grub-bios.cfg"
cp "${BOARD_DIR}/grub-efi.cfg" "${BINARIES_DIR}/grub-efi.cfg"

# Size the ESP from what it has to hold: the kernel plus the whole rootfs
# initrd (several hundred MB, and it grows with every package), the EFI
# binaries, 5% for FAT overhead and 32 MiB of slack so the dev boot log and
# hand-edited grub.cfg always fit. Rounded up to whole MiB.
BOOT_BYTES=$(cat "${BINARIES_DIR}/bzImage" "${BINARIES_DIR}/rootfs.cpio.gz" \
    "${BINARIES_DIR}"/efi-part/EFI/BOOT/*.efi | wc -c)
BOOT_MIB=$(( (BOOT_BYTES * 105 / 100 + 1048575) / 1048576 + 32 ))
echo "ESP size: ${BOOT_MIB} MiB (payload ${BOOT_BYTES} bytes)"
sed "s/@BOOT_SIZE@/${BOOT_MIB}M/" "${BOARD_DIR}/genimage-seedsigner.cfg" \
    > "${BINARIES_DIR}/genimage-seedsigner.cfg"

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

# Pin the MBR disk signature and verify the layout the boot chain promises:
# one bootable ESP in table slot 1 and nothing else -- the rootfs travels as
# /rootfs.cpio.gz on the ESP and runs from RAM. genimage pins the same
# signature (disk-signature in genimage-seedsigner.cfg) but defaults to 0
# when unset, so re-pin it here idempotently -- same ba5eba11 constant the
# Pi/La Frite deterministic scripts use for their label-id. Nothing
# checksums these bytes (the MBR code's holes region starts exactly at 440,
# so grub's boot.img never owns them).
echo *****Pinning MBR disk signature and verifying partition table*****
python3 - "${BINARIES_DIR}/seedsigner_os.img" <<'PYEOF'
import struct
import sys

path = sys.argv[1]
DISK_SIGNATURE = 0xBA5EBA11
BOOT_PART_TYPE = 0xEF   # EFI System, table slot 1

with open(path, "r+b") as f:
    f.seek(0x1B8)
    f.write(struct.pack("<I", DISK_SIGNATURE))

with open(path, "rb") as f:
    f.seek(0x1B8)
    sig = struct.unpack("<I", f.read(4))[0]
    f.seek(0x1BE)
    table = f.read(64)
    f.seek(0x1FE)
    bootmark = struct.unpack("<H", f.read(2))[0]

types = [table[i * 16 + 4] for i in range(4)]
print(
    "MBR disk signature 0x{0:08x}, boot mark 0x{1:04x}, partition types {2}".format(
        sig, bootmark, [hex(t) for t in types]
    )
)

if sig != DISK_SIGNATURE:
    sys.exit("ERROR: failed to write MBR disk signature")
if bootmark != 0xAA55:
    sys.exit("ERROR: missing 0x55AA MBR boot mark")
if types != [BOOT_PART_TYPE, 0, 0, 0]:
    sys.exit(
        "ERROR: unexpected partition layout {0}; expected a single ESP in "
        "slot 1 (the rootfs is /rootfs.cpio.gz on it)".format(
            [hex(t) for t in types]
        )
    )
PYEOF

exit $?
