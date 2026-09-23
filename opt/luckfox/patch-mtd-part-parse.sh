#!/usr/bin/env bash
#
# patch-mtd-part-parse.sh <LUCKFOX_PICO_DIR>
#
# Signed builds only (SEEDSIGNER_FIT_SIGNATURE=1): close the SPI-NAND half of
# the M1 env->cmdline bypass. Shared by the GitHub Actions build and both local
# Docker builds (os-build.sh / build-local.sh) -- change this script, never one
# caller. Run it next to apply_fit_signature_config()/lock-kernel-cmdline.sh,
# BEFORE `build.sh uboot` (it edits U-Boot C sources that then get compiled).
#
# WHY THIS EXISTS. lock-kernel-cmdline.sh stops CONFIG_ENVF_LIST from importing
# mtdparts/blkdevparts into U-Boot's global environment -- but that whitelist is
# not the only consumer of the unsigned env partition. disk/part_env.c reads
# env.img DIRECTLY (envf_get()) and hands the partition names to the block
# layer; two call sites then serialise them into the kernel command line:
#
#   * arch/arm/mach-rockchip/board.c bootargs_add_partition(): the
#     `#ifdef CONFIG_MTD_BLK` fallback appends mtd_part_parse(NULL) whenever the
#     global env has no `mtdparts` (exactly the signed-build case once
#     lock-kernel-cmdline.sh has stripped it); and
#   * common/spl/spl_fit.c: the SPL appends mtd_part_parse(desc) into the loaded
#     U-Boot FIT's /chosen/bootargs when booting from BLK_MTD_SPI_NAND.
#
# Both share drivers/mtd/mtd_blk.c mtd_part_parse(), which emits each partition
# as `0x<size>@0x<start>(<name>)` with <name> copied VERBATIM from part_env.c --
# and part_env.c takes everything up to the first ')' (PART_NAME_LEN 32, spaces
# and '=' allowed). A name like `rootfs rdinit=/q` therefore reaches the kernel
# cmdline as `...mtdparts=...(rootfs rdinit=/q)`, the kernel splits it on the
# space, and a failed rdinit= falls through to /bin/sh in the SIGNED initramfs
# (init/main.c kernel_init) -- the same pre-verification root shell as M1, on
# SPI-NAND. The SD/eMMC path never fires this (devtype is "mmc"), which is why
# lock-kernel-cmdline.sh alone is not enough.
#
# THE FIX.
#   * mtd_blk.c mtd_part_parse(): sanitise info.name in place (keep only
#     [A-Za-z0-9_-], replace everything else with '_') before any snprintf emits
#     it, so no whitespace/'='/')' can ever split the cmdline token. info.name is
#     the ONLY attacker-controlled field mtd_part_parse emits (size/start are
#     %x; product/MTD_PART_NAND_HEAD are compile-time). The struct is untouched
#     beyond this function, so U-Boot's own partition lookups are unaffected, and
#     our real names (env/idblock/uboot/boot/userdata/rootfs) are unchanged.
#   * board.c bootargs_add_partition(): skip the CONFIG_MTD_BLK fallback when the
#     bootargs already carry a partition token, so the signed-DTB layout baked by
#     apply_signed_nand_bootargs is authoritative instead of being overridden by
#     the env-derived one (the later token would otherwise win). Fail-safe: with
#     no token present it appends exactly as before, so a missed bake cannot
#     strand a board.
#
# Idempotent (marker check) and LOUD on any drift: a silently-skipped security
# patch is the failure mode this guards against. The built tree is re-checked by
# assert-uboot-fit-signature.sh.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "patch-mtd-part-parse: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || exit 0

UBOOT_DIR="$LUCKFOX_DIR/sysdrv/source/uboot/u-boot"
MTD_BLK="$UBOOT_DIR/drivers/mtd/mtd_blk.c"
BOARD_C="$UBOOT_DIR/arch/arm/mach-rockchip/board.c"
MARKER="SEEDSIGNER-CMDLINE-SANITIZE"

for f in "$MTD_BLK" "$BOARD_C"; do
    [ -f "$f" ] || { echo "patch-mtd-part-parse: $f not found (SDK layout changed?)" >&2; exit 1; }
done

mtd_marked=0
board_marked=0
grep -q "$MARKER" "$MTD_BLK" && mtd_marked=1
grep -q "$MARKER" "$BOARD_C" && board_marked=1
if [ "$mtd_marked" = 1 ] && [ "$board_marked" = 1 ]; then
    echo "  mtd_blk.c/board.c: cmdline-sanitise patch already present (idempotent re-run)"
    exit 0
fi
if [ "$mtd_marked" = 1 ] || [ "$board_marked" = 1 ]; then
    echo "patch-mtd-part-parse: partial marker (mtd_blk=$mtd_marked board=$board_marked); clean the SDK tree and retry" >&2
    exit 1
fi

