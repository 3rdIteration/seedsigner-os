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

# Get Java (aarch64 build for La Frite AML-S805X-AC)
# NOTE: Verify the SHA256 hash before use by downloading and running:
#   sha256sum zulu8.74.0.17-ca-jdk8.0.392-linux_aarch64.tar.gz
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
	--config "../lafrite-smartcard-dev/board/genimage-diy-tools.cfg"

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

rm -R -f ./tmp/

# Download pre-built La Frite bootloader (BL2+BL31+BL33 combined, Amlogic GXL encrypted)
# The Amlogic S805X bootrom requires a signed multi-stage image; a raw u-boot.bin alone won't boot.
# Source: https://github.com/3rdIteration/libretech-buildroot (board/librecomputer/genimage/bootloader.sh)
wget -nc -O "${BINARIES_DIR}/aml-s805x-ac" "https://boot.libre.computer/ci/aml-s805x-ac"
# Sanity-check that the bootloader is at least 100KB (per libretech-flash-tool verification)
BL_SIZE=$(stat -c %s "${BINARIES_DIR}/aml-s805x-ac")
if [ "${BL_SIZE}" -lt $((100 * 1024)) ]; then
  echo "ERROR: Downloaded bootloader is unexpectedly small (${BL_SIZE} bytes)" >&2
  exit 1
fi

cd buildroot

# Create main system image
echo *****Generating Main System Image*****

set -e

BOARD_DIR="$(dirname $0)"
BOARD_NAME="$(basename ${BOARD_DIR})"
GENIMAGE_CFG="${BOARD_DIR}/genimage-seedsigner.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# Copy extlinux boot configuration into the binaries directory for genimage
cp "${BOARD_DIR}/extlinux.conf" "${BINARIES_DIR}/extlinux.conf"

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
