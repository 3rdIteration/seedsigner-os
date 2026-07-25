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

echo *****Generating DIY-Tools Image*****

# Download DIY tools and package them into an image file for easy mounting
mkdir ../tmp

cd ../tmp

mkdir diy

# Get Java (aarch64 build for La Frite AML-S805X-AC)
download_and_verify "https://cdn.azul.com/zulu/bin/zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64.tar.gz" "c4449d28499f92213ae7b5ffc5c970b0947933e3fbd81a5612bb4071831c2b46"
tar -xvzf zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64.tar.gz
rm ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64/src.zip
rm -R ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64/demo
rm -R ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64/sample
mv ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64 ./diy/jdk

# Get Ant
download_and_verify "https://dlcdn.apache.org//ant/binaries/apache-ant-1.9.16-bin.tar.gz" "7db54556acf6d5654bf3e2882e3ff45220dea689160ac2e5964ac94635843df8"
tar -xvzf apache-ant-1.9.16-bin.tar.gz
mv ./apache-ant-1.9.16 ./diy/ant

# Get Satochip Source
git clone --depth 1 --recursive --branch 20250310 https://github.com/3rdIteration/Satochip-DIY.git
verify_git_head "./Satochip-DIY" "b8f1334b07c2ad3552548bd8659fa2714c19d55e"
rm -R -f ./Satochip-DIY/.git
rm -R ./Satochip-DIY/applets/seedkeeper-thd89/sdks
rm -R ./Satochip-DIY/applets/satodime-thd89/sdks
rm -R ./Satochip-DIY/applets/satochip-thd89/sdks
rm -R ./Satochip-DIY/applets/satochip/gp.exe
rm -R ./Satochip-DIY/applets/satodime/gp.exe
rm -R ./Satochip-DIY/applets/satochip-thd89/gp.exe
rm -R ./Satochip-DIY/applets/satodime-thd89/gp.exe
rm -R ./Satochip-DIY/gp.exe
rm -R -f ./Satochip-DIY/sdks/jc211_kit
rm -R -f ./Satochip-DIY/sdks/jc212_kit
rm -R -f ./Satochip-DIY/sdks/jc221_kit
rm -R -f ./Satochip-DIY/sdks/jc222_kit
rm -R -f ./Satochip-DIY/sdks/jc303_kit
rm -R -f ./Satochip-DIY/sdks/jc305u1_kit
rm -R -f ./Satochip-DIY/sdks/jc305u2_kit
rm -R -f ./Satochip-DIY/sdks/jc305u3_kit
rm -R -f ./Satochip-DIY/sdks/jc305u4_kit
rm -R -f ./Satochip-DIY/sdks/jc310b43_kit
rm -R -f ./Satochip-DIY/sdks/jc310r20210706_kit
mv ./Satochip-DIY ./diy/Satochip-DIY

genimage \
	--rootpath ./diy   \
	--config "../lafrite-smartcard/board/genimage-diy-tools.cfg"

cd ../

sha256sum ./tmp/images/diy-tools.squashfs

mv ./tmp/images/diy-tools.squashfs ${BINARIES_DIR}

rm -R -f ./tmp/

# Download pre-built La Frite bootloader (BL2+BL31+BL33 combined, Amlogic GXL encrypted)
# The Amlogic S805X bootrom requires a signed multi-stage image; a raw u-boot.bin alone won't boot.
# Source: https://github.com/3rdIteration/libretech-buildroot (board/librecomputer/genimage/bootloader.sh)
download_and_verify "https://boot.libre.computer/ci/aml-s805x-ac" "b539cb79bc2246953d27b87f8fd6481ca8cbb013fc12ce36c233e23fa725c865" "${BINARIES_DIR}/aml-s805x-ac"
# Sanity-check that the bootloader is at least 100KB (per libretech-flash-tool verification)
BL_SIZE=$(stat -c %s "${BINARIES_DIR}/aml-s805x-ac")
if [ "${BL_SIZE}" -lt $((100 * 1024)) ]; then
  echo "ERROR: Downloaded bootloader is unexpectedly small (${BL_SIZE} bytes)" >&2
  exit 1
fi

cd buildroot

# Create main system image with deterministic output (reproducible builds)
echo *****Generating Main System Image*****

set -e

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Write Amlogic bootloader at sector 1 (offset 512 bytes) - required by S805X bootrom
dd if=${BINARIES_DIR}/aml-s805x-ac of=disk.img bs=512 seek=1 conv=notrunc status=none

# Create boot partition.
START=$(/sbin/fdisk -l -o Start disk.img|tail -n 1)
SECTORS=$(/sbin/fdisk -l -o Sectors disk.img|tail -n 1)
### needed: apt install dosfstools
/sbin/mkfs.vfat --invariant -i ba5eba11 -n SEEDSIGNROS disk.img --offset $START $(sectorsToBlocks $SECTORS)
OFFSET=$(sectorsToBytes $START)

# Copy boot files.
# boot/extlinux is created empty to establish the ::extlinux dir in the image;
# extlinux.conf is staged in a top-level extlinux/ dir and mcopied in below
# (mirrors the overlays/microsd-images handling in the pi profiles).
mkdir -p boot/extlinux extlinux
cp ${BINARIES_DIR}/Image boot/Image
cp ${BINARIES_DIR}/meson-gxl-s805x-libretech-ac.dtb boot/meson-gxl-s805x-libretech-ac.dtb
cp ${BOARD_DIR}/extlinux.conf extlinux/extlinux.conf

# Copy DIY Tools Image
cp ${BINARIES_DIR}/diy-tools.squashfs boot/diy-tools.squashfs

# Create empty javacard-cap directory
mkdir -p boot/javacard-cap

chmod 0755 `find boot extlinux javacard-cap`
touch -d "${disk_timestamp}" `find boot extlinux javacard-cap`
### needed: apt install mtools
mcopy -bpm -i "disk.img@@$OFFSET" boot/* ::
# mcopy doesn't copy directories deterministically, so rely on sorted shell globbing instead.
mcopy -bpm -i "disk.img@@$OFFSET" extlinux/* ::extlinux
mv disk.img ${BASE_DIR}/images/seedsigner_os.img

cd -
