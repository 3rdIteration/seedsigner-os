#!/usr/bin/env bash
#
# sign-secure-boot.sh — sign Luckfox Pico (RV1106/RV1103) boot images for
# Rockchip secure boot, verify the result offline, and show the OTP hash a burn
# would write.
#
# THIS IS A BENCH TOOL, NOT PART OF THE IMAGE BUILD. It is never called by
# os-build.sh / build-local.sh / CI. Nothing in a normal SeedSigner build is
# signed. See docs/luckfox/secure-boot-bench-procedure.md for the full process
# and docs/luckfox/secure-boot.md for the rationale and the consequences.
#
# It does NOT flash and it does NOT burn a fuse. Signing and verifying are fully
# reversible; the only irreversible step (the OTP burn) happens later, on-device,
# when a loader signed with --burn is booted. See the warnings under --burn.
#
# Every rk_sign_tool / fit-sign.sh invocation here was validated against a real
# Luckfox_Pico_Mini_Flash image; the command transcripts are in the bench doc.
#
# Usage:
#   sign-secure-boot.sh gen-key   --keys <dir> [--bits 2048|4096]
#   sign-secure-boot.sh sign      --keys <dir> --images <dir> [--build-tree <dir>] [--burn]
#   sign-secure-boot.sh verify    --keys <dir> --images <dir>
#   sign-secure-boot.sh otp-hash  --keys <dir> --images <dir>
#
#   --tools <dir>   rkbin tools dir (has rk_sign_tool + fit-sign.sh).
#                   Default: the SDK copy if $LUCKFOX_SDK_DIR is set, else a
#                   sibling ./rkbin/tools, else error.
#   --chip <id>     Default 1106. The Mini (RV1103) signs as 1106 too — plain
#                   "1103" is rejected by the tool's support list.
#   --bits <n>      Key size for gen-key. Default 2048 (matches the shipped
#                   sha256,rsa2048 FITs and the documented BootROM size). 4096
#                   signs and verifies through the tool, but whether the RV1106
#                   BootROM accepts it for the loader is unverified in silicon —
#                   test on a sacrificial board before trusting it.
#   --build-tree <dir>  A built SDK image dir (with the SPL DTB + fit_signcfg).
#                   When given, the whole chain (loader+idblock+uboot+boot) is
#                   signed via fit-sign.sh. Without it, only the loader and
#                   idblock in --images are signed (all a prebuilt flash folder
#                   allows), which is enough for BootROM-level secure boot but
#                   leaves uboot.img/boot.img unverified.
#
set -euo pipefail

log()  { printf '  [sign] %s\n' "$*"; }
warn() { printf '  [sign] !! %s\n' "$*" >&2; }
die()  { printf '  [sign] ERROR: %s\n' "$*" >&2; exit 1; }

CMD="${1:-}"; shift || true
KEYS=""; IMAGES=""; TOOLS=""; CHIP="1106"; BITS="2048"; BUILD_TREE=""; BURN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keys)       KEYS="$2"; shift 2;;
    --images)     IMAGES="$2"; shift 2;;
    --tools)      TOOLS="$2"; shift 2;;
    --chip)       CHIP="$2"; shift 2;;
    --bits)       BITS="$2"; shift 2;;
    --build-tree) BUILD_TREE="$2"; shift 2;;
    --burn)       BURN=1; shift;;
    *) die "unknown argument: $1";;
  esac
done

# --- locate the rkbin tools -------------------------------------------------
resolve_tools() {
  [ -n "$TOOLS" ] && { echo "$TOOLS"; return; }
  if [ -n "${LUCKFOX_SDK_DIR:-}" ] && [ -x "$LUCKFOX_SDK_DIR/sysdrv/source/uboot/rkbin/tools/rk_sign_tool" ]; then
    echo "$LUCKFOX_SDK_DIR/sysdrv/source/uboot/rkbin/tools"; return
  fi
  for c in ./rkbin/tools ../rkbin/tools "$HOME/rkbin/tools"; do
    [ -x "$c/rk_sign_tool" ] && { echo "$c"; return; }
  done
  die "cannot find rk_sign_tool. Pass --tools <rkbin/tools dir> (from https://github.com/3rdIteration/rkbin)."
}

