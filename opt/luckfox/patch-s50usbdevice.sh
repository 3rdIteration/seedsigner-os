#!/usr/bin/env bash
#
# patch-s50usbdevice.sh <ROOTFS_DIR>
#
# USB host-mode fix, shared by the GitHub Actions build and the local Docker
# builds (os-build.sh / build-local.sh): the SDK's S50usbdevice unconditionally
# configures the USB *device* gadget (adb/RNDIS) and runs BEFORE S99seedsigner
# in rcS. In host mode there is no UDC to bind, so it hangs the boot before the
# app ever starts (this is the host/otg no-boot we hit; S99usb0config is
# already host-aware, S50usbdevice is not). Make it skip gadget setup when the
# controller is in host mode — a runtime dr_mode check, so it's a no-op on
# gadget/peripheral builds. Idempotent.
#
# IMPORTANT: the skip still mounts configfs. S50usbdevice's configfs_init is
# the only thing on this SDK that mounts it, and the Luckfox overlay system
# (luckfox-config, run by S99luckfoxconfigload) needs configfs to enable SPI0
# for the display. Skipping it entirely left no /dev/spidev0.0 -> app crash.

set -u

ROOTFS="${1:-}"
if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "patch-s50usbdevice: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi

S50="$ROOTFS/etc/init.d/S50usbdevice"
if [ -f "$S50" ] && ! grep -q 'SeedSigner: host-mode skip' "$S50"; then
  awk '
    { print }
    !d && /ifconfig lo up/ {
      print "\t# SeedSigner: host-mode skip - no USB device gadget when dr_mode=host.";
      print "\t# BUT still mount configfs: this SDK script is what mounts it (in";
      print "\t# configfs_init below), and the Luckfox overlay system (luckfox-config,";
      print "\t# run by S99luckfoxconfigload) needs configfs to enable SPI0 for the";
      print "\t# display. Skipping it here left no /dev/spidev0.0 -> app crash.";
      print "\tif grep -q host /proc/device-tree/usbdrd/usb@ffb00000/dr_mode 2>/dev/null; then";
      print "\t\techo \"S50usbdevice: dr_mode=host, mounting configfs + skipping USB gadget\"";
      print "\t\tmount -t configfs none /sys/kernel/config 2>/dev/null";
      print "\t\texit 0";
      print "\tfi";
      d=1
    }
  ' "$S50" > "$S50.ssnew" && mv "$S50.ssnew" "$S50" && chmod +x "$S50"
  echo "🔧 Patched S50usbdevice to be host-aware (skip USB gadget when dr_mode=host)"
else
  echo "ℹ️  S50usbdevice not patched (absent or already host-aware)"
fi
