#!/usr/bin/env bash
#
# patch-linkmount-hardening.sh <LUCKFOX_PICO_SDK_DIR>
#
# Mount untrusted storage noexec,nosuid,nodev on Luckfox Pico images.
#
# /userdata is the only untrusted writable partition on the device (settings,
# optional boot log), and removable media (microSD/USB) arrives via mdev
# hotplug. The app runs as root, so a planted binary or setuid file on either
# is code execution; nothing legitimate execve's from them (the app reads
# settings as data). This closes the last net-new boot-chain hardening item:
# untrusted storage must never be executable. Caveats (documented in AGENTS.md):
# noexec blocks execve of a planted binary but not `sh /mnt/x.sh` — an
# interpreter reads the file as data — and none of it helps if the rootfs
# itself is compromised.
#
# HOW: the SDK does NOT mount these partitions from /etc/fstab (its fstab only
# carries /dev/root, proc, devpts, tmpfs, sysfs). It generates an init script
# (/etc/init.d/S20linkmount) whose template lives in project/build.sh
# (parse_partition_file() + __GET_TARGET_PARTITION_FS_TYPE()); every mount call
# is a bare `mount -t <fstype> <dev> <mntpt>` with no options. In our layout
# the only partition that actually mounts through it is /userdata — rootfs is
# @IGNORE@ (early return) and oem was removed by apply-partition-layout.sh — so
# hardening every mount line in the template is userdata-only in practice.
#
# WHY THE GENERATOR: patching the installed S20linkmount is futile. The script
# is regenerated on every SDK build command (__PREPARE_BOARD_CFG) and re-copied
# into the rootfs by __PACKAGE_ROOTFS() during `build.sh firmware` — which runs
# AFTER harden-nondev.sh, in the same stage that packs rootfs.img. Only a patch
# to project/build.sh survives (same class of fix as the sdkinfo Build Time pin:
# patch the generator, never the generated file).
#
# Applied unconditionally (all build variants): nothing in any variant needs
# exec/suid/dev nodes from /userdata or removable media, and the Pi/La Frite
# side of this hardening is necessarily all-variant too (shared overlay).
#
# Shared by the GitHub Actions build and both local Docker builds — change this
# script, never one caller. Idempotent; fails loudly if the SDK moved the
# template lines rather than silently no-op'ing.
#
# Usage:  patch-linkmount-hardening.sh <LUCKFOX_PICO_SDK_DIR>

set -eu

SDK_DIR="${1:-}"
if [ -z "$SDK_DIR" ] || [ ! -d "$SDK_DIR" ]; then
    echo "patch-linkmount-hardening: SDK dir '${SDK_DIR:-<empty>}' not found" >&2
    exit 1
fi

BUILD_SH="$SDK_DIR/project/build.sh"
if [ ! -f "$BUILD_SH" ]; then
    echo "patch-linkmount-hardening: $BUILD_SH not found" >&2
    exit 1
fi

log() { echo "  [linkmount] $*"; }

# Literal text in project/build.sh (the S20linkmount template is an unquoted
# heredoc, so the runtime variables are backslash-escaped there).
ANY_MOUNT='mount -t \$part_fstype'
PATCHED='mount -t \$part_fstype -o noexec,nosuid,nodev '

if grep -qF "$PATCHED" "$BUILD_SH"; then
    log "S20linkmount template already hardened (idempotent re-run)"
else
    sed -i 's/mount -t \\$part_fstype /mount -t \\$part_fstype -o noexec,nosuid,nodev /g' "$BUILD_SH"
    log "patched S20linkmount mount template in project/build.sh (noexec,nosuid,nodev)"
fi

# Verify against the file, not the sed: every mount line in the template must
# carry the options. A changed SDK that moved or reworded the lines would make
# the counts disagree — fail loudly instead of shipping an unhardened image.
# grep -cF counts LINES; a patched line contains both ANY_MOUNT and PATCHED, so
# all == patched (and > 0) means nothing was missed.
all=$(grep -cF "$ANY_MOUNT" "$BUILD_SH" || true)
patched=$(grep -cF "$PATCHED" "$BUILD_SH" || true)

if [ "${patched:-0}" -eq 0 ]; then
    echo "patch-linkmount-hardening: no hardened mount line found in $BUILD_SH — the patch did not take" >&2
    exit 1
fi
if [ "${all:-0}" -ne "${patched:-0}" ]; then
    echo "patch-linkmount-hardening: $all S20linkmount mount line(s) but only $patched hardened — unpatched lines remain:" >&2
    grep -nF "$ANY_MOUNT" "$BUILD_SH" | grep -vF "$PATCHED" | sed 's/^/        /' >&2 || true
    exit 1
fi

# Canary against SDK drift: the pinned SDK (SDK_COMMIT) has exactly this many
# mount lines in the S20linkmount template. If an SDK bump adds or rewords one,
# fail loudly and recount — a silently unhardened line is worse than a failed
# build (same discipline as patch-fs-determinism.sh's sed targets).
EXPECTED_MOUNT_LINES=9
if [ "${patched:-0}" -ne "$EXPECTED_MOUNT_LINES" ]; then
    echo "patch-linkmount-hardening: expected $EXPECTED_MOUNT_LINES S20linkmount mount lines in project/build.sh, found $patched — the SDK template changed." >&2
    echo "   Recount with: grep -cF 'mount -t \\\$part_fstype' <SDK>/project/build.sh" >&2
    echo "   and update EXPECTED_MOUNT_LINES if the new lines are all in the mount_part template." >&2
    exit 1
fi

log "verified: all S20linkmount template mounts carry noexec,nosuid,nodev ($patched line(s))"
echo "=== linkmount hardening complete ==="
