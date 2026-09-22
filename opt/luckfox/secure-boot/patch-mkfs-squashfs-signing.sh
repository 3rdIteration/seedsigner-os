#!/usr/bin/env bash
#
# patch-mkfs-squashfs-signing.sh <LUCKFOX_PICO_DIR>
#
# Hook minisign into the SDK's mkfs_squashfs.sh so a raw-partition squashfs
# rootfs (MicroSD / eMMC — no UBI involved) is signed at build time. Sibling of
# patch-mkfs-ubi-signing.sh, which covers the NAND path where the same mksquashfs
# output gets wrapped in a UBI volume by mkfs_ubi.sh's OWN embedded call (that
# script never goes through mkfs_squashfs.sh). Run AFTER the SDK is checked out
# and BEFORE `build.sh firmware` — the pctools step copies sysdrv/tools/pc into
# sysdrv/out/pc and it is the copies that get used (same constraint as both
# sibling patches).
#
# Why sign $dst here rather than the final partition bytes: on SD/eMMC the SDK
# writes this exact file verbatim to offset 0 of the rootfs partition
# (build_mkimg: dst=$RK_PROJECT_OUTPUT_IMAGE/rootfs.img, fs_type=squashfs), so
# the signed prefix IS what the kernel sees. The partition is larger than the
# image (6G on Mini); the tail is untrusted padding the verifier never reads —
# it streams exactly ${dst}.size bytes, recorded here next to the signature.
#
# The hook is APPENDED at the end of mkfs_squashfs.sh on purpose: it must run
# after every step that rewrites bytes of $dst (patch-fs-determinism's
# superblock mkfs_time pin writes offset 8 AFTER mksquashfs returns), and an
# EOF append keeps that ordering no matter what other patches touch the file.
# It is gated on SEEDSIGNER_ROOTFS_SIGNING_KEY being set (exported by os-build.sh
# only when SEEDSIGNER_FIT_SIGNATURE=1), so unsigned builds are byte-identical
# to before this hook existed.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "usage: patch-mkfs-squashfs-signing.sh <LUCKFOX_PICO_DIR>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUASH_TOOL="$LUCKFOX_DIR/sysdrv/tools/pc/mksquashfs/mkfs_squashfs.sh"
# Build-time signing runs on the build host, so this is the x86-64 binary. The
# armv7 minisign-arm ships in the initramfs for boot-time verification instead.
MINISIGN_BIN="$SCRIPT_DIR/initramfs-binaries/minisign-host"

if [ ! -f "$SQUASH_TOOL" ]; then
    echo "patch-mkfs-squashfs-signing: $SQUASH_TOOL not found" >&2
    exit 1
fi
if [ ! -x "$MINISIGN_BIN" ]; then
    echo "patch-mkfs-squashfs-signing: vendored minisign-host missing at $MINISIGN_BIN (stale checkout?)" >&2
    exit 1
fi

MARKER="SEEDSIGNER-SQUASHFS-SIGN-BEGIN"
if grep -q "$MARKER" "$SQUASH_TOOL"; then
    # A hook from an older revision of this script is unusable: it must sign in
    # pre-hashed mode (-H) and record the size file, or the boot-time verifier
    # cannot use it. Fail loudly instead of keeping it — a clean SDK checkout
    # removes the hook.
    if grep -A12 "$MARKER" "$SQUASH_TOOL" | grep -q -- '-H -m' \
        && grep -A12 "$MARKER" "$SQUASH_TOOL" | grep -q '\${dst}.size'; then
        echo "  mkfs_squashfs.sh: rootfs signing hook already present (idempotent re-run)"
        exit 0
    fi
    echo "patch-mkfs-squashfs-signing: stale rootfs signing hook in $SQUASH_TOOL; clean the SDK tree and retry" >&2
    exit 1
fi

# Sanity-anchor on something that must exist in any revision of this script, so
# a renamed/rewritten tool fails loudly instead of getting a hook appended to
# the wrong file. The mksquashfs invocation is the contract: $dst is its output.
grep -q 'MKSQUASHFS_TOOL' "$SQUASH_TOOL" || {
    echo "patch-mkfs-squashfs-signing: MKSQUASHFS_TOOL not found in $SQUASH_TOOL (SDK changed?)" >&2
    exit 1
}

cat >> "$SQUASH_TOOL" <<EOF

# $MARKER (added by patch-mkfs-squashfs-signing.sh)
# Sign the finished squashfs image for boot-time verification: minisign
# pre-hashed mode (-H, BLAKE2b-512 streamed in 64 KiB chunks — recorded inside
# the .minisig as sig_alg "ED", so the initramfs verifier streams too and peak
# RAM stays ~128 KiB for a multi-GB partition). Same key and trusted comment as
# the UBI hook, so one public key covers every medium. Runs LAST: after any
# post-processing that rewrites bytes of \$dst (the superblock mkfs_time pin).
if [ -n "\$SEEDSIGNER_ROOTFS_SIGNING_KEY" ]; then
    printf '%s\\n' "\$SEEDSIGNER_ROOTFS_KEY_PASSPHRASE" | $MINISIGN_BIN -S -s "\$SEEDSIGNER_ROOTFS_SIGNING_KEY" -t seedsigner-os-rootfs -H -m \$dst \\
        || { echo "rootfs signing failed for \$dst" >&2; exit 1; }
    wc -c < "\$dst" > "\${dst}.size"
fi
# SEEDSIGNER-SQUASHFS-SIGN-END
EOF

# Verify the hook landed and is syntactically valid shell.
grep -q "$MARKER" "$SQUASH_TOOL" || { echo "patch-mkfs-squashfs-signing: marker missing after patch" >&2; exit 1; }
bash -n "$SQUASH_TOOL" || { echo "patch-mkfs-squashfs-signing: patched mkfs_squashfs.sh fails bash -n" >&2; exit 1; }
echo "  mkfs_squashfs.sh: rootfs minisign hook installed (appended, default geometry n/a)"
