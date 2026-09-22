#!/bin/bash
# Remove entries whose names contain whitespace from a rootfs tree before it is
# packed into an ext4 partition image.
#
# mkfs-ext4-deterministic.sh cannot represent such names: it feeds debugfs a
# line-oriented command file, and a path containing whitespace would break that
# format — so it treats them as FATAL (its "unsupported filename" check).
# Upstream packages occasionally ship test fixtures with spaces in their names
# (setuptools vendors jaraco.text's `Lorem ipsum.txt`); on the device they are
# dead weight — sample text for unit tests, never read at runtime.
#
# Deletion rather than renaming: nothing on the device references these names,
# and a rename would only move the problem into any code that did. A directory
# with whitespace in its name is removed whole: every path beneath it contains
# the offending component, so none of it could be packed as-is anyway. Every
# removal is logged so CI can audit exactly what left the image.
set -euo pipefail

rootfs_dir="${1:?usage: strip-whitespace-filenames.sh <rootfs-dir>}"
[ -d "$rootfs_dir" ] || { echo "strip-whitespace-filenames: not a directory: $rootfs_dir" >&2; exit 1; }

# Collect before deleting so the walk never mutates the tree it is reading.
# -mindepth 1: the root itself (a fixed container path) is out of scope.
entries=()
while IFS= read -r -d '' p; do entries+=("$p"); done \
    < <(find "$rootfs_dir" -mindepth 1 -name '*[[:space:]]*' -print0 | LC_ALL=C sort -z)

if [ "${#entries[@]}" -eq 0 ]; then
    echo "strip-whitespace-filenames: nothing to remove in $(basename "$rootfs_dir")"
    exit 0
fi

for p in "${entries[@]}"; do
    rm -rf -- "$p"
    echo "strip-whitespace-filenames: removed whitespace-named entry: ${p#"$rootfs_dir"/}"
done
echo "strip-whitespace-filenames: removed ${#entries[@]} entr(ies) from $(basename "$rootfs_dir")"
