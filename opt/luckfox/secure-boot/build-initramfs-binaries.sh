#!/usr/bin/env bash
#
# build-initramfs-binaries.sh <SDK_TOOLCHAIN_DIR> <OUTPUT_DIR>
#
# Deterministically rebuild all four vendored secure-boot binaries from source
# and overwrite the copies in OUTPUT_DIR (secure-boot/initramfs-binaries/).
# Shared by os-build.sh and build-local.sh — change this script, never one caller.
#
# The rebuilt files are then checked against their committed SHA-256 pins by
# verify_initramfs_binaries() in the calling build script: a fresh build that
# does not reproduce the pinned bytes EXACTLY fails the build loudly. The pins
# are therefore a live determinism canary, not just an integrity check — do NOT
# auto-update them here. When source legitimately changes (e.g. ss-lcd.c), the
# rebuild will fail until the pins and committed binaries are updated together
# in one commit (see initramfs-binaries/README.md).
#
# Determinism inputs, all pinned:
#   * sources  — downloaded by URL below and verified against hardcoded SHA-256
#                (AGENTS.md: every external asset is checksum-pinned)
#   * toolchain— the SDK's own arm-rockchip830-linux-uclibcgnueabihf (GCC 8.3.0,
#                crosstool-NG), pinned by opt/luckfox/SDK_COMMIT; minisign-host
#                uses the host gcc of the Ubuntu 22.04 build environment
#   * date     — SOURCE_DATE_EPOCH (defaulted to 0 here, as in both build
#                scripts). busybox 1.36.1's kconfig honours it for the version
#                string ("BusyBox v1.36.1 (1970-01-01 00:00:00 UTC)"); minisign
#                and libsodium embed no date at all.
#   * locale/TZ— pinned below so tool output parsing cannot drift by host.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SDK_TOOLCHAIN_DIR="${1:-}"
OUTPUT_DIR="${2:-}"
if [ -z "$SDK_TOOLCHAIN_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "usage: $0 <SDK_TOOLCHAIN_DIR> <OUTPUT_DIR>" >&2
    exit 2
fi

TC_PREFIX="arm-rockchip830-linux-uclibcgnueabihf"
TC_GCC="$SDK_TOOLCHAIN_DIR/bin/$TC_PREFIX-gcc"
TC_STRIP="$SDK_TOOLCHAIN_DIR/bin/$TC_PREFIX-strip"
[ -x "$TC_GCC" ] || { echo "build-initramfs-binaries: cross gcc not found at $TC_GCC (SDK toolchain missing or not extracted yet)" >&2; exit 1; }
[ -x "$TC_STRIP" ] || { echo "build-initramfs-binaries: strip not found at $TC_STRIP" >&2; exit 1; }

# --- determinism environment -------------------------------------------------
export LC_ALL=C TZ=UTC
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step() { echo "build-initramfs-binaries: $*"; }
fail() { echo "build-initramfs-binaries: ERROR: $*" >&2; exit 1; }

# --- sources (URL + hardcoded SHA-256) ----------------------------------------
BUSYBOX_URL="https://busybox.net/downloads/busybox-1.36.1.tar.bz2"
BUSYBOX_SHA="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"
MINISIGN_URL="https://codeload.github.com/jedisct1/minisign/tar.gz/9b3a4f28fd58033a48d7b7284a1da30182d7d4b8"
MINISIGN_SHA="168b528a9d53e2e687b73bbd64b9d4603e6f626d66e039be07dc2701ab902130"
SODIUM_URL="https://github.com/jedisct1/libsodium/releases/download/1.0.22-RELEASE/libsodium-1.0.22.tar.gz"
SODIUM_SHA="adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349"

download_and_verify() { # $1=url $2=dest $3=sha256
    step "downloading $(basename "$2") ..."
    curl -fSL --retry 3 --connect-timeout 30 -o "$WORK/$2" "$1" \
        || fail "download failed: $1"
    local actual
    actual="$(sha256sum "$WORK/$2" | cut -d' ' -f1)"
    [ "$actual" = "$3" ] \
        || fail "SHA-256 mismatch for $(basename "$2"): got $actual, want $3 (upstream changed or network tampering — update the pin deliberately, never skip verification)"
}

download_and_verify "$BUSYBOX_URL"  busybox.tar.bz2   "$BUSYBOX_SHA"
download_and_verify "$MINISIGN_URL"  minisign.tar.gz   "$MINISIGN_SHA"
download_and_verify "$SODIUM_URL"    libsodium.tar.gz  "$SODIUM_SHA"

tar xjf "$WORK/busybox.tar.bz2"   -C "$WORK"
tar xzf "$WORK/minisign.tar.gz"   -C "$WORK"
tar xzf "$WORK/libsodium.tar.gz"  -C "$WORK"
BB="$WORK/busybox-1.36.1"
MS="$WORK/minisign-9b3a4f28fd58033a48d7b7284a1da30182d7d4b8"
SD="$WORK/libsodium-1.0.22"

# --- ss-lcd (source in this repo) ---------------------------------------------
step "building ss-lcd ..."
[ -f "$SCRIPT_DIR/initramfs/ss-lcd.c" ] || fail "ss-lcd source missing: $SCRIPT_DIR/initramfs/ss-lcd.c"
"$TC_GCC" -O2 -static \
    -I"$SCRIPT_DIR/initramfs" \
    "$SCRIPT_DIR/initramfs/ss-lcd.c" -o "$WORK/ss-lcd" || fail "ss-lcd compile failed"
"$TC_STRIP" "$WORK/ss-lcd"

# --- busybox-arm ----------------------------------------------------------------
# Config recipe (see initramfs-binaries/README.md): allnoconfig, then flip ONLY
# the options /init needs. Starting from a minimal .config and letting oldconfig
# fill defaults balloons the binary ~1.2 MB (overflows the 4 MiB boot partition);
# appending =y lines fails kconfig's reassignment check — so sed-replace the
# "# CONFIG_X is not set" lines in place. Applet options are INSERT-generated at
# make time, so they only exist AFTER allnoconfig has run.
# Note: no CONFIG_SH — the "sh" alias of ash is CONFIG_SH_IS_ASH, which is the
# default choice in allnoconfig (include/applets.h: IF_SH_IS_ASH).
step "building busybox-arm ..."
(
    cd "$BB"
    make allnoconfig >/dev/null
    for s in ASH TEST ASH_TEST MOUNT UMOUNT PIVOT_ROOT DD TRUNCATE SHA256SUM \
             LS CAT ECHO SLEEP TRUE FALSE REBOOT HALT POWEROFF MKNOD GREP HEAD \
             TAIL DMESG RM MKDIR LN CP MV STATIC ASH_INTERNAL_GLOB \
             FEATURE_FANCY_HEAD FEATURE_SH_MATH SWITCH_ROOT; do
        sed -i "s|^# CONFIG_${s} is not set$|CONFIG_${s}=y|" .config
    done
    yes '' | make oldconfig >/dev/null
    make -j"$(nproc)" CROSS_COMPILE="$SDK_TOOLCHAIN_DIR/bin/$TC_PREFIX-" \
        || exit 1
) || fail "busybox build failed"
[ -f "$BB/busybox" ] || fail "busybox binary not produced"

# Canary: every applet /init invokes must be compiled in. Applet names live in
# the binary's applet table; strings -n 2 catches the 2-3 char ones (sh, dd...).
missing=""
for a in sh mount umount switch_root dd truncate sha256sum ls cat echo sleep \
         true false reboot halt poweroff mknod grep head tail dmesg rm mkdir ln cp mv; do
    strings -n 2 "$BB/busybox" | grep -qx "$a" || missing="$missing $a"
done
[ -z "$missing" ] || fail "busybox is missing applets /init needs:$missing (config recipe drifted?)"

# --- libsodium + minisign, arm and host -----------------------------------------
build_minisign_pair() { # $1=tag $2=gcc $3=strip $4=sodium-dir $5=extra-configure...
    local tag="$1" gcc="$2" strip="$3" sodium_dir="$4"; shift 4
    step "building libsodium-$tag (static) ..."
    (
        cd "$sodium_dir"
        ./configure --enable-static --disable-shared "$@" >/dev/null \
            || exit 1
        make -j"$(nproc)" >/dev/null || exit 1
    ) || fail "libsodium-$tag build failed"
    # libtool keeps the real archive next to the sources (src/libsodium/.libs/);
    # a top-level lib/ only appears after `make install`, which we do not run.
    # Public headers live in src/libsodium/include/ (configure generates the
    # version-specific ones there).
    local sodium_libdir="$sodium_dir/src/libsodium/.libs"
    local sodium_includedir="$sodium_dir/src/libsodium/include"
    [ -f "$sodium_libdir/libsodium.a" ] || fail "libsodium-$tag: src/libsodium/.libs/libsodium.a not produced"

    step "building minisign-$tag ..."
    (
        cd "$MS"
        "$gcc" -O2 -static -D_GNU_SOURCE \
            src/base64.c src/get_line.c src/helpers.c src/minisign.c \
            -I"$sodium_includedir" -L"$sodium_libdir" -lsodium \
            -o "minisign-$tag" || exit 1
    ) || fail "minisign-$tag build failed"
    "$strip" "$MS/minisign-$tag"
}

# ARM: cross-configure libsodium for the uClibc target (README recipe).
build_minisign_pair arm "$TC_GCC" "$TC_STRIP" "$SD" \
    --host="$TC_PREFIX" CC="$TC_GCC"

# Host: plain gcc of the Ubuntu 22.04 build environment (Docker image or CI
# host). configure is per-directory, so the host pair gets its own source copy
# to keep the two builds independent.
mkdir -p "$WORK/sodium-host"
tar xzf "$WORK/libsodium.tar.gz" -C "$WORK/sodium-host" --strip-components=1
build_minisign_pair host gcc /usr/bin/strip "$WORK/sodium-host"

# --- install ---------------------------------------------------------------------
step "installing rebuilt binaries into $OUTPUT_DIR ..."
[ -d "$OUTPUT_DIR" ] || fail "output dir missing: $OUTPUT_DIR"
cp -f "$BB/busybox"            "$OUTPUT_DIR/busybox-arm"
cp -f "$MS/minisign-arm"       "$OUTPUT_DIR/minisign-arm"
cp -f "$WORK/ss-lcd"           "$OUTPUT_DIR/ss-lcd"
cp -f "$MS/minisign-host"      "$OUTPUT_DIR/minisign-host"
chmod 755 "$OUTPUT_DIR/busybox-arm" "$OUTPUT_DIR/minisign-arm" \
          "$OUTPUT_DIR/ss-lcd" "$OUTPUT_DIR/minisign-host"

step "rebuilt binaries:"
( cd "$OUTPUT_DIR" && sha256sum busybox-arm minisign-arm ss-lcd minisign-host )
