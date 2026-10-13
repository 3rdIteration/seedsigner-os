#!/bin/bash
# Print the artifact name tag for a Luckfox image or bundle, e.g.
#
#   SeSi-0.8.7_ShSi-B13-osproduction-signed-devkey
#   SeSi-0.8.7_ShSi-B13-pre-osproduction-dev-uart-signed-devkey
#
# Shared by os-build.sh (Docker/CI) and build-local.sh so the two cannot drift.
# Format:
#
#   <appref>-os<develop|production>[-dev-<lever>...]-<unsigned|signed[-devkey|-realkey]|burnable[-devkey|-realkey]>
#
# Why the -dev-<lever> tokens exist: a user flashed the B13-pre release image,
# named "...-osproduction-signed-devkey...", and it hung after the secure-boot
# screen. That release run was non-dev but passed disable_uart2_console_debug=
# false, so the serial console was on, and nothing in the file name said so. An
# image whose name says "production" must not quietly carry a debug setting.
#
# The rules:
#   * dev-uart     serial console (ttyFIQ0) left on. EVERY variant -- an image
#                  with the console on does not boot through to the app on the
#                  Pico, so it has to be visible even on a develop build.
#   * dev-testing  testing build (hardware test menu instead of Home). Every
#                  variant -- it is never a usable wallet.
#   On a production (non-dev) build, also every lever left away from its
#   production default (a develop build has these by design, so they stay off
#   its name):
#   * dev-adb      USB gadget mode (adb/RNDIS)
#   * dev-otg      USB dual-role (boots as gadget)
#   * dev-net      Ethernet debug channel (telnet/ssh) kept
#   * dev-rw       writable rootfs instead of read-only squashfs
#   * dev-bootlog  persistent boot log written to /userdata
#   * dev-adbfiles adb userspace not stripped
#
# Tokens are emitted in the fixed order above, so the name is deterministic.
#
# Usage: artifact-tag.sh key=value ...
#   appref=<app ref>              (required; sanitised to [A-Za-z0-9_.-])
#   variant=dev|non-dev           (required)
#   uart_console=on|off           serial console state, already resolved
#   testing=1|0
#   usb_mode=gadget|host|otg|auto (auto: non-dev=host, dev=gadget, as configure-usb-mode.sh)
#   debug_network=on|off|auto     (auto: off on non-dev)
#   readonly_rootfs=1|0|auto      resolved value preferred; auto: non-dev=1, dev=0
#   boot_log=on|off
#   harden_adb=on|off
#   fit_signature=1|0
#   burn_key_hash=1|0
#   real_key=1|0                  1 when a real (non-committed) FIT key is in use

set -euo pipefail

appref="" variant="" uart_console="off" testing="0" usb_mode="auto"
debug_network="auto" readonly_rootfs="auto" boot_log="off" harden_adb="on"
fit_signature="0" burn_key_hash="0" real_key="0"

for arg in "$@"; do
    key="${arg%%=*}"; val="${arg#*=}"
    [ "$key" != "$arg" ] || { echo "artifact-tag.sh: expected key=value, got '$arg'" >&2; exit 2; }
    case "$key" in
        appref|variant|uart_console|testing|usb_mode|debug_network|readonly_rootfs|boot_log|harden_adb|fit_signature|burn_key_hash|real_key)
            printf -v "$key" '%s' "$val" ;;
        *) echo "artifact-tag.sh: unknown key '$key'" >&2; exit 2 ;;
    esac
done

[ -n "$appref" ] || { echo "artifact-tag.sh: appref is required" >&2; exit 2; }

case "$variant" in
    dev)     variant_tag="develop" ;;
    non-dev) variant_tag="production" ;;
    *) echo "artifact-tag.sh: unknown build variant '$variant' (expected dev or non-dev)" >&2; exit 2 ;;
esac

dev_tags=""
add() { dev_tags="${dev_tags}-dev-$1"; }

case "$uart_console" in
    on)  add uart ;;
    off) ;;
    *) echo "artifact-tag.sh: uart_console must be on|off, got '$uart_console'" >&2; exit 2 ;;
esac
[ "$testing" = "1" ] && add testing

if [ "$variant" = "non-dev" ]; then
    case "$usb_mode" in
        gadget) add adb ;;
        otg)    add otg ;;
        host|auto|"") ;;
        *) echo "artifact-tag.sh: unknown usb_mode '$usb_mode'" >&2; exit 2 ;;
    esac
    [ "$debug_network" = "on" ] && add net
    [ "$readonly_rootfs" = "0" ] && add rw
    [ "$boot_log" = "on" ] && add bootlog
    [ "$harden_adb" = "off" ] && add adbfiles
fi

if [ "$fit_signature" = "1" ]; then
    if [ "$burn_key_hash" = "1" ]; then sb_state="burnable"; else sb_state="signed"; fi
    if [ "$real_key" = "1" ]; then sb_state="${sb_state}-realkey"; else sb_state="${sb_state}-devkey"; fi
else
    sb_state="unsigned"
fi

printf '%s' "$(printf '%s' "$appref" | tr -c 'A-Za-z0-9_.-' '_')-os${variant_tag}${dev_tags}-${sb_state}"
