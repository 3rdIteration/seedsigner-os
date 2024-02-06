#!/bin/bash

echo *****Generating DIY-Tools Image*****

# Download DIY tools and package them into an image file for easy mounting
# Create Image File
mkdir ../tmp

cd ../tmp

mkdir diy

# Get Java
wget https://cdn.azul.com/zulu-embedded/bin/zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf.tar.gz
tar -xvzf zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf.tar.gz
rm ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf/src.zip
rm -R ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf/demo
rm -R ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf/sample
mv ./zulu8.74.0.17-ca-jdk8.0.392-linux_aarch32hf ./diy/jdk

# Get Ant
wget https://dlcdn.apache.org//ant/binaries/apache-ant-1.9.16-bin.tar.gz
tar -xvzf apache-ant-1.9.16-bin.tar.gz
mv ./apache-ant-1.9.16 ./diy/ant

# Get Satochip Source
git clone --depth 1 --recursive https://github.com/3rdIteration/Satochip-DIY.git
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
	--config "../pi02w-smartcard-dev/board/genimage-diy-tools.cfg"

cd ../

mv ./tmp/images/diy-tools.squashfs ./buildroot/output/images/diy-tools.squashfs

wget https://github.com/SeedSigner/seedsigner/releases/download/0.7.0/seedsigner_os.0.7.0.pi0.img

cp seedsigner_os.0.7.0.pi0.img ./buildroot/output/images/

wget https://github.com/SeedSigner/seedsigner/releases/download/0.7.0/seedsigner_os.0.7.0.pi02w.img

cp seedsigner_os.0.7.0.pi02w.img ./buildroot/output/images/

wget https://github.com/SeedSigner/seedsigner/releases/download/0.7.0/seedsigner_os.0.7.0.pi2.img

cp seedsigner_os.0.7.0.pi2.img ./buildroot/output/images/

wget https://github.com/SeedSigner/seedsigner/releases/download/0.7.0/seedsigner_os.0.7.0.pi4.img

cp seedsigner_os.0.7.0.pi4.img ./buildroot/output/images/

rm -R -f ./tmp/

cd buildroot

# Create main system image 
echo *****Generating Main System Image*****

set -e

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