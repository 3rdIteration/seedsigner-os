#!/bin/bash
# Test that the mtools commands in post-image scripts use correct partition syntax.
# Creates a synthetic disk image (MBR + FAT32 partition) matching what genimage produces,
# then runs each script's mtools command against it to verify correctness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
TMPDIR=""

cleanup() {
  if [ -n "${TMPDIR}" ] && [ -d "${TMPDIR}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

check_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "SKIP: '$cmd' not found — install mtools, dosfstools, and sfdisk to run these tests" >&2
    exit 0
  fi
}

# Verify required tools are available
for cmd in dd mkfs.vfat mmd mdir mtoolstest sfdisk python3; do
  check_cmd "$cmd"
done

TMPDIR="$(mktemp -d)"
SYNTHETIC_IMG="${TMPDIR}/seedsigner_os.img"
BINARIES_DIR="${TMPDIR}"

echo "=== Creating synthetic disk image (MBR + FAT32 partition) ==="

# Create a 256 MiB image file filled with zeros
dd if=/dev/zero of="${SYNTHETIC_IMG}" bs=1M count=256 status=none

# Create an MBR partition table with a single FAT32 (type 0xC) partition starting at sector 2048
sfdisk "${SYNTHETIC_IMG}" <<EOF
label: dos
unit: sectors

${SYNTHETIC_IMG}1 : start=2048, size=204800, type=c
EOF

# Format partition 1 as FAT32 by writing a pre-formatted image at the correct offset
dd if=/dev/zero of="${TMPDIR}/boot.vfat" bs=512 count=204800 status=none
mkfs.vfat -n "SEEDSIGNDEV" "${TMPDIR}/boot.vfat" >/dev/null 2>&1
dd if="${TMPDIR}/boot.vfat" of="${SYNTHETIC_IMG}" bs=512 seek=2048 conv=notrunc status=none

# Verify partition layout
echo "Partition table:"
sfdisk --dump "${SYNTHETIC_IMG}" 2>/dev/null | grep -v "^$" || true
echo ""

# Verify the offset extraction works
PARTITION_OFFSET=$(python3 -c "import struct; print(struct.unpack('<I', open('${SYNTHETIC_IMG}','rb').read()[454:458])[0] * 512)")
echo "Extracted partition 1 offset: ${PARTITION_OFFSET} bytes (sector $((PARTITION_OFFSET / 512)))"

if [ "${PARTITION_OFFSET}" -ne 1048576 ]; then
  echo "FAIL: Expected offset 1048576, got ${PARTITION_OFFSET}" >&2
  exit 1
fi
echo ""

# --- Negative tests: verify known-bad syntaxes fail ---
echo "=== Negative tests (should FAIL) ==="

test_negative() {
  local label="$1"
  local img_arg="$2"
  
  if MTOOLS_SKIP_CHECK=1 mmd -i "${img_arg}" ::javacard-cap >/dev/null 2>&1; then
    echo "FAIL: ${label} — command succeeded but should have failed"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: ${label} — correctly rejected (as expected)"
    PASS=$((PASS + 1))
  fi
}

# Bare image (no partition specifier) -> sees MBR, not FAT
test_negative "bare image (no partition)" "${SYNTHETIC_IMG}"

# ::1 syntax (treated as drive letter C:, not partition)
test_negative "::1 suffix" "${SYNTHETIC_IMG}::1"

# :p1 syntax (not valid mtools command-line syntax)
test_negative ":p1 suffix" "${SYNTHETIC_IMG}:p1"

echo ""

# --- Positive tests: verify correct @@offset syntax works ---
echo "=== Positive tests (should SUCCEED) ==="

test_positive() {
  local label="$1"
  local img_arg="$2"
  
  # Clean up any previous test directory
  MTOOLS_SKIP_CHECK=1 mrd -i "${img_arg}" ::javacard-cap >/dev/null 2>&1 || true
  
  if MTOOLS_SKIP_CHECK=1 mmd -i "${img_arg}" ::javacard-cap >/dev/null 2>&1; then
    # Verify the directory was actually created
    if MTOOLS_SKIP_CHECK=1 mtoolstest -i "${img_arg}" ::javacard-cap >/dev/null 2>&1; then
      echo "PASS: ${label} — command succeeded and directory exists"
      PASS=$((PASS + 1))
    else
      echo "FAIL: ${label} — command succeeded but directory not found"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "FAIL: ${label} — command failed unexpectedly"
    FAIL=$((FAIL + 1))
  fi
}

# @@offset syntax (correct mtools partition specifier)
test_positive "@@offset syntax" "${SYNTHETIC_IMG}@@${PARTITION_OFFSET}"

echo ""

# --- Integration tests: extract and run actual commands from post-image scripts ---
echo "=== Integration tests (actual post-image scripts) ==="

POST_IMAGE_SCRIPTS=(
  "opt/pi0-smartcard-dev/board/post-image-seedsigner.sh"
  "opt/pi02w-smartcard-dev/board/post-image-seedsigner.sh"
  "opt/pi2-smartcard-dev/board/post-image-seedsigner.sh"
  "opt/pi4-smartcard-dev/board/post-image-seedsigner.sh"
  "opt/lafrite-smartcard-dev/board/post-image-seedsigner.sh"
)

for script_rel in "${POST_IMAGE_SCRIPTS[@]}"; do
  script_path="${REPO_ROOT}/${script_rel}"
  
  if [ ! -f "${script_path}" ]; then
    echo "FAIL: ${script_rel} — file not found"
    FAIL=$((FAIL + 1))
    continue
  fi
  
  board_name="$(echo "${script_rel}" | cut -d'/' -f2)"
  
  # Extract the mtools line (the mmd command) from the script
  mtools_line="$(grep -E '^\s*MTOOLS_SKIP_CHECK=1\s+mmd\s+-i' "${script_path}" || true)"
  
  if [ -z "${mtools_line}" ]; then
    echo "FAIL: ${board_name} — no mtools mmd command found"
    FAIL=$((FAIL + 1))
    continue
  fi
  
  # Check that the script computes PARTITION_OFFSET from MBR (dynamic offset)
  if ! grep -q 'PARTITION_OFFSET.*python3.*struct' "${script_path}"; then
    echo "WARN: ${board_name} — does not compute partition offset dynamically from MBR"
  fi
  
  # Extract the -i argument pattern from the mtools line
  img_arg="$(echo "${mtools_line}" | sed -n 's/.*-i\s*"\([^"]*\)".*/\1/p')"
  
  if [ -z "${img_arg}" ]; then
    echo "FAIL: ${board_name} — could not extract image argument from: ${mtools_line}"
    FAIL=$((FAIL + 1))
    continue
  fi
  
  # The script uses patterns like:
  #   ${BINARIES_DIR}/seedsigner_os.img@@${PARTITION_OFFSET}
  # We need to resolve both variables. Create a minimal test environment.
  
  # Clean up any previous javacard-cap directory
  MTOOLS_SKIP_CHECK=1 mrd -i "${SYNTHETIC_IMG}@@${PARTITION_OFFSET}" ::javacard-cap >/dev/null 2>&1 || true
  
  # Source just the relevant part: set BINARIES_DIR and compute PARTITION_OFFSET, then run the command
  (
    export BINARIES_DIR="${TMPDIR}"
    export MTOOLS_SKIP_CHECK=1
    
    # Extract and evaluate the PARTITION_OFFSET computation line from the script
    offset_line="$(grep 'PARTITION_OFFSET=' "${script_path}" || true)"
    if [ -n "${offset_line}" ]; then
      eval "${offset_line}"
    else
      # Fallback: use known offset
      PARTITION_OFFSET="${PARTITION_OFFSET}"
    fi
    
    # Extract the mmd command and evaluate it
    eval "${mtools_line}" 2>/dev/null
  )
  
  if MTOOLS_SKIP_CHECK=1 mtoolstest -i "${SYNTHETIC_IMG}@@${PARTITION_OFFSET}" ::javacard-cap >/dev/null 2>&1; then
    echo "PASS: ${board_name} — mtools command works correctly"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${board_name} — javacard-cap directory not created"
    echo "       Command: ${mtools_line}"
    FAIL=$((FAIL + 1))
  fi
done

echo ""

# --- Summary ---
TOTAL=$((PASS + FAIL))
echo "=== Results: ${PASS}/${TOTAL} passed, ${FAIL} failed ==="

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi

exit 0
