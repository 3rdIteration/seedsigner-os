#!/usr/bin/env bash
#
# patch-oem-pre-hook.sh <BOARD_CONFIG_PATH> <PRUNE_SCRIPT_ABS_PATH>
#
# Install SeedSigner calls into the Luckfox SDK's pre-build-OEM hook, so the
# iqfiles prune and the rootfs-fold prep both run in the one window where the
# staged oem tree exists and is still editable. Shared by the GitHub Actions
# build and both local Docker builds — change this script, never one caller. Run
# BEFORE `build.sh firmware`.
#
# Since 2026-09-23 the oem partition is removed: apply-partition-layout.sh sets
# RK_BUILD_APP_TO_OEM_PARTITION=n, so build_firmware() copies the tree this hook
# edits into <rootfs>/oem and packs it into the signed squashfs. The hook is
# therefore the last chance to fix content that assumed a writable /oem (see
# prepare-oem-for-rootfs.sh, run right after the prune below).
#
# HOW THE SDK HOOK WORKS (build.sh __RUN_PRE_BUILD_OEM_SCRIPT):
#     tmp_path=$(dirname $(realpath $BOARD_CONFIG))
#     [ -f "$tmp_path/$RK_PRE_BUILD_OEM_SCRIPT" ] && bash -x "$tmp_path/$RK_PRE_BUILD_OEM_SCRIPT"
# i.e. the script name comes from RK_PRE_BUILD_OEM_SCRIPT in the board config
# and is resolved relative to the board config's own directory. It is called
# from build_firmware() after __PACKAGE_OEM (which populates
# $RK_PROJECT_PACKAGE_OEM_DIR) and before the tree is used: with our
# RK_BUILD_APP_TO_OEM_PARTITION=n that is the fold into <rootfs>/oem followed by
# the squashfs pack; on a stock board it would be build_mkimg creating oem.img.
#
# Every Luckfox board config we build already sets
# RK_PRE_BUILD_OEM_SCRIPT=luckfox-buildroot-oem-pre.sh (the vendor script that
# prunes unused libs from the oem tree), so we APPEND to it rather than
# replacing it — replacing would silently drop the vendor's prunes. If a board
# config has no hook configured, one is created and wired up.
#
# Idempotent: the appended block is marked and only added once.

set -eu

BOARD_CONFIG="${1:-}"
PRUNE_SCRIPT="${2:-}"
MARKER="# >>> SeedSigner oem rootfs prep (added by patch-oem-pre-hook.sh) >>>"

if [ -z "$BOARD_CONFIG" ] || [ ! -f "$BOARD_CONFIG" ]; then
    echo "patch-oem-pre-hook: board config '${BOARD_CONFIG:-<empty>}' not found" >&2
    exit 1
fi
if [ -z "$PRUNE_SCRIPT" ] || [ ! -f "$PRUNE_SCRIPT" ]; then
    echo "patch-oem-pre-hook: prune script '${PRUNE_SCRIPT:-<empty>}' not found" >&2
    exit 1
fi

# Resolve to absolute: the hook executes with an unpredictable cwd, deep inside
# the SDK build, so a relative path would not resolve.
PRUNE_SCRIPT="$(cd "$(dirname "$PRUNE_SCRIPT")" && pwd)/$(basename "$PRUNE_SCRIPT")"
BOARD_CONFIG="$(cd "$(dirname "$BOARD_CONFIG")" && pwd)/$(basename "$BOARD_CONFIG")"
HOOK_DIR="$(dirname "$BOARD_CONFIG")"
# The shared scripts live next to the prune script; prepare-oem-for-rootfs.sh is
# resolved from there so the caller does not have to pass a second path.
SHARED_DIR="$(dirname "$PRUNE_SCRIPT")"

HOOK_NAME="$(sed -n 's/^export RK_PRE_BUILD_OEM_SCRIPT=["'"'"']\{0,1\}\([^"'"'"' ]*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$BOARD_CONFIG" | tail -n1)"

if [ -z "$HOOK_NAME" ]; then
    # No hook configured for this board: create one and point the board config at it.
    HOOK_NAME="seedsigner-oem-pre.sh"
    printf '\n# SeedSigner: run the oem prune/rootfs prep before the tree is packed\nexport RK_PRE_BUILD_OEM_SCRIPT=%s\n' "$HOOK_NAME" >> "$BOARD_CONFIG"
    printf '#!/bin/bash\n# Created by patch-oem-pre-hook.sh (no vendor hook was configured for this board).\n' > "$HOOK_DIR/$HOOK_NAME"
    chmod +x "$HOOK_DIR/$HOOK_NAME"
    echo "🔧 no RK_PRE_BUILD_OEM_SCRIPT was set — created $HOOK_NAME and wired it into $(basename "$BOARD_CONFIG")"
fi

HOOK="$HOOK_DIR/$HOOK_NAME"
if [ ! -f "$HOOK" ]; then
    echo "patch-oem-pre-hook: hook script referenced by the board config is missing: $HOOK" >&2
    exit 1
fi

if grep -qF "$MARKER" "$HOOK"; then
    echo "ℹ️  oem pre-build hook already patched ($HOOK_NAME)"
    exit 0
fi

# The SDK runs the hook with `bash -x` and does not check its exit status, but
# guard anyway: a missing prune/prep script must not be able to break the build.
# IQFILES_KEEP is passed through to the prune if the caller exported it.
cat >> "$HOOK" <<EOF

$MARKER
# Prune camera ISP tuning files from the staged oem tree. This runs after
# __PACKAGE_OEM and before build_firmware() folds the tree into <rootfs>/oem and
# packs the squashfs — the only point where the oem tree exists and is editable
# (see prune-oem-iqfiles.sh).
if [ -f "$PRUNE_SCRIPT" ]; then
    bash "$PRUNE_SCRIPT" "\${RK_PROJECT_PACKAGE_OEM_DIR:-}"
else
    echo "  [iqprune] (skip) prune script not found: $PRUNE_SCRIPT"
fi
# Fix up the pruned oem tree for a read-only /oem inside the signed rootfs (the
# SDK folds it in right after this hook — see prepare-oem-for-rootfs.sh).
if [ -f "$SHARED_DIR/prepare-oem-for-rootfs.sh" ]; then
    bash "$SHARED_DIR/prepare-oem-for-rootfs.sh" "\${RK_PROJECT_PACKAGE_OEM_DIR:-}"
else
    echo "  [oemroot] (skip) prepare script not found: $SHARED_DIR/prepare-oem-for-rootfs.sh"
fi
# <<< SeedSigner oem rootfs prep <<<
EOF

echo "🔧 Patched $HOOK_NAME to prune the SeedSigner oem iqfiles and prep /oem for the signed rootfs"
