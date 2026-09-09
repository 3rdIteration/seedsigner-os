#!/bin/bash

set -e

# Dev images are assembled with genimage, which populates the FAT boot partition
# via mtools. mtools honors SOURCE_DATE_EPOCH; build.sh exports it as 0 (epoch
# 1970), and the buildroot mtools wraps that pre-1980 date to 2098 on FAT. A
# post-2038 FAT timestamp makes stat() return EOVERFLOW on the 32-bit kernel,
# which hides every boot file (and breaks diy-tools mounting). Pin a safe
# in-range epoch so FAT dates stay before 2038.
export SOURCE_DATE_EPOCH="1672575305"

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

# Create empty javacard-cap directory on the boot partition using mtools
### needed: apt install mtools
# Read partition 1 start sector from MBR (byte offset 454, little-endian uint32) and convert to byte offset
PARTITION_OFFSET=$(python3 -c "import struct; print(struct.unpack('<I', open('${BINARIES_DIR}/seedsigner_os.img','rb').read()[454:458])[0] * 512)")
MTOOLS_SKIP_CHECK=1 mmd -i "${BINARIES_DIR}/seedsigner_os.img@@${PARTITION_OFFSET}" ::javacard-cap

exit $?