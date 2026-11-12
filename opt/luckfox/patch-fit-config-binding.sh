#!/usr/bin/env bash
#
# patch-fit-config-binding.sh <LUCKFOX_PICO_DIR>
#
# Signed builds only (SEEDSIGNER_FIT_SIGNATURE=1): make the SPL and U-Boot bind
# the FIT configuration they BOOT to the configuration that was SIGNED. Shared
# by the GitHub Actions build and both local Docker builds (os-build.sh /
# build-local.sh) -- change this script, never one caller. Run it next to
# apply_fit_signature_config()/patch-mtd-part-parse.sh, BEFORE `build.sh uboot`
# (it edits a U-Boot C source that is compiled into both the SPL and U-Boot).
#
# WHY THIS EXISTS. The SDK's U-Boot is a 2017.09 fork, and its
# common/image-sig.c fit_config_check_sig() predates the upstream fixes for
# CVE-2020-10648 and CVE-2021-27097 / CVE-2021-27138. As shipped it:
#
#   * hashes exactly the nodes named in the signature node's own `hashed-nodes`
#     property, and never checks that the configuration it was asked to verify
#     is one of them. The property lives in the signature node, whose
#     properties are outside the signed region;
#   * picks the configuration to boot from /configurations `default`, which is
#     also outside the signed region (fdt_find_regions() includes a node's
#     properties only when the node is listed; /configurations is not);
#   * leaves any node that is NOT listed -- and is not the child of a listed
#     node -- entirely out of the hash, begin/end tags included, so nodes can
#     be added under /images and /configurations without changing the digest;
#   * resolves image and configuration names through libfdt's
#     fdt_subnode_offset(), which lets a lookup for "kernel" match a node named
#     "kernel@1".
#
# Together those mean the RSA signature proves that the genuine configuration
# is still PRESENT in the image, not that it is the one being booted. Both
# tiers use this function (common/spl/spl_fit.c for uboot.img,
# arch/arm/mach-rockchip/fit.c for boot.img), so it is the check the whole
# chain above the BootROM rests on. The repo's own PC-side verifier
# (secure-boot/fitsign.py) hashes every node's begin/end tag and so is
# stricter than the device was; this patch brings the device up to it.
#
# THE FIX -- the same rules upstream U-Boot enforces since 2020.04 / 2021.04,
# inserted into fit_config_check_sig() BEFORE the RSA check (and so before the
# SPL's rsa_burn_key_hash(), which runs on a successful verify):
#
#   1. the configuration that owns the signature node being checked must be
#      named in `hashed-nodes` ("Selected config not in hashed nodes");
#   2. no node anywhere in the FIT may have '@' in its name, so a name lookup
#      can only ever resolve to the exact node that was hashed;
#   3. every node directly under /images and /configurations must be named in
#      `hashed-nodes` -- a signed FIT carries no unsigned image or
#      configuration at all.
#
# Every image this build produces already satisfies all three (checked against
# shipped uboot.img/boot.img for mini/max/pi: no '@' names, the single `conf`
# and every image listed), so genuine releases verify exactly as before.
#
# Idempotent (marker check) and LOUD on any drift: a silently-skipped security
# patch is the failure mode this guards against. The built tree is re-checked
# by assert-uboot-fit-signature.sh.

set -eu

LUCKFOX_DIR="${1:-}"
if [ -z "$LUCKFOX_DIR" ] || [ ! -d "$LUCKFOX_DIR" ]; then
    echo "patch-fit-config-binding: luckfox-pico dir '${LUCKFOX_DIR:-<empty>}' not found" >&2
    exit 1
fi

[ "${SEEDSIGNER_FIT_SIGNATURE:-0}" = "1" ] || exit 0

IMAGE_SIG="$LUCKFOX_DIR/sysdrv/source/uboot/u-boot/common/image-sig.c"
MARKER="SEEDSIGNER-FIT-CONF-BINDING"

[ -f "$IMAGE_SIG" ] || { echo "patch-fit-config-binding: $IMAGE_SIG not found (SDK layout changed?)" >&2; exit 1; }

if grep -q "$MARKER" "$IMAGE_SIG"; then
    if grep -q 'ss_fit_conf_bound(fit, noffset, prop, end, err_msgp)' "$IMAGE_SIG"; then
        echo "  image-sig.c: FIT config-binding patch already present (idempotent re-run)"
        exit 0
    fi
    echo "patch-fit-config-binding: marker present but the call is missing; clean the SDK tree and retry" >&2
    exit 1
fi

open_before=$(tr -cd '{' < "$IMAGE_SIG" | wc -c)
close_before=$(tr -cd '}' < "$IMAGE_SIG" | wc -c)

python3 - "$IMAGE_SIG" "$MARKER" <<'PYEOF'
import sys

path, marker = sys.argv[1], sys.argv[2]

