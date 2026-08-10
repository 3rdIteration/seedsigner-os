#!/usr/bin/env bash
#
# uboot-recovery-config.sh <LUCKFOX_PICO_DIR>
#
# Non-dev U-Boot recovery config: bootdelay=0 + boot-counter → rockusb Loader
# failover. Shared by the GitHub Actions build and the local Docker builds
# (os-build.sh / build-local.sh) so all three stay in sync. Run it on non-dev
# builds only, BEFORE `./build.sh uboot`.
#
# Two patches to the board header, both hardware-verified on a live Pico Pro Max:
#
#  (1) Enable a MEMORY-BACKED boot counter. This Rockchip U-Boot 2017.09 fork's
#      drivers/bootcount/Kconfig only has CONFIG_BOOTCOUNT / _EXT — there is NO
#      CONFIG_BOOTCOUNT_LIMIT / _ENV symbol, so defconfig lines are silently
#      dropped (proven: the compiled U-Boot had zero bootcount code). Use the
#      always-built generic backend (drivers/bootcount/bootcount.c is obj-y) via
#      board-header #defines, pointed at a FREE GRF OS_REG scratch register
#      (0xFF020218): survives a warm reset (kernel-panic reboot loops keep
#      counting), clears on a cold power-cycle, no NAND wear. autoboot.c's
#      bootdelay_process() runs the increment + "bootcount > bootlimit ->
#      altbootcmd" check every boot. Proven on hardware: the counter incremented
#      6 -> 7 across a reboot.
#
#  (2) Bake bootlimit + altbootcmd into the COMPILED DEFAULT ENV. This U-Boot is
#      built ENV_IS_NOWHERE (no CONFIG_ENV_IS_* in any defconfig), so it NEVER
#      reads the mtd0 env that fw_setenv writes — proven on hardware: with
#      bootcount forced to 7 and mtd0 bootlimit=5, U-Boot used its built-in
#      default bootlimit (10) and booted normally. So bootlimit/altbootcmd must
#      be compiled in, via CONFIG_EXTRA_ENV_SETTINGS. altbootcmd zeroes the
#      counter reg then writes the proven reboot-mode Loader magic (0x5242C301 at
#      0xFF020200, same as `rk-reboot loader`) and resets. `mw`/`reset` both exist
#      in this U-Boot. The OS clears the counter (`devmem 0xFF020218 32 0`) once
#      userspace is up, so only boots that never get that far reach the limit.

set -u

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "uboot-recovery-config: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi
cd "$LUCKFOX_DIR"

echo "🔧 non-dev: U-Boot recovery config (bootdelay=0 + bootcount→loader)"
# bootdelay (already 0 on the Luckfox SDK; guard kept for other SDK versions).
for f in $(grep -rlE '^CONFIG_BOOTDELAY=[1-9]' sysdrv 2>/dev/null | grep -iE 'uboot|u-boot' || true); do
  sed -i -E 's/^CONFIG_BOOTDELAY=[1-9][0-9]*/CONFIG_BOOTDELAY=0/' "$f"; echo "  zeroed CONFIG_BOOTDELAY in $f"
done

bc=0
for h in $(find sysdrv -path '*uboot*/include/configs/rv1106_common.h' 2>/dev/null || true); do
  # (1) memory-backed bootcount #defines, inserted after CONFIG_PREBOOT
  if ! grep -q 'CONFIG_SYS_BOOTCOUNT_ADDR' "$h"; then
    awk '
      { print }
      !d && /^#define CONFIG_PREBOOT[ \t]*$/ {
        print "";
        print "/* SeedSigner boot-failover: memory-backed boot counter in a free GRF";
        print " * OS_REG scratch register (survives warm reset, clears on cold power-off). */";
        print "#define CONFIG_BOOTCOUNT_LIMIT";
        print "#define CONFIG_SYS_BOOTCOUNT_SINGLEWORD";
        print "#define CONFIG_SYS_BOOTCOUNT_ADDR\t0xFF020218";
        d=1
      }
    ' "$h" > "$h.ssbc" && mv "$h.ssbc" "$h"
  fi
  # (2) bake bootlimit + altbootcmd into the default env (U-Boot is ENV_IS_NOWHERE)
  if ! grep -q 'altbootcmd=mw.l 0xFF020218' "$h"; then
    awk '
      BEGIN { bs = sprintf("%c", 92); z = bs "0"; TAB = sprintf("%c", 9) }
      /^#define CONFIG_EXTRA_ENV_SETTINGS/ {
        tail = $0; sub(/^#define CONFIG_EXTRA_ENV_SETTINGS[ \t]*/, "", tail)
        print "#define CONFIG_EXTRA_ENV_SETTINGS" TAB bs
        print TAB "\"bootlimit=5" z "\"" TAB bs
        print TAB "\"altbootcmd=mw.l 0xFF020218 0; mw.l 0xff020200 0x5242c301; reset" z "\"" TAB bs
        if (tail ~ /[\\][ \t]*$/) { next } else { print TAB tail; next }
      }
      { print }
    ' "$h" > "$h.ssenv" && mv "$h.ssenv" "$h"
  fi
  if grep -q 'CONFIG_SYS_BOOTCOUNT_ADDR' "$h" && grep -q 'altbootcmd=mw.l 0xFF020218' "$h"; then
    echo "  enabled memory-backed bootcount + baked bootlimit/altbootcmd in $(basename "$h")"; bc=1
  fi
done
[ "$bc" -eq 1 ] || echo "  ⚠️  rv1106_common.h not patched — bootcount NOT enabled (userspace watchdog still covers app failures)"
