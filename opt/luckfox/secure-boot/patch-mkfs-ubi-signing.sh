#!/usr/bin/env bash
#
# patch-mkfs-ubi-signing.sh <LUCKFOX_PICO_DIR>
#
# Hook minisign into the SDK's mkfs_ubi.sh so the rootfs volume's logical
# UBIFS contents are signed at build time. Run AFTER the SDK is checked out
# and BEFORE `build.sh firmware` (the pctools step copies these scripts from
# sysdrv/tools/pc into sysdrv/out/pc, so they must be patched at the source —
# same constraint as patch-fs-determinism.sh).
#
# Why sign the logical image rather than the final .ubi file: UBI rewrites
# erase-counter headers and fastmap data after unclean power cuts, so raw mtd6
# bytes are not stable across boots. The logical volume contents ARE stable —
# that is exactly what mkfs.ubifs/mksquashfs produced, and it is what the
# kernel exposes at boot (/dev/ubi0_0 for dynamic UBIFS volumes,
# /dev/ubiblock0_0 for static squashfs-on-UBI) for the initramfs verifier to
# re-read and check.
#
# The hook sits after the COMMON ubinize line in mk_ubi_image_fake(), so it
# signs $temp_image whatever FS_TYPE is (squashfs on non-dev, ubifs on dev).
# Only the DEFAULT-geometry image (the one that becomes rootfs.img via the
# `ln -rfs` in mkfs_ubi.sh) is signed; the other two geometry variants are
# build-time artifacts only.
#
# The signing runs inside the fakeroot script mkfs_ubi.sh generates, right
# after the default-geometry mkfs.ubifs call, so it sees the exact bytes that
# get wrapped into UBI. It is gated on SEEDSIGNER_ROOTFS_SIGNING_KEY being set
# (exported by os-build.sh only when SEEDSIGNER_FIT_SIGNATURE=1), so unsigned
# builds are byte-identical to before this hook existed.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "usage: patch-mkfs-ubi-signing.sh <LUCKFOX_PICO_DIR>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBI_TOOL="$LUCKFOX_DIR/sysdrv/tools/pc/mtd-utils/mkfs_ubi.sh"
# Build-time signing runs on the build host (inside mkfs_ubi.sh's fakeroot
# script), so this is the x86-64 binary. The armv7 minisign-arm ships in the
# initramfs for boot-time verification instead.
MINISIGN_BIN="$SCRIPT_DIR/initramfs-binaries/minisign-host"

if [ ! -f "$UBI_TOOL" ]; then
    echo "patch-mkfs-ubi-signing: $UBI_TOOL not found" >&2
    exit 1
fi
if [ ! -x "$MINISIGN_BIN" ]; then
    echo "patch-mkfs-ubi-signing: vendored minisign-host missing at $MINISIGN_BIN (stale checkout?)" >&2
    exit 1
fi

MARKER="SEEDSIGNER-ROOTFS-SIGN-BEGIN"
if grep -q "$MARKER" "$UBI_TOOL"; then
    echo "  mkfs_ubi.sh: rootfs signing hook already present (idempotent re-run)"
    exit 0
fi

# The target is the echoed ubinize invocation — common to all three FS_TYPE
# cases in mk_ubi_image_fake(), where $temp_image already holds the logical
# image (.squashfs / .erofs / .ubifs) that is about to be packed into UBI. A
# changed/missing target must fail loudly, not silently no-op.
TARGET='echo "$MKUBINIZE_TOOL -o $output_image -m $ubifs_miniosize -p $UBI_BLOCK_SIZE -v $temp_ubinize_file" >> $UBI_IMAGE_FAKEROOT'
if ! grep -qF "$TARGET" "$UBI_TOOL"; then
    echo "patch-mkfs-ubi-signing: ubinize invocation line not found in $UBI_TOOL (SDK changed?)" >&2
    exit 1
fi

# Insert the hook after that line. The block is echoed into the fakeroot
# script like every other command there; it signs only for the default
# geometry (the one mkfs_ubi.sh symlinks to rootfs.img) and copies the
# signature next to the final image where os-build.sh picks it up.
python3 - "$UBI_TOOL" "$MINISIGN_BIN" <<'PYEOF'
import sys

