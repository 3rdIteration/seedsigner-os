#!/usr/bin/env bash
#
# patch-oem-pre-hook.sh <BOARD_CONFIG_PATH> <PRUNE_SCRIPT_ABS_PATH>
#
# Install a SeedSigner call into the Luckfox SDK's pre-build-OEM hook, so the
# iqfiles prune runs in the one window where the staged oem tree exists and is
# still editable. Shared by the GitHub Actions build and both local Docker
# builds — change this script, never one caller. Run BEFORE `build.sh firmware`.
#
# HOW THE SDK HOOK WORKS (build.sh __RUN_PRE_BUILD_OEM_SCRIPT):
#     tmp_path=$(dirname $(realpath $BOARD_CONFIG))
#     [ -f "$tmp_path/$RK_PRE_BUILD_OEM_SCRIPT" ] && bash -x "$tmp_path/$RK_PRE_BUILD_OEM_SCRIPT"
# i.e. the script name comes from RK_PRE_BUILD_OEM_SCRIPT in the board config
# and is resolved relative to the board config's own directory. It is called
# from build_firmware() after __PACKAGE_OEM (which populates
# $RK_PROJECT_PACKAGE_OEM_DIR) and before build_mkimg builds oem.img.
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
MARKER="# >>> SeedSigner oem prune (added by patch-oem-pre-hook.sh) >>>"

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

HOOK_NAME="$(sed -n 's/^export RK_PRE_BUILD_OEM_SCRIPT=["'"'"']\{0,1\}\([^"'"'"' ]*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$BOARD_CONFIG" | tail -n1)"

if [ -z "$HOOK_NAME" ]; then
    # No hook configured for this board: create one and point the board config at it.
    HOOK_NAME="seedsigner-oem-pre.sh"
    printf '\n# SeedSigner: run the oem prune before oem.img is built\nexport RK_PRE_BUILD_OEM_SCRIPT=%s\n' "$HOOK_NAME" >> "$BOARD_CONFIG"
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
# guard anyway: a missing prune script must not be able to break the build over
# a size optimization. IQFILES_KEEP is passed through if the caller exported it.
cat >> "$HOOK" <<EOF

$MARKER
# Prune camera ISP tuning files from the staged oem tree. This runs after
# __PACKAGE_OEM and before build_mkimg creates oem.img — the only point where
# the oem tree exists and is still editable (see prune-oem-iqfiles.sh).
if [ -f "$PRUNE_SCRIPT" ]; then
    bash "$PRUNE_SCRIPT" "\${RK_PROJECT_PACKAGE_OEM_DIR:-}"
else
    echo "  [iqprune] (skip) prune script not found: $PRUNE_SCRIPT"
fi
# <<< SeedSigner oem prune <<<
EOF

echo "🔧 Patched $HOOK_NAME to run the SeedSigner oem iqfiles prune before oem.img"
