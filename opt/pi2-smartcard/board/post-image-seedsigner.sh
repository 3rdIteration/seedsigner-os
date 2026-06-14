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
# Create Image File
mkdir ../tmp

cd ../tmp

mkdir diy

# Get Java
download_and_verify "https://cdn.azul.com/zulu-embedded/bin/zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf.tar.gz" "9d7c46b836094ea5b805eda88a79e19171d7256130a6968e2324da838b546217"
tar -xvzf zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf.tar.gz
rm ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf/src.zip
rm -R ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf/demo
rm -R ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf/sample
mv ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf ./diy/jdk

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
	--config "../pi2-smartcard/board/genimage-diy-tools.cfg"

cd ../

sha256sum ./tmp/images/diy-tools.squashfs

mv ./tmp/images/diy-tools.squashfs ${BINARIES_DIR}

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
cp ${BASE_DIR}/images/rpi-firmware/fixup_x.dat boot/fixup_x.dat
cp ${BASE_DIR}/images/rpi-firmware/start_x.elf boot/start_x.elf
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