# Brace counts must be unchanged by the insertion (net-zero) -- a cheap canary
# for a mangled edit, since we cannot compile U-Boot here.
mtd_open_before=$(tr -cd '{' < "$MTD_BLK" | wc -c)
mtd_close_before=$(tr -cd '}' < "$MTD_BLK" | wc -c)
board_open_before=$(tr -cd '{' < "$BOARD_C" | wc -c)
board_close_before=$(tr -cd '}' < "$BOARD_C" | wc -c)

python3 - "$MTD_BLK" "$BOARD_C" "$MARKER" <<'PYEOF'
import sys

mtd_path, board_path, marker = sys.argv[1], sys.argv[2], sys.argv[3]

HELPER = (
    "/* " + marker + ": partition names are copied from the UNSIGNED env\n"
    " * partition (disk/part_env.c) and mtd_part_parse() serialises them into\n"
    " * the kernel command line. Whitespace in a name would split that token\n"
    " * and let a crafted name inject parameters (e.g. rdinit=), bypassing the\n"
    " * rootfs verifier. Keep only [A-Za-z0-9_-]; replace the rest with '_'.\n"
    " */\n"
    "static void ss_sanitize_part_name(uchar *name)\n"
    "{\n"
    "\tuchar *q;\n"
    "\n"
    "\tfor (q = name; *q; q++) {\n"
    "\t\tif ((*q >= 'a' && *q <= 'z') || (*q >= 'A' && *q <= 'Z') ||\n"
    "\t\t    (*q >= '0' && *q <= '9') || *q == '_' || *q == '-')\n"
    "\t\t\tcontinue;\n"
    "\t\t*q = '_';\n"
    "\t}\n"
    "}\n"
)


def patch(path, old, new, what):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    n = text.count(old)
    if n != 1:
        sys.exit("patch-mtd-part-parse: expected exactly one %s in %s, found %d "
                 "(SDK source changed?)" % (what, path, n))
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new, 1))


# 1. mtd_blk.c: define the helper just above mtd_part_parse().
anchor = "char *mtd_part_parse(struct blk_desc *dev_desc)\n{"
patch(mtd_path, anchor, HELPER + "\n" + anchor, "mtd_part_parse() definition")

# 2. mtd_blk.c: sanitise the name as soon as it is fetched -- every later
#    snprintf in the loop (incl. the grow-tag branches) reuses this struct.
debug_line = '\t\tdebug("name is %s, start addr is %x\\n", info.name,'
patch(mtd_path, debug_line,
      "\t\tss_sanitize_part_name(info.name);\t/* " + marker + " */\n" + debug_line,
      "mtd_part_parse() debug line")

# 3. board.c: do not override a signed layout with the env-derived one.
board_old = '#ifdef CONFIG_MTD_BLK\n\tif (!env_get("mtdparts")) {'
board_new = (
    '#ifdef CONFIG_MTD_BLK\n'
    "\t/* " + marker + ": if the signed DTB already carries the partition\n"
    "\t * layout, do not override it with the env-derived one -- this fallback\n"
    "\t * otherwise re-reads the unsigned env via disk/part_env.c and, appended\n"
    "\t * last, wins on SPI-NAND. Fail-safe: with no token present it appends\n"
    "\t * exactly as before.\n"
    "\t */\n"
    '\tif (!env_get("mtdparts") &&\n'
    '\t    !(env_get("bootargs") &&\n'
    '\t      (strstr(env_get("bootargs"), "mtdparts=") ||\n'
    '\t       strstr(env_get("bootargs"), "blkdevparts=")))) {'
)
patch(board_path, board_old, board_new, "CONFIG_MTD_BLK fallback")
PYEOF

grep -q "$MARKER" "$MTD_BLK" || { echo "patch-mtd-part-parse: marker missing in mtd_blk.c after patch" >&2; exit 1; }
grep -q "$MARKER" "$BOARD_C" || { echo "patch-mtd-part-parse: marker missing in board.c after patch" >&2; exit 1; }
grep -q 'ss_sanitize_part_name(info.name);' "$MTD_BLK" || { echo "patch-mtd-part-parse: sanitize call missing in mtd_blk.c" >&2; exit 1; }

mtd_open_after=$(tr -cd '{' < "$MTD_BLK" | wc -c)
mtd_close_after=$(tr -cd '}' < "$MTD_BLK" | wc -c)
board_open_after=$(tr -cd '{' < "$BOARD_C" | wc -c)
board_close_after=$(tr -cd '}' < "$BOARD_C" | wc -c)
# The helper adds balanced braces, so the OPEN-CLOSE difference must be
# unchanged by the edit; a moved/rehashed brace is caught here.
[ "$((mtd_open_after - mtd_close_after))" = "$((mtd_open_before - mtd_close_before))" ] \
    || { echo "patch-mtd-part-parse: brace balance changed in mtd_blk.c -- refusing" >&2; exit 1; }
[ "$((board_open_after - board_close_after))" = "$((board_open_before - board_close_before))" ] \
    || { echo "patch-mtd-part-parse: brace balance changed in board.c -- refusing" >&2; exit 1; }

echo "  mtd_blk.c/board.c: partition-name sanitisation + signed-layout guard installed"