need_dir()  { [ -d "$1" ] || die "$2 not found: $1"; }
need_file() { [ -f "$1" ] || die "$2 not found: $1"; }

# --- pick the loader/idblock in an image dir --------------------------------
# The loader is download.bin / MiniLoaderAll.bin / *loader*.bin; idblock is
# idblock*.img. Match fit-sign.sh's own glob (see rkbin/tools/fit-sign.sh).
# Iterate candidates with [ -f ] rather than ls, so a missing candidate does not
# return non-zero and trip `set -e`/`pipefail`.
find_loader()  { local f; for f in "$1"/download.bin "$1"/MiniLoaderAll.bin "$1"/*loader*.bin; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 0; }
find_idblock() { local f; for f in "$1"/idblock*.img; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 0; }

cmd_gen_key() {
  need_dir "$KEYS" "keys dir (create it first: mkdir -p)"
  local T; T="$(resolve_tools)"
  if [ -f "$KEYS/private_key.pem" ]; then
    warn "key already exists at $KEYS/private_key.pem — refusing to overwrite."
    warn "delete it yourself if you really mean to regenerate (this orphans every device signed with it)."
    exit 1
  fi
  log "generating RSA-$BITS keypair in $KEYS (chip $CHIP)"
  ( cd "$KEYS" && "$T/rk_sign_tool" kk --bits "$BITS" --out . >/dev/null 2>&1 )
  need_file "$KEYS/private_key.pem" "generated private key"
  need_file "$KEYS/public_key.pem"  "generated public key"
  log "done. BACK UP $KEYS OFFLINE NOW — losing it makes every fused device un-updatable."
}

load_key() {
  local T="$1"
  need_file "$KEYS/private_key.pem" "private key (run gen-key first)"
  "$T/rk_sign_tool" cc --chip "$CHIP" >/dev/null
  "$T/rk_sign_tool" lk --key "$KEYS/private_key.pem" --pubkey "$KEYS/public_key.pem" >/dev/null
}

cmd_sign() {
  need_dir "$IMAGES" "images dir"
  local T; T="$(resolve_tools)"
  load_key "$T"

  if [ -n "$BUILD_TREE" ]; then
    need_dir "$BUILD_TREE" "build tree"
    log "full-chain signing via fit-sign.sh (loader + idblock + uboot + boot)"
    local burnflag=""
    if [ "$BURN" = 1 ]; then confirm_burn; burnflag="--burn-key-hash"; fi
    "$T/fit-sign.sh" --key-dir "$KEYS" --src-dir "$BUILD_TREE" --out-dir "$IMAGES/signed" $burnflag
    log "signed images in: $IMAGES/signed"
    return
  fi

  # Prebuilt-folder path: loader + idblock only.
  local loader idb; loader="$(find_loader "$IMAGES")"; idb="$(find_idblock "$IMAGES")"
  [ -n "$loader" ] || die "no loader (download.bin / *loader*.bin) in $IMAGES"
  [ -n "$idb" ]    || die "no idblock*.img in $IMAGES"
  log "prebuilt-folder path: signing loader + idblock only (uboot.img/boot.img cannot be signed here)"

  if [ "$BURN" = 1 ]; then
    confirm_burn
    warn "loader-path burn uses 'ss --flag 0x20'. 0x20 is documented for RK3308/PX30, NOT RV1106."
    warn "prefer the --build-tree path (fit-sign.sh --burn-key-hash). Proceeding only because you asked."
    "$T/rk_sign_tool" ss --flag 0x20 >/dev/null
  fi

  cp -f "$loader" "$IMAGES/download.signed.bin"
  cp -f "$idb"    "$IMAGES/idblock.signed.img"
  log "signing loader ($(basename "$loader"))"
  "$T/rk_sign_tool" sl --loader "$IMAGES/download.signed.bin" >/dev/null
  log "signing idblock ($(basename "$idb"))"
  "$T/rk_sign_tool" sb --idb "$IMAGES/idblock.signed.img" >/dev/null

  IMAGES="$IMAGES" KEYS="$KEYS" TOOLS="$T" verify_prebuilt
  otp_hash "$T" "$IMAGES/download.signed.bin"
  log "signed: $IMAGES/download.signed.bin, $IMAGES/idblock.signed.img"
  print_flash_hint
}

verify_prebuilt() {
  local T="${TOOLS:-$(resolve_tools)}"
  "$T/rk_sign_tool" cc --chip "$CHIP" >/dev/null
  local ok=1
  if [ -f "$IMAGES/download.signed.bin" ]; then
    "$T/rk_sign_tool" vl --loader "$IMAGES/download.signed.bin" >/dev/null 2>&1 \
      && log "verify loader: OK" || { warn "verify loader: FAILED"; ok=0; }
  fi
  if [ -f "$IMAGES/idblock.signed.img" ]; then
    "$T/rk_sign_tool" vb --idb "$IMAGES/idblock.signed.img" >/dev/null 2>&1 \
      && log "verify idblock: OK" || { warn "verify idblock: FAILED"; ok=0; }
  fi
  [ "$ok" = 1 ] || die "offline verification failed — do NOT flash these."
}

cmd_verify() {
  need_dir "$IMAGES" "images dir"
  need_file "$KEYS/public_key.pem" "public key"
  verify_prebuilt
}

otp_hash() {
  local T="$1" loader="$2"
  "$T/rk_sign_tool" otp --loader "$loader" --hash "$IMAGES/otp_hash.bin" >/dev/null 2>&1 || {
    warn "otp hash extraction failed"; return; }
  log "OTP hash a burn WOULD write (record this — it cannot be read back after fusing):"
  od -An -tx1 "$IMAGES/otp_hash.bin" | tr -s ' ' | sed 's/^ /    /'
}

cmd_otp_hash() {
  need_dir "$IMAGES" "images dir"
  local T; T="$(resolve_tools)"; load_key "$T"
  local loader=""; for f in "$IMAGES"/download.signed.bin "$IMAGES"/download.bin; do [ -f "$f" ] && { loader="$f"; break; }; done
  [ -n "$loader" ] || die "no loader in $IMAGES"
  otp_hash "$T" "$loader"
}

confirm_burn() {
  warn "================= IRREVERSIBLE ================="
  warn "--burn arms the OTP key-hash write. A board booted with the resulting loader"
  warn "burns a one-time fuse and will thereafter ONLY boot signed firmware. There is"
  warn "no undo. Losing the key orphans the device. Test recovery (BOOT->Maskrom) on a"
  warn "sacrificial board FIRST — see docs/luckfox/secure-boot-bench-procedure.md."
  warn "==============================================="
  [ "${SEEDSIGNER_SB_CONFIRM:-}" = "I-UNDERSTAND-THIS-BURNS-A-FUSE" ] || \
    die "refusing to arm a burn without SEEDSIGNER_SB_CONFIRM=I-UNDERSTAND-THIS-BURNS-A-FUSE"
}

print_flash_hint() {
  cat <<'HINT'
  [sign] next: flash over USB (board in Maskrom: hold BOOT while connecting), e.g.
  [sign]   rkdeveloptool ld                       # confirm Maskrom/Loader
  [sign]   rkdeveloptool db  download.signed.bin  # load signed loader to RAM
  [sign]   rkdeveloptool ul  download.signed.bin  # upgrade loader
  [sign] then write idblock.signed.img (+ uboot/boot) with your usual flash tool,
  [sign] and watch UART @115200. See the bench procedure doc for the full sequence.
HINT
}

case "$CMD" in
  gen-key)  cmd_gen_key;;
  sign)     cmd_sign;;
  verify)   cmd_verify;;
  otp-hash) cmd_otp_hash;;
  ""|-h|--help|help)
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $CMD (try: gen-key | sign | verify | otp-hash)";;
esac
