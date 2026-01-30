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
git clone --depth 1 --recursive --branch 20250310 https://github.com/3rdIteration/Satochip-DIY.git
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
	--config "../pi4-smartcard-dev/board/genimage-diy-tools.cfg"

cd ../

sha256sum ./tmp/images/diy-tools.squashfs

mv ./tmp/images/diy-tools.squashfs ${BINARIES_DIR}

wget https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi0.img
mv seedsigner_os.0.8.6.pi0.img ${BINARIES_DIR}

wget https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi02w.img
mv seedsigner_os.0.8.6.pi02w.img ${BINARIES_DIR}

wget https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi2.img
mv seedsigner_os.0.8.6.pi2.img ${BINARIES_DIR}

wget https://github.com/SeedSigner/seedsigner/releases/download/0.8.6/seedsigner_os.0.8.6.pi4.img
mv seedsigner_os.0.8.6.pi4.img ${BINARIES_DIR}

wget https://github.com/Toporin/Seedkeeper-Applet/releases/download/v0.2-0.1/SeedKeeper-v0.2-0.1.cap
mv SeedKeeper-v0.2-0.1.cap ${BINARIES_DIR}

wget https://github.com/Toporin/SatochipApplet/releases/download/v0.12/SatoChip-0.12-05.cap
mv SatoChip-0.12-05.cap ${BINARIES_DIR}

wget https://github.com/Toporin/Satodime-Applet/releases/download/v0.1-0.2/Satodime-0.1-0.2.cap
mv Satodime-0.1-0.2.cap ${BINARIES_DIR}

wget https://github.com/cryptoadvance/specter-javacard/releases/download/v0.1.0/MemoryCardApplet.cap
mv MemoryCardApplet.cap ${BINARIES_DIR}

wget https://github.com/DangerousThings/flexsecure-applets/releases/download/v0.18.9/vivokey-otp.cap
mv vivokey-otp.cap ${BINARIES_DIR}

wget https://github.com/github-af/SmartPGP/releases/download/v1.22.2-3.0.4/SmartPGP-v1.22.2-jc304-rsa_up_to_2048.cap
mv SmartPGP-v1.22.2-jc304-rsa_up_to_2048.cap ${BINARIES_DIR}/SmartPGP-RSA2048.cap

wget https://github.com/github-af/SmartPGP/releases/download/v1.22.2-3.0.4/SmartPGP-v1.22.2-jc304-rsa_up_to_4096.cap
mv SmartPGP-v1.22.2-jc304-rsa_up_to_4096.cap ${BINARIES_DIR}/SmartPGP-RSA4096.cap

# Get Waveshare 2.8" DPI overlays
WAVESHARE_OVERLAYS_DIR="${BR2_EXTERNAL_RPI_SEEDSIGNER_PATH}/../waveshare-overlays"
WAVESHARE_OVERLAYS_ZIP_URL_DEFAULT="https://files.waveshare.com/wiki/2.8inc-DPI-LCD/28DPI-DTBO.zip"
WAVESHARE_OVERLAYS_ZIP_URL="${WAVESHARE_OVERLAYS_ZIP_URL:-${WAVESHARE_OVERLAYS_ZIP_URL_DEFAULT}}"
if [ -n "${WAVESHARE_OVERLAYS_ZIP_URL:-}" ] && [ ! -d "${WAVESHARE_OVERLAYS_DIR}" ]; then
	mkdir -p "${WAVESHARE_OVERLAYS_DIR}"
	tmp_zip="$(mktemp)"
	echo "Downloading Waveshare overlays from ${WAVESHARE_OVERLAYS_ZIP_URL}"
	wget -O "${tmp_zip}" "${WAVESHARE_OVERLAYS_ZIP_URL}"
	python - <<'PY' "${tmp_zip}" "${WAVESHARE_OVERLAYS_DIR}"
import sys
import zipfile
zip_path = sys.argv[1]
out_dir = sys.argv[2]
targets = {
    "waveshare-28dpi-3b-4b.dtbo",
    "waveshare-28dpi-3b.dtbo",
    "waveshare-touch-28dpi.dtbo",
}
with zipfile.ZipFile(zip_path) as zf:
    for name in zf.namelist():
        base = name.rsplit("/", 1)[-1]
        if base in targets:
            zf.extract(name, out_dir)
PY
	find "${WAVESHARE_OVERLAYS_DIR}" -name "waveshare-28dpi-*.dtbo" -o -name "waveshare-touch-28dpi.dtbo" | while read -r overlay; do
		mv "${overlay}" "${WAVESHARE_OVERLAYS_DIR}/"
	done
	rm -f "${tmp_zip}"
fi

if [ -d "${WAVESHARE_OVERLAYS_DIR}" ]; then
	mkdir -p "${BINARIES_DIR}/rpi-firmware/overlays"
	for overlay in waveshare-28dpi-3b-4b.dtbo waveshare-28dpi-3b.dtbo waveshare-touch-28dpi.dtbo; do
		if [ -f "${WAVESHARE_OVERLAYS_DIR}/${overlay}" ]; then
			cp "${WAVESHARE_OVERLAYS_DIR}/${overlay}" "${BINARIES_DIR}/rpi-firmware/overlays/${overlay}"
		fi
	done
fi

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
