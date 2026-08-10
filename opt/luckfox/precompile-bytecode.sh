#!/usr/bin/env bash
#
# precompile-bytecode.sh <ROOTFS_DIR> <LUCKFOX_PICO_DIR>
#
# Precompile the SeedSigner app (/opt/src) and the rootfs site-packages to
# .pyc at build time, so the device does not re-compile every module in memory
# on every boot. Shared by the GitHub Actions build and both local Docker
# builds (os-build.sh / build-local.sh) — change this script, never one caller.
# Run AFTER the app is staged and after optimize-nondev.sh (which prunes parts
# of the python tree), BEFORE the rootfs is packed.
#
# WHY: the non-dev rootfs is read-only squashfs (readonly-rootfs.sh), so /opt
# can never cache bytecode at runtime — without this, every import re-reads and
# re-compiles .py source off xz-compressed squashfs, on a single-core
# Cortex-A7, on EVERY boot. The Pi profiles have always precompiled at build
# time (opt/pi0/board/post-build.sh: "Add python byte code ... to increase boot
# and import module speed"); Luckfox got away without it only while its rootfs
# was writable UBIFS that cached __pycache__ on first boot.
#
# The .pyc magic must match the TARGET interpreter, so compilation uses the SDK
# buildroot's own host python3 together with the TARGET python's Lib/
# compileall.py — discovered, never hard-coded (the SDK's buildroot and python
# versions change between SDK revisions; see resolve-buildroot-dir.sh).
#
# Deterministic, same as the Pi post-build: SOURCE_DATE_EPOCH and PYTHONHASHSEED
# pinned, hash-based invalidation (checked-hash). .py sources stay in the image
# (checked-hash validation reads them, and they aid on-device debugging).

set -eu

ROOTFS="${1:-}"
LUCKFOX_DIR="${2:-}"

if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "precompile-bytecode: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "precompile-bytecode: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log() { echo "  [pyc] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILDROOT_DIR="$(bash "$SCRIPT_DIR/resolve-buildroot-dir.sh" "$LUCKFOX_DIR")"

# Host python from the buildroot host tree (host-python3 is always built: the
# target python3 package depends on it).
HOST_PY=""
for c in "$BUILDROOT_DIR/output/host/bin/python3" "$BUILDROOT_DIR/output/host/bin/"python3.[0-9]*; do
    if [ -x "$c" ] && "$c" -c 'import sys' 2>/dev/null; then
        HOST_PY="$c"
        break
    fi
done
if [ -z "$HOST_PY" ]; then
    echo "precompile-bytecode: no working host python3 under $BUILDROOT_DIR/output/host/bin" >&2
    exit 1
fi

# Target python build tree (same discovery convention as resolve-buildroot-dir).
PY_BUILD="$(find "$BUILDROOT_DIR/output/build" -maxdepth 1 -type d -name 'python3-3.*' 2>/dev/null | sort | tail -n 1)"
if [ -z "$PY_BUILD" ]; then
    echo "precompile-bytecode: no python3-3.* build dir under $BUILDROOT_DIR/output/build" >&2
    exit 1
fi
COMPILEALL="$PY_BUILD/Lib/compileall.py"
if [ ! -f "$COMPILEALL" ]; then
    echo "precompile-bytecode: $COMPILEALL not found" >&2
    exit 1
fi

# The .pyc magic must equal the target interpreter's: compare major.minor.
HOST_MM="$("$HOST_PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
TARGET_MM="$(basename "$PY_BUILD" | sed -E 's/^python3-(3\.[0-9]+).*/\1/')"
if [ "$HOST_MM" != "$TARGET_MM" ]; then
    echo "precompile-bytecode: host python $HOST_MM != target python $TARGET_MM — refusing to emit unusable bytecode" >&2
    exit 1
fi
log "host python $HOST_MM matches target ($PY_BUILD)"

# Compile targets: the app, plus every real site-packages directory (skip
# symlinked python3* parents — the target layout may symlink python3 ->
# python3.12, and compiling the same tree twice wastes minutes).
TARGETS=()
if [ -d "$ROOTFS/opt/src" ]; then
    TARGETS+=("$ROOTFS/opt/src")
fi
for sp in "$ROOTFS/usr/lib/"python3*/site-packages; do
    if [ -d "$sp" ] && [ ! -L "$(dirname "$sp")" ]; then
        TARGETS+=("$sp")
    fi
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "precompile-bytecode: no compile targets found under $ROOTFS" >&2
    exit 1
fi

JOBS="$(nproc 2>/dev/null || echo 1)"
log "compiling: ${TARGETS[*]} (-j $JOBS)"
# Per-file failures are tolerated: an uncompilable module fails identically at
# runtime with or without this step, so skipping it loses nothing. A wholesale
# failure is caught below (no .pyc produced under /opt/src at all).
rc=0
SOURCE_DATE_EPOCH=1 PYTHONHASHSEED=0 \
    "$HOST_PY" "$COMPILEALL" -f -q -j "$JOBS" --invalidation-mode=checked-hash "${TARGETS[@]}" || rc=$?
if [ "$rc" -ne 0 ]; then
    log "WARNING: compileall exited $rc — some files were skipped (they still run from source)"
fi

PYC_APP=0
if [ -d "$ROOTFS/opt/src" ]; then
    PYC_APP="$(find "$ROOTFS/opt/src" -type f -name '*.pyc' | wc -l)"
fi
if [ "$PYC_APP" -eq 0 ]; then
    echo "precompile-bytecode: no .pyc produced under $ROOTFS/opt/src — compilation failed wholesale" >&2
    exit 1
fi
PYC_TOTAL="$(find "${TARGETS[@]}" -type f -name '*.pyc' | wc -l)"
log "precompiled bytecode: $PYC_APP modules in the app, $PYC_TOTAL total"
