#!/usr/bin/env bash
#
# configure-usb-mode.sh <LUCKFOX_PICO_DIR> <HARDWARE> <USB_MODE> <BUILD_VARIANT>
#
# Set the RV1103/RV1106 USB controller role in the board DTS. Shared by the
# GitHub Actions build and the local Docker builds (os-build.sh /
# build-local.sh) so all three stay in sync — this switch is what removes
# adb/RNDIS from non-dev images.
#
#   HARDWARE       RV1103_Luckfox_Pico_Mini | RV1106_Luckfox_Pico_Pro_Max |
#                  RV1106_Luckfox_Pico_Pi
#   USB_MODE       gadget | host | otg | auto/empty
#                  (auto: non-dev = host — air-gapped, drives USB peripherals,
#                   no adb/RNDIS; dev = gadget — USB device mode with adb.
#                   otg = dual-role: boots as gadget but runtime-switchable to
#                   host via /sys/kernel/debug/usb/ffb00000.usb/mode.)
#   BUILD_VARIANT  non-dev | dev (only consulted when USB_MODE is auto/empty)
#
# Idempotent: appends a last-wins &usbdrd_dwc3 override once (device-tree — the
# final property assignment wins); gadget mode is the DTS default (no change).

set -eu

LUCKFOX_DIR="${1:-}"
HARDWARE="${2:-}"
USB_MODE="${3:-auto}"
BUILD_VARIANT="${4:-dev}"

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "configure-usb-mode: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi
cd "$LUCKFOX_DIR"

# USB role: explicit gadget/host/otg wins; otherwise (auto/empty) non-dev is host
# (air-gapped, drives peripherals, no adb/RNDIS) and dev is gadget (adb).
case "$USB_MODE" in
  gadget|host|otg) ;;
  *) if [ "$BUILD_VARIANT" = "non-dev" ]; then USB_MODE="host"; else USB_MODE="gadget"; fi ;;
esac

if [ "$HARDWARE" = "RV1103_Luckfox_Pico_Mini" ]; then
  DTS_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1103g-luckfox-pico-mini.dts"
elif [ "$HARDWARE" = "RV1106_Luckfox_Pico_Pro_Max" ]; then
  DTS_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pro-max.dts"
elif [ "$HARDWARE" = "RV1106_Luckfox_Pico_Pi" ]; then
  DTS_FILE="sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-luckfox-pico-pi.dts"
else
  echo "ERROR: Unknown hardware for USB-mode DTS patch: $HARDWARE"; exit 1
fi

echo "USB mode: $USB_MODE  (target DTS: $DTS_FILE)"
if [ ! -f "$DTS_FILE" ]; then
  echo "ERROR: DTS source file not found: $DTS_FILE"; exit 1
fi
echo "USB dr_mode (before):"; grep -nE 'dr_mode' "$DTS_FILE" || echo "  (none in board DTS)"

if [ "$USB_MODE" = "gadget" ]; then
  echo "USB left in gadget/peripheral mode (adb available) — DTS default, no change"
else
  # host or otg: append a last-wins &usbdrd_dwc3 dr_mode override (device-tree:
  # the final property assignment wins). host = no device gadget (no adb/RNDIS),
  # drives external USB peripherals. otg = dual-role: boots as gadget but the
  # controller allows a runtime role switch to host for live testing. Idempotent.
  if ! grep -q 'SeedSigner USB role override' "$DTS_FILE"; then
    printf '\n/* SeedSigner USB role override (usb_mode=%s). host: drive external USB\n * peripherals (camera/smartcard), no adb/RNDIS. otg: dual-role, runtime\n * switchable via /sys/kernel/debug/usb/ffb00000.usb/mode. */\n&usbdrd_dwc3 {\n\tdr_mode = "%s";\n};\n' "$USB_MODE" "$USB_MODE" >> "$DTS_FILE"
  fi
  echo "USB dr_mode (after):"; grep -nE 'dr_mode' "$DTS_FILE"
  if ! grep -q "dr_mode = \"$USB_MODE\"" "$DTS_FILE"; then
    echo "ERROR: failed to set USB dr_mode=$USB_MODE in $DTS_FILE"; exit 1
  fi
  echo "✅ USB set to $USB_MODE mode in $DTS_FILE"
fi
