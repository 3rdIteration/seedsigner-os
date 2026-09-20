#!/usr/bin/env bash
#
# deterministic-sign.sh <IMAGE_DIR> <KEY_PEM> <PUBKEY_PEM>
#
# Re-sign the four boot-chain images (idblock.img, download.bin, uboot.img,
# boot.img) with our own tools so their RSA-PSS signatures are byte-
# reproducible: salt derived from the digest, FIT timestamp zeroed. Shared by
# the GitHub Actions build and both local Docker builds — change this script,
# never one caller. Must run AFTER every content mutation of the four images
# (embed_rootfs_verifier, sign_boot_image) and BEFORE normalise_boot_images, so
# update.img's repack embeds OUR signatures rather than the vendor's.
#
# WHY THIS EXISTS
#
# The SDK signs these images with its own tooling during the build:
#   * uboot.img / boot.img - U-Boot 2017.09 mkimage (fit-core.sh, fit.sh). Its
#     backported FIT signing writes a wall-clock `timestamp` property into the
#     signature node (time(NULL); it does NOT honour SOURCE_DATE_EPOCH) and
#     draws its PSS salt at random. Two builds of the same commit therefore
#     differ in exactly those bytes - verified against shipped CI images, whose
#     timestamps were 1789823100 / 1789826498 (the build window), not 0. It
#     also leaves UNINITIALISED HEAP BYTES in the FDT alignment padding: when
#     libfdt grows the structure block to append the signature node it copies
#     into a fresh malloc(), so the pad after whatever property triggered the
#     grow is random (observed: 3 bytes after `hashed-nodes` in uboot.img).
#     fitsign.zero_fdt_padding clears all of it - FDT pads are undefined and no
#     parser reads them, and hashed-node pads are already zero at creation.
#   * idblock.img / download.bin - rk_sign_tool, a PREBUILT binary we cannot
#     patch; its salt behaviour is whatever the blob does.
#
# KNOWN EXCEPTION (vendor-encrypted, not fixable here): download.bin's tail
# (the 196 KiB after the two hashed components) is an AES-ECB-encrypted vendor
# "flashhead" loader - 220 repeated 16-byte ciphertext blocks give it away.
# sign_tool signs its internal head with a random salt on every build, and the
# resulting 256 bytes of CIPHERTEXT (tail+0x600..0x700) therefore differ per
# build; we cannot re-sign inside it without the vendor's AES key. It does not
# affect the SD card image (download.bin is a USB-flash package, never written
# to the card - see sd_update.txt), only download.bin/update.img in the bundle.
#
# Neither can be made deterministic without patching vendor C source in the
# pinned SDK (fragile across SDK bumps) or replacing an unpatchable binary. So
# instead we let the SDK sign (it creates the signature-node structure and
# embeds the pubkey), then OVERWRITE every signature with our own tools:
#   * rkloader.py  - loader tier; rehashes components + refreshes the LDR
#                    trailer internally, signs with a digest-derived salt.
#   * fitsign.py   - FIT tier; same deterministic salt at mkimage's max length,
#                    and zeroes the wall-clock timestamp (outside the signed
#                    region, so nothing on-device changes).
# The signatures verify identically on hardware: PSS verification recovers the
# salt from the block, and the SPL/U-Boot checkers never read the timestamp.
#
# Gated by the caller on SEEDSIGNER_FIT_SIGNATURE=1; unsigned builds never run
# this and stay byte-for-byte unchanged.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $(basename "$0") <IMAGE_DIR> <KEY_PEM> <PUBKEY_PEM>" >&2
    exit 1
fi

IMAGE_DIR="$1"
KEY_PEM="$2"
PUBKEY_PEM="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURE_BOOT="$SCRIPT_DIR/secure-boot"

for f in "$KEY_PEM" "$PUBKEY_PEM"; do
    [ -f "$f" ] || { echo "deterministic-sign: key file missing: $f" >&2; exit 1; }
done
[ -x "$SECURE_BOOT/rkloader.py" ] || [ -f "$SECURE_BOOT/rkloader.py" ] \
    || { echo "deterministic-sign: secure-boot tools missing at $SECURE_BOOT (stale Docker image?)" >&2; exit 1; }

# Every one of the four must exist and be re-signed. Silently skipping a
# missing file would ship that tier with the vendor's non-reproducible
# signature, which defeats the point - so absence is a hard failure.
for img in idblock.img download.bin uboot.img boot.img; do
    [ -f "$IMAGE_DIR/$img" ] \
        || { echo "deterministic-sign: $IMAGE_DIR/$img missing (run 'build.sh firmware' first)" >&2; exit 1; }
done

sign_and_verify() {
    local tool="$1" img="$2"
    python3 "$SECURE_BOOT/$tool" sign "$IMAGE_DIR/$img" --key "$KEY_PEM" \
        || { echo "deterministic-sign: $tool sign failed for $img" >&2; exit 1; }
    python3 "$SECURE_BOOT/$tool" verify "$IMAGE_DIR/$img" --pubkey "$PUBKEY_PEM" \
        || { echo "deterministic-sign: $img does NOT verify after signing - aborting" >&2; exit 1; }
}

echo "deterministic-sign: re-signing the boot chain with digest-derived salts (timestamp zeroed)"
sign_and_verify rkloader.py idblock.img
sign_and_verify rkloader.py download.bin
sign_and_verify fitsign.py uboot.img
sign_and_verify fitsign.py boot.img
echo "deterministic-sign: all four images signed and verified"
