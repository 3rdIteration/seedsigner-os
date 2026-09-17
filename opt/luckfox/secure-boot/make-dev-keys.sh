#!/usr/bin/env bash
#
# make-dev-keys.sh — produce the dev.{key,pubkey,crt} key triple that Rockchip's
# mkimage-based FIT signing expects in a signing key dir.
#
# BOTH signing paths need this exact triple, under the "dev" key-name-hint the
# shipped .its files carry:
#   * the in-SDK build  (sysdrv/source/uboot/u-boot/scripts/fit-core.sh ->
#     check_rsa_keys + `mkimage -k keys/`) when CONFIG_FIT_SIGNATURE=y, and
#   * the post-build resign (rkbin/tools/fit-sign.sh --key-dir <dir>).
# mkimage reads dev.key (RSA private, PEM) and dev.crt (self-signed X.509 whose
# public key it embeds into the FIT / SPL DTB); rk_sign_tool + check_rsa_keys
# also want dev.pubkey (public, PEM). All three must be present or signing
# aborts with "ERROR: No keys/dev.key".
#
# This is the single source of that triple, shared by os-build.sh (throwaway
# build key) and sign-secure-boot.sh (the real signing key). RSA public exponent
# is F4 (65537), required by U-Boot's RSA verifier.
#
# Usage:
#   make-dev-keys.sh --out <dir> [--bits 2048|4096]        # generate a fresh key
#   make-dev-keys.sh --out <dir> --from <private_key.pem>  # wrap an existing key
#                                                          # (e.g. a BIP85-derived
#                                                          #  key exported from a
#                                                          #  SeedSigner)
#
set -euo pipefail

OUT=""; BITS="2048"; FROM=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT="$2"; shift 2;;
    --bits)  BITS="$2"; shift 2;;
    --from)  FROM="$2"; shift 2;;
    --force) FORCE=1; shift;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "make-dev-keys: unknown argument: $1" >&2; exit 1;;
  esac
done

[ -n "$OUT" ] || { echo "make-dev-keys: --out <dir> is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "make-dev-keys: openssl not found on PATH" >&2; exit 1; }

mkdir -p "$OUT"
if [ "$FORCE" != 1 ] && [ -f "$OUT/dev.key" ]; then
  echo "make-dev-keys: $OUT/dev.key already exists — refusing to overwrite (pass --force to replace)." >&2
  echo "  Replacing a signing key orphans every device already fused to its pubkey." >&2
  exit 1
fi

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "make-dev-keys: --from key not found: $FROM" >&2; exit 1; }
  # Normalise whatever RSA private key was given (PKCS#1 or PKCS#8) to the
  # traditional PEM mkimage/rk_sign_tool read. Fails loudly if it is not RSA.
  openssl rsa -in "$FROM" -out "$OUT/dev.key" >/dev/null 2>&1 \
    || { echo "make-dev-keys: could not read an RSA private key from $FROM" >&2; exit 1; }
else
  openssl genrsa -F4 -out "$OUT/dev.key" "$BITS" >/dev/null 2>&1 \
    || { echo "make-dev-keys: openssl genrsa failed" >&2; exit 1; }
fi

openssl rsa -in "$OUT/dev.key" -pubout -out "$OUT/dev.pubkey" >/dev/null 2>&1 \
  || { echo "make-dev-keys: could not derive dev.pubkey" >&2; exit 1; }
# The -subj value starts with "/", which MSYS/Git-Bash on Windows would rewrite
# into a drive path before openssl sees it. MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL
# disable that; both are simply ignored on Linux (the Docker build).
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  openssl req -batch -new -x509 -days 3650 -key "$OUT/dev.key" -out "$OUT/dev.crt" \
    -subj "/CN=seedsigner-os FIT signing/" >/dev/null 2>&1 \
  || { echo "make-dev-keys: could not create self-signed dev.crt" >&2; exit 1; }

echo "make-dev-keys: wrote dev.key, dev.pubkey, dev.crt to $OUT"
