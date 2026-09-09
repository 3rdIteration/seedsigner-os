#!/usr/bin/env bash
#
# patch-sd-update-scripts.sh <LUCKFOX_PICO_DIR>
#
# Repoint the SDK-generated U-Boot flashing scripts (output/image/sd_update.txt
# and tftp_update.txt) at a staging address that the whole rootfs actually fits
# below, and hard-fail if any image no longer does. Shared by the GitHub Actions
# build and both local Docker builds — change this script, never one caller.
# Must run AFTER `build.sh firmware` and BEFORE the NAND bundle is packaged.
#
# WHY THIS EXISTS
#
# The microSD auto-flash path (copy the NAND bundle onto a FAT card, power on,
# U-Boot's `sd_update` command runs sd_update.txt) hung on the LAST step, with
# the boot log ending at:
#
#     $ mw.b ${ramdisk_addr_r} 0xff 0x26A0000; fatload mmc 1 ... rootfs.img; ...
#
# and no "reading rootfs.img" line after it — i.e. U-Boot died inside mw.b,
# before fatload ever started. Every earlier partition flashed fine.
#
# The SDK emits every step as "stage the whole partition image at
# ${ramdisk_addr_r}, then mtd write it", with no regard for how big the image is
# or how much room there is above that address. On a Luckfox Pico Mini (RV1103,
# 64 MiB DRAM) that leaves ~31 MiB, and SeedSigner's rootfs is past it:
#
#   DRAM                               64 MiB (0x0 - 0x4000000)
#   ramdisk_addr_r (U-Boot built-in)   0x00E00000   <- not in env.img; it is the
#                                                      compiled-in default
#   relocated U-Boot code              0x03F80000   ("Relocation Offset: 03d80000"
#                                                      + the 0x00200000 load base)
#   bottom of U-Boot's reserved area   ~0x02DF0000  ("Relocation fdt: 02dfa098")
#     (malloc heap -> gd -> fdt -> stack, all reserved downward from ram_top)
#
#   rootfs.img 0x26A0000 staged at 0x00E00000 ends at 0x034A0000
#     = ~6.6 MiB INTO U-Boot's own stack, global data, fdt and malloc heap.
#
# So mw.b overwrote the loader it was running from. No output, no error, dead
# board mid-flash. The images themselves were always fine — flashing the same
# files over USB (update.img / rkdeveloptool / SocToolKit) works, because that
# path streams to flash and never stages a partition in DRAM.
#
# THE FIX: stage low instead. Nothing below ramdisk_addr_r is live once U-Boot
# has relocated — the pre-relocation copy at 0x00200000 is dead — and, checked
# rather than assumed, the sd_update.txt text buffer is NOT at ${scriptaddr}:
# the `sd_update` handler mallocs a 0x6000-byte buffer, so the script being
# executed lives in the heap up at ~0x02E00000+, above any staging buffer we
# choose. Staging at 0x00100000 turns a ~31 MiB window into ~44 MiB.
#
# The ceiling below is deliberately the Mini's. Max (128 MiB) and Pi (256 MiB)
# have more DRAM, so a lower base and a lower ceiling are always safe there —
# and one number that is right everywhere beats three that drift apart.
#
# NOT DONE ON PURPOSE, twice bitten:
#
#   * No chunked writes (fatload with <bytes>/<pos> + several mtd writes at
#     stepped offsets). That would be size-independent, but U-Boot's `mtd write`
#     skips bad blocks ("Skipping bad block at 0x%08llx", and there is no
#     .dontskipbad for write — only for erase). One bad block inside a chunk
#     shifts everything after it, and the next chunk, written at a hardcoded
#     offset, lands on already-programmed pages.
#
#   * No `reset` appended to sd_update.txt (tftp_update.txt has one, and that is
#     correct for it). With the card still inserted, a reset re-enters sd_update
#     and reflashes the board forever.

set -eu

LUCKFOX_DIR="${1:-}"

# Where partition images are staged in DRAM before `mtd write`. See above.
STAGE_BASE="${SS_UBOOT_STAGE_BASE:-0x00100000}"
# Highest address a staged image may reach. 0x02DF0000 is where the running
# loader's reserved region was observed to start; 0x02D00000 keeps 1 MiB of
# slack under it, because the stack grows DOWN from there during the flash.
STAGE_CEILING="${SS_UBOOT_STAGE_CEILING:-0x02D00000}"

log()  { echo "  [sdupd] $*"; }
fail() { echo "  [sdupd] ❌ $*" >&2; exit 1; }

if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "patch-sd-update-scripts: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