path, minisign = sys.argv[1], sys.argv[2]
target = 'echo "$MKUBINIZE_TOOL -o $output_image -m $ubifs_miniosize -p $UBI_BLOCK_SIZE -v $temp_ubinize_file" >> $UBI_IMAGE_FAKEROOT'

# Three quoting rules, because of how mkfs_ubi.sh works:
#  * The geometry filter must run at GENERATION time — UBI_PAGE_SIZE /
#    UBI_BLOCK_SIZE are plain (unexported) shell variables that only exist in
#    this process; the fakeroot script runs as a child and cannot see them.
#  * $temp_image is ALSO generation-time-only, so it must be expanded NOW
#    (unescaped in the echo below), exactly like every other line of the
#    fakeroot script — escaped it would arrive empty at runtime.
#  * The signing key/passphrase are RUNTIME env vars (exported by os-build.sh,
#    inherited through fakeroot), so they stay escaped for the child; the -n
#    guard keeps unsigned builds from failing under `set -e`.
# NOTE: minisign's secret-key flag is lowercase -s (uppercase -S is the sign
# MODE and takes no argument — passing the key path there makes minisign fall
# back to ~/.minisign/minisign.key and fail).
hook_lines = [
    '\t\t\t# SEEDSIGNER-ROOTFS-SIGN-BEGIN (added by patch-mkfs-ubi-signing.sh)',
    '\t\t\tif [ $(( $DEFAULT_UBI_PAGE_SIZE )) -eq $(( $UBI_PAGE_SIZE )) ] && \\',
    '\t\t\t   [ $(( $DEFAULT_UBI_BLOCK_SIZE )) -eq $(( $UBI_BLOCK_SIZE )) ]; then',
    '\t\t\techo "if [ -n \\"\\$SEEDSIGNER_ROOTFS_SIGNING_KEY\\" ]; then" >> $UBI_IMAGE_FAKEROOT',
    '\t\t\techo "printf \'%s\\\\n\' \\"\\$SEEDSIGNER_ROOTFS_KEY_PASSPHRASE\\" | ' + minisign + ' -S -s \\"\\$SEEDSIGNER_ROOTFS_SIGNING_KEY\\" -t seedsigner-os-rootfs -m \\"$temp_image\\"" >> $UBI_IMAGE_FAKEROOT',
    '\t\t\techo "cp -f \\"${temp_image}.minisig\\" \\"$IMAGE_OUTPUT_DIR/rootfs.ubifs.minisig\\"" >> $UBI_IMAGE_FAKEROOT',
    # Record the signed image size: UBI autoresize pads the volume, so the
    # initramfs verifier must truncate its dd of the volume to exactly this
    # many bytes before checking. The final rootfs.img is UBI-wrapped and says
    # nothing about it — only here do we know the logical image's size.
    '\t\t\techo "wc -c < \"$temp_image\" > \"$IMAGE_OUTPUT_DIR/rootfs.ubifs.size\"" >> $UBI_IMAGE_FAKEROOT',
    '\t\t\techo fi >> $UBI_IMAGE_FAKEROOT',
    '\t\t\t# SEEDSIGNER-ROOTFS-SIGN-END',
    '\t\t\tfi',
]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
inserted = False
for line in lines:
    out.append(line)
    if not inserted and line.rstrip("\n").strip() == target:
        out.extend(h + "\n" for h in hook_lines)
        inserted = True

if not inserted:
    sys.exit("target line vanished during patching")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PYEOF

# Verify the hook landed and is syntactically valid shell.
grep -q "$MARKER" "$UBI_TOOL" || { echo "patch-mkfs-ubi-signing: marker missing after patch" >&2; exit 1; }
bash -n "$UBI_TOOL" || { echo "patch-mkfs-ubi-signing: patched mkfs_ubi.sh fails bash -n" >&2; exit 1; }
echo "  mkfs_ubi.sh: rootfs minisign hook installed (default geometry only)"