HELPER = (
    "/* " + marker + ": bind the configuration being booted to the one that\n"
    " * was signed. `hashed-nodes` and /configurations `default` both sit\n"
    " * outside the signed region, and unlisted nodes are not hashed at all, so\n"
    " * without these checks a valid signature only proves the genuine\n"
    " * configuration is still present in the image (CVE-2020-10648,\n"
    " * CVE-2021-27097, CVE-2021-27138).\n"
    " */\n"
    "static int ss_fit_node_hashed(const char *path, const char *prop,\n"
    "\t\t\t      const char *end)\n"
    "{\n"
    "\tconst char *name;\n"
    "\n"
    "\tfor (name = prop; name < end; name += strlen(name) + 1) {\n"
    "\t\tif (!strcmp(name, path))\n"
    "\t\t\treturn 1;\n"
    "\t}\n"
    "\n"
    "\treturn 0;\n"
    "}\n"
    "\n"
    "static int ss_fit_conf_bound(const void *fit, int sig_noffset,\n"
    "\t\t\t     const char *prop, const char *end,\n"
    "\t\t\t     char **err_msgp)\n"
    "{\n"
    "\tchar path[200];\n"
    "\tconst char *name, *leaf;\n"
    "\tint conf_noffset, noffset, depth = -1;\n"
    "\n"
    "\t/* the list is walked as NUL-terminated strings: insist on the NUL */\n"
    "\tif (!prop || end <= prop || end[-1] != '\\0') {\n"
    "\t\t*err_msgp = \"Malformed hashed-nodes property\";\n"
    "\t\treturn -1;\n"
    "\t}\n"
    "\n"
    "\t/* 1. the configuration that owns this signature must be signed */\n"
    "\tconf_noffset = fdt_parent_offset(fit, sig_noffset);\n"
    "\tif (conf_noffset < 0 ||\n"
    "\t    fdt_get_path(fit, conf_noffset, path, sizeof(path)) ||\n"
    "\t    !ss_fit_node_hashed(path, prop, end)) {\n"
    "\t\t*err_msgp = \"Selected config not in hashed nodes\";\n"
    "\t\treturn -1;\n"
    "\t}\n"
    "\n"
    "\t/* depth starts at -1 so the root is 0; libfdt returns a NON-negative\n"
    "\t * offset (the tag after the root's END_NODE) once depth drops below\n"
    "\t * zero, so the walk must stop on depth, not on the offset alone.\n"
    "\t */\n"
    "\tfor (noffset = fdt_next_node(fit, -1, &depth);\n"
    "\t     noffset >= 0 && depth >= 0;\n"
    "\t     noffset = fdt_next_node(fit, noffset, &depth)) {\n"
    "\t\t/* 2. no unit addresses: a name lookup must be exact */\n"
    "\t\tname = fdt_get_name(fit, noffset, NULL);\n"
    "\t\tif (!name || strchr(name, '@')) {\n"
    "\t\t\t*err_msgp = \"Node name contains @\";\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n"
    "\n"
    "\t\t/* 3. no unsigned image or configuration in a signed FIT */\n"
    "\t\tif (fdt_get_path(fit, noffset, path, sizeof(path))) {\n"
    "\t\t\t*err_msgp = \"Node path too long\";\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n"
    "\t\tif (!strncmp(path, \"/images/\", 8))\n"
    "\t\t\tleaf = path + 8;\n"
    "\t\telse if (!strncmp(path, \"/configurations/\", 16))\n"
    "\t\t\tleaf = path + 16;\n"
    "\t\telse\n"
    "\t\t\tcontinue;\n"
    "\t\tif (!strchr(leaf, '/') && !ss_fit_node_hashed(path, prop, end)) {\n"
    "\t\t\t*err_msgp = \"Unsigned image or config in signed FIT\";\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n"
    "\t}\n"
    "\n"
    "\treturn 0;\n"
    "}\n"
)

CALL = (
    "\t/* " + marker + " */\n"
    "\tif (ss_fit_conf_bound(fit, noffset, prop, end, err_msgp))\n"
    "\t\treturn -1;\n"
    "\n"
)


def patch(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit("patch-fit-config-binding: expected exactly one %s in %s, found %d "
                 "(SDK source changed?)" % (what, path, n))
    return text.replace(old, new, 1)


with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# 1. the helpers, just above fit_config_check_sig().
anchor = "int fit_config_check_sig(const void *fit, int noffset, int required_keynode,\n"
text = patch(text, anchor, HELPER + "\n" + anchor, "fit_config_check_sig() definition")

# 2. the call: after `hashed-nodes` has been fetched and bounded (prop/end/
#    count are set, count <= IMAGE_MAX_HASHED_NODES), before the regions are
#    built and long before info.crypto->verify().
call_anchor = "\t/* Create a list of node names from those strings */\n\tchar *node_inc[count];\n"
text = patch(text, call_anchor, CALL + call_anchor, "node_inc declaration")

# The call relies on these names existing exactly as the vendor wrote them.
for needle, what in (
    ('prop = fdt_getprop(fit, noffset, "hashed-nodes", &prop_len);', "hashed-nodes fetch"),
    ("end = prop ? prop + prop_len : prop;", "hashed-nodes end computation"),
    ("if (info.crypto->verify(&info, region, count, fit_value,", "RSA verify call"),
):
    if text.count(needle) != 1:
        sys.exit("patch-fit-config-binding: %s not found exactly once (SDK source changed?)" % what)
if text.index(CALL) > text.index("if (info.crypto->verify(&info, region, count, fit_value,"):
    sys.exit("patch-fit-config-binding: binding check landed AFTER the RSA verify - refusing")

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
PYEOF

grep -q "$MARKER" "$IMAGE_SIG" || { echo "patch-fit-config-binding: marker missing after patch" >&2; exit 1; }
grep -q 'ss_fit_conf_bound(fit, noffset, prop, end, err_msgp)' "$IMAGE_SIG" \
    || { echo "patch-fit-config-binding: binding call missing after patch" >&2; exit 1; }

open_after=$(tr -cd '{' < "$IMAGE_SIG" | wc -c)
close_after=$(tr -cd '}' < "$IMAGE_SIG" | wc -c)
[ "$((open_after - close_after))" = "$((open_before - close_before))" ] \
    || { echo "patch-fit-config-binding: brace balance changed in image-sig.c -- refusing" >&2; exit 1; }

echo "  image-sig.c: booted FIT configuration is now bound to the signed one (config in hashed-nodes, no @ names, no unsigned image/config)"
