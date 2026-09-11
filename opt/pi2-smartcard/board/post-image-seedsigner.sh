#!/bin/bash

set -e

check_sha256() {
  local file="$1"
  local expected_sha256="$2"

  echo "${expected_sha256}  ${file}" | sha256sum -c -
}

# Everything this script fetches -- the prebuilt diy-tools squashfs, the four
# seedsigner_os release images, and (on La Frite) the bootloader -- comes
# straight off a CDN on every build and is thrown away with the container. Those
# CDNs do go down: an Apache 503 failed the La Frite build outright in run
# 32726173869. Keep the downloads in buildroot's download dir, which CI mounts
# from the host and caches, so a repeat build reuses them instead of re-fetching.
# BR2_DL_DIR is exported to post-image scripts by buildroot's EXTRA_ENV.
#
# The cached copy is checksummed before use exactly like a fresh download, so a
# truncated or tampered file falls back to downloading rather than being
# trusted. Caching changes where the bytes come from, never whether they are
# verified.
download_and_verify() {
  local url="$1"
  local expected_sha256="$2"
  local output_file="${3:-$(basename "${url}")}"
  local cache_dir="${BR2_DL_DIR:-/buildroot_dl}/seedsigner-post-image"
  # Named after the URL, not output_file: every board writes the squashfs to the
  # same "diy-tools.squashfs", but armhf and aarch64 are different artifacts and
  # the download cache is a single entry shared across the whole matrix -- so
  # keying on the output name has the boards overwriting each other's copy every
  # run. No URL fetched here carries a query string.
  local cached="${cache_dir}/$(basename "${url}")"

  if [ -f "${cached}" ] && echo "${expected_sha256}  ${cached}" | sha256sum -c --status -; then
    echo "Using cached $(basename "${url}") from ${cache_dir}"
    cp "${cached}" "${output_file}"
    return 0
  fi

  wget -O "${output_file}" "${url}"

  # Explicit rather than leaning on "set -e": this function no longer ends with
  # the checksum, so without this a mismatch would be masked by the exit status
  # of the caching copy below, and the bad file would be cached to boot.
  if ! check_sha256 "${output_file}" "${expected_sha256}"; then
    rm -f "${output_file}"
    return 1
  fi

  # Best-effort: the file is downloaded and verified by the time we get here, so
  # a read-only or full BR2_DL_DIR must warn, not fail the build under "set -e".
  # Write via a temp name so an interrupted job cannot leave a half-copied file
  # for the next run to find (it would fail the checksum, but re-download every
  # time until something overwrote it).
  if mkdir -p "${cache_dir}" 2>/dev/null && cp "${output_file}" "${cached}.$$" 2>/dev/null; then
    mv -f "${cached}.$$" "${cached}" || rm -f "${cached}.$$"
  else
    rm -f "${cached}.$$" 2>/dev/null || true
    echo "warning: could not cache $(basename "${url}") in ${cache_dir}" >&2
  fi

  return 0
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