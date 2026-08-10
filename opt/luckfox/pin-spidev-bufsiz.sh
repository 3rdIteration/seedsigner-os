#!/usr/bin/env bash
#
# pin-spidev-bufsiz.sh <LUCKFOX_PICO_DIR> <HARDWARE> [BUFSIZ]
#
# Pin the spidev per-transfer buffer size on the kernel command line. Shared by
# the GitHub Actions build and both local Docker builds (os-build.sh /
# build-local.sh) — change this script, never one caller. Must run BEFORE the
# kernel/DTB is built.
#
#   HARDWARE  RV1103_Luckfox_Pico_Mini | RV1106_Luckfox_Pico_Pro_Max |
#             RV1106_Luckfox_Pico_Pi
#   BUFSIZ    bytes (default 8192)
#
# WHY: spidev_open() kmallocs its tx AND rx buffers at `bufsiz` EACH, physically
# contiguous. The vendor default is large enough to be an order-6 (256 KB)
# allocation, which on the 64 MB Mini fails once memory is fragmented:
#
#   python: page allocation failure: order:6 ... spidev_open+0x65/0x94
#   SPIError: [Errno 12] Opening SPI device: Cannot allocate memory
#
# ...so the display never opens even though the panel, overlays and wiring are
# all fine — the pre-app splash draws correctly on the very same boot, which is
# what makes this failure so easy to misread as a display bug.
#
# 8 KB is ample: ST7789._chunked_transfer() caps a single transfer at
# CHUNK_SIZE = 4096 and halves on EMSGSIZE, so nothing ever asks for more. That
# makes the buffer an order-1 allocation, which succeeds under memory pressure.
#
# Applied to every board, not just the Mini: it costs the larger boards nothing
# and pins a value that would otherwise silently inherit whatever the vendor
# kernel picks. spidev's bufsiz is module_param(..., S_IRUGO) — read-only at
# runtime — so the kernel command line is the only place it can be set.

set -eu

LUCKFOX_DIR="${1:-}"
HARDWARE="${2:-}"
BUFSIZ="${3:-8192}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "pin-spidev-bufsiz: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

log() { echo "  [spidev] $*"; }

case "$HARDWARE" in
    RV1103_Luckfox_Pico_Mini)
        DTS_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1103g-luckfox-pico-mini.dts"
        DTSI_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1103-luckfox-pico-ipc.dtsi"
        ;;
    RV1106_Luckfox_Pico_Pro_Max)
        DTS_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pro-max.dts"
        DTSI_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1106-luckfox-pico-pro-max-ipc.dtsi"
        ;;
    RV1106_Luckfox_Pico_Pi)
        DTS_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pi.dts"
        DTSI_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1106-luckfox-pico-pi-ipc.dtsi"
        ;;
    *)
        echo "pin-spidev-bufsiz: unsupported hardware '$HARDWARE'" >&2
        exit 1
        ;;
esac

echo "=== Pinning spidev.bufsiz=${BUFSIZ} for ${HARDWARE} ==="

PATCHED=0
for target in "$DTS_FILE" "$DTSI_FILE"; do
    full="$LUCKFOX_DIR/$target"
    [ -f "$full" ] || continue
    # Append inside an existing chosen bootargs="..." only; no-op otherwise.
    if grep -Eq 'bootargs[[:space:]]*=' "$full" && ! grep -q 'spidev.bufsiz' "$full"; then
        sed -i -E "/bootargs[[:space:]]*=/ s/(bootargs[[:space:]]*=[[:space:]]*\"[^\"]*)\"/\1 spidev.bufsiz=${BUFSIZ}\"/" "$full"
        log "spidev.bufsiz=${BUFSIZ} added to $target"
        PATCHED=1
    elif grep -q 'spidev.bufsiz' "$full"; then
        log "spidev.bufsiz already present in $target"
        PATCHED=1
    fi
done

# Assert rather than warn: a silent miss reintroduces the order-6 allocation and
# the Mini loses its display again, with no build-time signal that anything is
# wrong. That failure costs a flash cycle and looks like a hardware fault.
if [ "$PATCHED" -ne 1 ]; then
    echo "pin-spidev-bufsiz: ERROR — could not add spidev.bufsiz to any bootargs in $DTS_FILE / $DTSI_FILE" >&2
    grep -nE 'bootargs' "$LUCKFOX_DIR/$DTS_FILE" "$LUCKFOX_DIR/$DTSI_FILE" 2>/dev/null >&2 \
        || echo "  (no bootargs found at all)" >&2
    exit 1
fi

grep -nE 'bootargs' "$LUCKFOX_DIR/$DTS_FILE" "$LUCKFOX_DIR/$DTSI_FILE" 2>/dev/null || true
echo "=== spidev.bufsiz pinned ==="
