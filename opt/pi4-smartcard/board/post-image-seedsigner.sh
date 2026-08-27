#!/bin/bash

set -e

check_sha256() {
  local file="$1"
  local expected_sha256="$2"

  echo "${expected_sha256}  ${file}" | sha256sum -c -
}

download_and_verify() {
  local url="$1"
  local expected_sha256="$2"
  local output_file="${3:-$(basename "${url}")}"

  wget -O "${output_file}" "${url}"
  check_sha256 "${output_file}" "${expected_sha256}"
}

verify_git_head() {
  local repo_dir="$1"
  local expected_commit="$2"
  local actual_commit

  actual_commit="$(git -C "${repo_dir}" rev-parse HEAD)"
  if [ "${actual_commit}" != "${expected_commit}" ]; then
    echo "ERROR: Unexpected commit for ${repo_dir}: ${actual_commit} (expected ${expected_commit})" >&2
    exit 1
  fi
}

echo *****Fetching DIY-Tools Image*****

# The diy-tools squashfs is built reproducibly by the seedsigner-diy-tools repo
# and published as a tagged GitHub Release. Download the prebuilt artifact and
# verify it against the pinned hash in opt/rootfs-overlay/etc/diy-tools.sha256
# (the same hash mdev.sh re-checks at runtime before mounting).
DIY_ARCH="armhf"
DIY_TAG="v1.0.0"
DIY_HASH_FILE="$(cd "$(dirname "$0")/../../rootfs-overlay" && pwd)/etc/diy-tools.sha256"
DIY_HASH="$(awk -F: -v a="${DIY_ARCH}" '$1==a{print $2}' "${DIY_HASH_FILE}")"
if [ -z "${DIY_HASH}" ]; then
  echo "ERROR: no pinned diy-tools hash for arch ${DIY_ARCH} in ${DIY_HASH_FILE}" >&2
  exit 1
fi

DIY_TMP="$(mktemp -d)"
( cd "${DIY_TMP}" && download_and_verify "https://github.com/3rdIteration/seedsigner-diy-tools/releases/download/${DIY_TAG}/diy-tools-${DIY_ARCH}.squashfs" "${DIY_HASH}" "diy-tools.squashfs" )
mv "${DIY_TMP}/diy-tools.squashfs" "${BINARIES_DIR}/diy-tools.squashfs"
rm -rf "${DIY_TMP}"
cd "$(dirname "$0")/../.."


download_and_verify "https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi0.img" "da32ce21f185404ccefd58e76e55ae7f1ac9fe2df2100bc7bbab3e03c5d71b6d"
mv seedsigner_os.0.8.6.pi0.img ${BINARIES_DIR}

download_and_verify "https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi02w.img" "d1669ad3aec6046dc43a673056a258e00c389ce23fa0ff754378cd0267516888"
mv seedsigner_os.0.8.6.pi02w.img ${BINARIES_DIR}

download_and_verify "https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi2.img" "029ecacc6ba45ae23cb953d7111cf98b0689f1eefb1cee101300acb10167b098"
mv seedsigner_os.0.8.6.pi2.img ${BINARIES_DIR}

download_and_verify "https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi4.img" "47879ded57a91ecf46dbb44825699c53550bbf5aa6aa7c5b6519913a8863d157"
mv seedsigner_os.0.8.6.pi4.img ${BINARIES_DIR}

rm -R -f ./tmp/

cd buildroot

# Create main system image 
echo *****Generating Main System Image*****

set -e

sectorsToBlocks() {
  echo $(( ( "$1" * 512 ) / 1024 ))
}

sectorsToBytes() {
  echo $(( "$1" * 512 ))
}

export disk_timestamp="2023/01/01T12:15:05"

rm -rf ${BUILD_DIR}/custom_image
mkdir -p ${BUILD_DIR}/custom_image
cd ${BUILD_DIR}/custom_image

# Create disk image.
dd if=/dev/zero of=disk.img bs=1M count=512 #512 MB

### needed: apt install fdisk
/sbin/sfdisk disk.img <<EOF
  label: dos
  label-id: 0xba5eba11

  disk.img1 : type=c, bootable
EOF

# Create boot partition.
START=$(/sbin/fdisk -l -o Start disk.img|tail -n 1)
SECTORS=$(/sbin/fdisk -l -o Sectors disk.img|tail -n 1)
### needed: apt install dosfstools
/sbin/mkfs.vfat --invariant -i ba5eba11 -n SEEDSIGNROS disk.img --offset $START $(sectorsToBlocks $SECTORS)
OFFSET=$(sectorsToBytes $START)

# Copy boot files.
mkdir -p boot/overlays overlays
cp ${BASE_DIR}/images/rpi-firmware/cmdline.txt boot/cmdline.txt
cp ${BASE_DIR}/images/rpi-firmware/config.txt boot/config.txt
cp ${BASE_DIR}/images/rpi-firmware/bootcode.bin boot/bootcode.bin
cp ${BASE_DIR}/images/rpi-firmware/fixup4x.dat boot/fixup4x.dat
cp ${BASE_DIR}/images/rpi-firmware/start4x.elf boot/start4x.elf
cp ${BASE_DIR}/images/rpi-firmware/overlays/* overlays/
cp ${BASE_DIR}/images/*.dtb boot/
cp ${BASE_DIR}/images/zImage boot/zImage

# Copy DIY Tools Image
cp ${BINARIES_DIR}/diy-tools.squashfs boot/diy-tools.squashfs

# Copy Seedsigner Images
mkdir -p boot/microsd-images microsd-images
cp ${BINARIES_DIR}/seedsigner_os.0.8.6.pi0.img microsd-images/seedsigner_os.0.8.6.pi0.img
cp ${BINARIES_DIR}/seedsigner_os.0.8.6.pi02w.img microsd-images/seedsigner_os.0.8.6.pi02w.img
cp ${BINARIES_DIR}/seedsigner_os.0.8.6.pi2.img microsd-images/seedsigner_os.0.8.6.pi2.img
cp ${BINARIES_DIR}/seedsigner_os.0.8.6.pi4.img microsd-images/seedsigner_os.0.8.6.pi4.img

# Create empty javacard-cap directory
mkdir -p boot/javacard-cap

chmod 0755 `find boot overlays microsd-images javacard-cap`
touch -d "${disk_timestamp}" `find boot overlays microsd-images javacard-cap`
### needed: apt install mtools
mcopy -bpm -i "disk.img@@$OFFSET" boot/* ::
# mcopy doesn't copy directories deterministically, so rely on sorted shell globbing instead.
mcopy -bpm -i "disk.img@@$OFFSET" overlays/* ::overlays
mcopy -bpm -i "disk.img@@$OFFSET" microsd-images/* ::microsd-images
mv disk.img ${BASE_DIR}/images/seedsigner_os.img

cd -