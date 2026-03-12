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
	--config "../pi4-smartcard-dev/board/genimage-diy-tools.cfg"

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

download_and_verify "https://github.com/Toporin/Seedkeeper-Applet/releases/download/v0.2-0.1/SeedKeeper-v0.2-0.1.cap" "28dbae3c7c130a6f7d0e6d05f41386ffd93976fd290eaa5d8db708b9903dabcd"
mv SeedKeeper-v0.2-0.1.cap ${BINARIES_DIR}

download_and_verify "https://github.com/Toporin/SatochipApplet/releases/download/v0.12/SatoChip-0.12-05.cap" "b608d1a1a53956d58e53e1aceb417a10d3492fa744528a08904eb0b068e293ce"
mv SatoChip-0.12-05.cap ${BINARIES_DIR}

download_and_verify "https://github.com/Toporin/Satodime-Applet/releases/download/v0.1-0.2/Satodime-0.1-0.2.cap" "d106503ae273a6f9193f9a6199e3565b0e02d3dd2ad57aa313a1ea16143197d9"
mv Satodime-0.1-0.2.cap ${BINARIES_DIR}

download_and_verify "https://github.com/cryptoadvance/specter-javacard/releases/download/v0.1.0/MemoryCardApplet.cap" "5f855f0c490402ac2f1e4cb1fc39cf6e4ce3d633fcb407fe024d275677f0efb4"
mv MemoryCardApplet.cap ${BINARIES_DIR}

download_and_verify "https://github.com/DangerousThings/flexsecure-applets/releases/download/v0.18.9/vivokey-otp.cap" "f2b7909a75a15f93aae5fa1c1c3bfe69cc613f3a74072db6c25e57b5423f16e0"
mv vivokey-otp.cap ${BINARIES_DIR}

download_and_verify "https://github.com/github-af/SmartPGP/releases/download/v1.22.2-3.0.4/SmartPGP-v1.22.2-jc304-rsa_up_to_2048.cap" "9aa779f3615083b02df0acd1eb7268e370c9fefee99727581c8560c7efeafa09"
mv SmartPGP-v1.22.2-jc304-rsa_up_to_2048.cap ${BINARIES_DIR}/SmartPGP-RSA2048.cap

download_and_verify "https://github.com/github-af/SmartPGP/releases/download/v1.22.2-3.0.4/SmartPGP-v1.22.2-jc304-rsa_up_to_4096.cap" "8df7523e24117e0d3a289f511179b25b82b1bc1df39c203f03b21c568ac2b6b8"
mv SmartPGP-v1.22.2-jc304-rsa_up_to_4096.cap ${BINARIES_DIR}/SmartPGP-RSA4096.cap

# Get Waveshare 2.8" DPI overlays
WAVESHARE_OVERLAYS_DIR="${BR2_EXTERNAL_RPI_SEEDSIGNER_PATH}/../waveshare-overlays"
WAVESHARE_OVERLAYS_ZIP_URL_DEFAULT="https://files.waveshare.com/wiki/2.8inc-DPI-LCD/28DPI-DTBO.zip"
WAVESHARE_OVERLAYS_ZIP_URL="${WAVESHARE_OVERLAYS_ZIP_URL:-${WAVESHARE_OVERLAYS_ZIP_URL_DEFAULT}}"
WAVESHARE_OVERLAYS_FILES="waveshare-28dpi-3b-4b.dtbo waveshare-28dpi-3b.dtbo waveshare-touch-28dpi.dtbo"
missing_overlays=0
for overlay in ${WAVESHARE_OVERLAYS_FILES}; do
	if [ ! -f "${WAVESHARE_OVERLAYS_DIR}/${overlay}" ]; then
		missing_overlays=1
	fi
done

if [ -n "${WAVESHARE_OVERLAYS_ZIP_URL:-}" ] && [ "${missing_overlays}" -eq 1 ]; then
	mkdir -p "${WAVESHARE_OVERLAYS_DIR}"
	tmp_zip="$(mktemp)"
	echo "Downloading Waveshare overlays from ${WAVESHARE_OVERLAYS_ZIP_URL}"
	wget -O "${tmp_zip}" "${WAVESHARE_OVERLAYS_ZIP_URL}"
	echo "Extracting Waveshare overlays into ${WAVESHARE_OVERLAYS_DIR}"
	for overlay in ${WAVESHARE_OVERLAYS_FILES}; do
		unzip -j "${tmp_zip}" "*/${overlay}" -d "${WAVESHARE_OVERLAYS_DIR}"
	done
	rm -f "${tmp_zip}"
elif [ "${missing_overlays}" -eq 0 ]; then
	echo "Waveshare overlays already present in ${WAVESHARE_OVERLAYS_DIR}"
fi

if [ -d "${WAVESHARE_OVERLAYS_DIR}" ]; then
	echo "Copying Waveshare overlays into ${BINARIES_DIR}/rpi-firmware/overlays"
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