IMAGE_DIR="$LUCKFOX_DIR/output/image"

echo "=== Patching U-Boot update scripts ==="

if [ ! -d "$IMAGE_DIR" ]; then
    fail "image output dir not found: $IMAGE_DIR (run 'build.sh firmware' first)"
fi

base_dec=$(( STAGE_BASE ))
ceil_dec=$(( STAGE_CEILING ))
[ "$ceil_dec" -gt "$base_dec" ] \
    || fail "staging ceiling $STAGE_CEILING is not above staging base $STAGE_BASE"
window=$(( ceil_dec - base_dec ))

log "staging base $STAGE_BASE, ceiling $STAGE_CEILING ($(( window / 1024 / 1024 )) MiB window)"

patched_any=0

for name in sd_update.txt tftp_update.txt; do
    script="$IMAGE_DIR/$name"

    # An SD- or eMMC-boot profile does not necessarily emit these; that is not an
    # error here. The NAND bundle path checks for them itself
    # (validate_nand_oriented_output in os-build.sh).
    if [ ! -f "$script" ]; then
        log "(skip) $name not present"
        continue
    fi

    if grep -q '\${ramdisk_addr_r}' "$script"; then
        sed -i "s|\${ramdisk_addr_r}|$STAGE_BASE|g" "$script"
        if grep -q '\${ramdisk_addr_r}' "$script"; then
            fail "\${ramdisk_addr_r} still present in $name after rewrite"
        fi
        log "$name: staging address -> $STAGE_BASE"
        patched_any=1
    elif grep -q "^mw\.b[[:space:]]\{1,\}$STAGE_BASE[[:space:]]" "$script"; then
        # Already rewritten by an earlier call. Fall through to the size guard
        # anyway — re-running must not be the way the check gets skipped.
        log "$name: already staged at $STAGE_BASE"
        patched_any=1
    else
        log "(skip) $name does not stage via \${ramdisk_addr_r}"
        continue
    fi

    # Size guard. Each step declares the bytes it will stage as the mw.b fill
    # length, so that is the number to check — not the file on disk, which is
    # what the SDK derived it from anyway. Today's rootfs clears the ceiling by
    # a few MiB; without this check, the build that first exceeds it would ship
    # a bundle that bricks the SD path silently, exactly as before.
    overrun=0
    steps=0
    while IFS= read -r line; do
        case "$line" in
            mw.b*) ;;
            *) continue ;;
        esac

        size="$(printf '%s\n' "$line" \
            | sed -n 's/^mw\.b[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}0xff[[:space:]]\{1,\}\([^;[:space:]]\{1,\}\).*/\1/p')"
        [ -n "$size" ] || fail "could not read the staged size from a $name step: $line"

        img="$(printf '%s\n' "$line" \
            | sed -n 's/.*\(fatload mmc [0-9]\{1,\}\|tftp\)[[:space:]]\{1,\}[^[:space:]]\{1,\}[[:space:]]\{1,\}\([^;[:space:]]\{1,\}\).*/\2/p')"
        [ -n "$img" ] || img="(unnamed step)"

        steps=$(( steps + 1 ))
        end=$(( base_dec + size ))

        if [ "$end" -gt "$ceil_dec" ]; then
            over=$(( end - ceil_dec ))
            echo "  [sdupd] ❌ $img: $size staged at $STAGE_BASE ends at $(printf '0x%08X' "$end")" >&2
            echo "  [sdupd]    that is $(( (over + 1048575) / 1048576 )) MiB past the $STAGE_CEILING ceiling" >&2
            overrun=1
        else
            log "$img: $size -> ends $(printf '0x%08X' "$end") ($(( (ceil_dec - end) / 1048576 )) MiB spare)"
        fi
    done < "$script"

    [ "$steps" -gt 0 ] || fail "$name has no mw.b staging steps to check"

    if [ "$overrun" -ne 0 ]; then
        echo "" >&2
        echo "  [sdupd] An image no longer fits the U-Boot staging window on a 64 MiB board." >&2
        echo "  [sdupd] Staging it would overwrite U-Boot's own stack/heap and hang the" >&2
        echo "  [sdupd] microSD auto-flash mid-write, with no error on the console." >&2
        echo "  [sdupd] Shrink the image, or flash over USB with update.img instead." >&2
        fail "$name: staged image exceeds the U-Boot staging window"
    fi

    log "✅ $name verified: $steps step(s), all within the staging window"
done

if [ "$patched_any" -eq 0 ]; then
    log "no U-Boot update scripts needed patching"
fi

echo "=== U-Boot update scripts patched ==="
