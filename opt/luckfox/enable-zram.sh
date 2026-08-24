#!/usr/bin/env bash
#
# enable-zram.sh <KERNEL_DEFCONFIG> [ENABLE]
#
# Build a kernel that can do compressed swap in RAM (zram). Shared by the GitHub
# Actions build and both local Docker builds (os-build.sh / build-local.sh) —
# change this script, never one caller. Must run BEFORE `./build.sh kernel`.
#
#   ENABLE  1|0 (default 1) — 0 makes this a logged no-op
#
# The runtime half is files/S03zram, which sizes the device and swaps it on.
# Neither half is any use without the other.
#
# WHY: the Mini has 64 MB of RAM and no swap of any kind today, so the only
# response to memory pressure is reclaim of page cache and then the OOM killer.
# The symptoms already worked around elsewhere in this tree are all the same
# shortage seen from different angles — pin-spidev-bufsiz.sh exists because
# spidev_open()'s order-6 allocation fails once memory is fragmented, the Mini
# runs a 1 MB CMA, and start-seedsigner.sh staggers camera startup because the
# display otherwise loses the race for memory. zram does not replace any of
# those; it widens the margin they all operate in.
#
# It is a good fit for this workload specifically: the app is CPython, whose
# heap is pointer- and zero-dense and typically compresses around 3:1, so the
# pages that get swapped are exactly the ones that compress well. A compressed
# page still lives in RAM, so a "swap in" is a decompression, not a flash read —
# there is no storage to be slow, and no wear.
#
# WHY NOT A SWAP FILE OR PARTITION: two independent reasons, either sufficient.
# Seed material is in the app's address space, and anything paged out to flash
# is seed material at rest on a device whose whole premise is that it keeps
# nothing. And the rootfs is read-only squashfs (readonly-rootfs.sh), so there
# is nowhere on / to put a swap file in the first place.
#
# CONFIG_ZRAM_WRITEBACK IS DELIBERATELY LEFT OFF, and asserted off in
# assert-zram.sh. It teaches zram to push incompressible or idle pages out to a
# backing block device — i.e. it re-creates exactly the flash-backed swap the
# previous paragraph rules out, from inside the feature we are enabling. It
# needs /sys/block/zram0/backing_dev to be set to do anything, which nothing
# here does, but "off by default and nothing sets it" is not a control worth
# relying on when the failure is seed material on flash. Off at the kernel level
# is.
#
# NOTE: Kconfig SILENTLY DROPS defconfig lines for symbols that don't exist or
# whose dependencies are unmet, so setting CONFIG_ZRAM=y here does NOT prove the
# built kernel has zram. CONFIG_ZSMALLOC is the specific trap: ZRAM `depends on`
# it (drivers/block/zram/Kconfig) and a `depends on` is never auto-enabled the
# way a `select` is, so CONFIG_ZRAM=y on its own is silently discarded and the
# build stays green. That is why it is set explicitly below and why every symbol
# is re-checked against the GENERATED .config afterwards. See assert-zram.sh.
#
# Failing to enable zram is NOT fatal to a boot — S03zram is written to skip
# cleanly when the kernel has no zram device — so this is not in the same class
# as the overlayfs check, where a silent miss bricks the display. The assertion
# still fails the build: an image that quietly lost the memory headroom it was
# built for is not an image anyone should have to diagnose from the outside.

set -eu

DEFCONFIG="${1:-}"
ENABLE="${2:-1}"

if [ -z "$DEFCONFIG" ] || [ ! -f "$DEFCONFIG" ]; then
    echo "enable-zram: kernel defconfig '${DEFCONFIG:-<empty>}' not found" >&2
    exit 1
fi

log() { echo "  [zram] $*"; }

if [ "$ENABLE" != "1" ]; then
    log "zram DISABLED — the kernel gets no zram device and S03zram will no-op"
    exit 0
fi

echo "=== Enabling zram (compressed swap in RAM) in $(basename "$DEFCONFIG") ==="

# Force a symbol on, whatever state it's currently in: drop any existing
# CONFIG_X= or "# CONFIG_X is not set" line, then append the enabled form.
# Same shape as readonly-rootfs.sh's enable_sym.
enable_sym() {
    local sym="$1"
    sed -i -E "/^(# )?${sym}[= ]/d" "$DEFCONFIG"
    printf '%s=y\n' "$sym" >> "$DEFCONFIG"
    grep -qE "^${sym}=y$" "$DEFCONFIG" || {
        echo "enable-zram: failed to enable $sym" >&2; exit 1
    }
    log "enabled ${sym}"
}

disable_sym() {
    local sym="$1"
    sed -i -E "/^(# )?${sym}[= ]/d" "$DEFCONFIG"
    printf '# %s is not set\n' "$sym" >> "$DEFCONFIG"
    log "disabled ${sym}"
}

# Everything is built IN (=y), not modular. Modules on this SDK are packaged to
# /oem/usr/ko and inserted late by the vendor's RkLunch.sh, which is after
# pcscd, after the camera stack and around when the app starts — i.e. after the
# window where the memory is actually needed. A built-in zram device exists
# before init runs, so S03zram can bring swap up at S03, ahead of every consumer.
enable_sym CONFIG_ZSMALLOC     # ZRAM `depends on` this; never auto-enabled
enable_sym CONFIG_ZRAM

# ZRAM `select`s CRYPTO_LZO, so this is already implied — set and asserted
# explicitly because it is what provides the compressor S03zram asks for by
# name. In this kernel (5.10) crypto/Makefile builds BOTH lzo.o and lzo-rle.o
# from CONFIG_CRYPTO_LZO, and zram's own default_compressor is "lzo-rle"
# (drivers/block/zram/zram_drv.c), so no separate symbol selects lzo-rle and
# none is needed.
enable_sym CONFIG_CRYPTO_LZO

# Swap support itself. `default y` in init/Kconfig with deps (MMU && BLOCK) that
# this board meets, and the stock defconfig carries no line for it either way,
# so this changes nothing today. It is pinned because zram without CONFIG_SWAP
# is a block device nothing can swapon — a silent, total loss of the feature if
# an SDK bump ever turns it off.
enable_sym CONFIG_SWAP

# See the header: this is the one zram feature that could put swapped pages on
# flash. Kept off at the kernel level rather than merely unconfigured.
disable_sym CONFIG_ZRAM_WRITEBACK

# Not enabled: CONFIG_ZRAM_MEMORY_TRACKING (debugfs per-page state — a debug
# feature that would expose swapped-page metadata on a device holding seed
# material) and CONFIG_ZSMALLOC_STAT (debugfs statistics, DEBUG_FS-gated).

echo "=== zram kernel configuration complete ==="
