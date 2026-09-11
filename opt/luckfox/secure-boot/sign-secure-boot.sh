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
#   sign-secure-boot.sh gen-key   --keys <dir> [--bits 2048|4096] [--from <pem>]
#   sign-secure-boot.sh sign      --keys <dir> --images <dir> [--build-tree <dir>] [--burn]
#   sign-secure-boot.sh verify    --keys <dir> --images <dir>
#   sign-secure-boot.sh otp-hash  --keys <dir> --images <dir>
#
#   gen-key writes ONE keys dir that both signing paths accept:
#     * dev.key / dev.pubkey / dev.crt  — the triple Rockchip's mkimage FIT
#       signing needs (the --build-tree path, via fit-sign.sh, and the in-SDK
#       build). Produced by the shared make-dev-keys.sh.
#     * private_key.pem / public_key.pem — copies rk_sign_tool reads for the
#       prebuilt loader+idblock path.
#   --from <pem> derives the key from an existing RSA private key PEM instead of
#   generating one — e.g. a BIP85-derived key exported from a SeedSigner
#   (key.export_key('PEM')), so the signing key is reproducible from the seed.
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
KEYS=""; IMAGES=""; TOOLS=""; CHIP="1106"; BITS="2048"; BUILD_TREE=""; BURN=0; FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keys)       KEYS="$2"; shift 2;;
    --images)     IMAGES="$2"; shift 2;;
    --tools)      TOOLS="$2"; shift 2;;
    --chip)       CHIP="$2"; shift 2;;
    --bits)       BITS="$2"; shift 2;;
    --from)       FROM="$2"; shift 2;;
    --build-tree) BUILD_TREE="$2"; shift 2;;
    --burn)       BURN=1; shift;;
    *) die "unknown argument: $1";;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- locate the rkbin tools -------------------------------------------------
# Always returns a dir that actually contains an executable rk_sign_tool, or
# dies with a clear message. When --tools is given we also accept an rkbin ROOT
# (we try <dir> and <dir>/tools), so both --tools .../rkbin and
# --tools .../rkbin/tools work.
resolve_tools() {
  local cands=()
  if [ -n "$TOOLS" ]; then
    cands=( "$TOOLS" "$TOOLS/tools" )
  else
    [ -n "${LUCKFOX_SDK_DIR:-}" ] && cands+=( "$LUCKFOX_SDK_DIR/sysdrv/source/uboot/rkbin/tools" )
    cands+=( ./rkbin/tools ../rkbin/tools "$HOME/rkbin/tools" "$HOME/tmp/rkbin/tools" )
  fi
  local c
  for c in "${cands[@]}"; do
    [ -x "$c/rk_sign_tool" ] && { echo "$c"; return; }
  done
  if [ -n "$TOOLS" ]; then
    die "no executable rk_sign_tool under --tools '$TOOLS' (looked in '$TOOLS' and '$TOOLS/tools'). Clone https://github.com/3rdIteration/rkbin and point --tools at its tools/ dir."
  fi
  die "cannot find rk_sign_tool. Pass --tools <rkbin/tools dir> (clone https://github.com/3rdIteration/rkbin)."
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
  [ -n "$KEYS" ] || die "--keys <dir> is required"
  local mk="$SCRIPT_DIR/make-dev-keys.sh"
  [ -f "$mk" ] || die "shared key helper not found: $mk"
  mkdir -p "$KEYS" || die "could not create keys dir: $KEYS"
  if [ -f "$KEYS/dev.key" ] || [ -f "$KEYS/private_key.pem" ]; then
    warn "key already exists in $KEYS — refusing to overwrite."
    warn "delete it yourself if you really mean to regenerate (this orphans every device signed with it)."
    exit 1
  fi
  # make-dev-keys.sh produces the dev.{key,pubkey,crt} triple both the mkimage
  # FIT path (fit-sign.sh / in-SDK build) and rk_sign_tool understand. --from
  # wraps an existing RSA PEM (e.g. a BIP85-derived key); otherwise generate one.
  if [ -n "$FROM" ]; then
    [ -f "$FROM" ] || die "--from key not found: $FROM"
    log "deriving signing key in $KEYS from $FROM"
    bash "$mk" --out "$KEYS" --from "$FROM" || die "make-dev-keys.sh --from failed"
  else
    log "generating RSA-$BITS signing key in $KEYS"
    bash "$mk" --out "$KEYS" --bits "$BITS" || die "make-dev-keys.sh failed"
  fi
  # rk_sign_tool (prebuilt loader+idblock path) reads private_key.pem/public_key.pem;
  # they are the same key material as dev.key/dev.pubkey.
  cp -f "$KEYS/dev.key"    "$KEYS/private_key.pem"
  cp -f "$KEYS/dev.pubkey" "$KEYS/public_key.pem"
  log "done: $KEYS/{dev.key,dev.pubkey,dev.crt} (+ private_key.pem/public_key.pem)"
  log "BACK UP $KEYS OFFLINE NOW — losing it makes every fused device un-updatable."
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

  if [ -n "$BUILD_TREE" ]; then
    need_dir "$BUILD_TREE" "build tree"
    # fit-sign.sh does its own rk_sign_tool cc/lk from the dev.* triple, so the
    # build-tree path needs dev.{key,pubkey,crt}, NOT private_key.pem.
    local k
    for k in dev.key dev.pubkey dev.crt; do
      need_file "$KEYS/$k" "signing key '$k' (run gen-key, or secure-boot/make-dev-keys.sh)"
    done
    log "full-chain signing via fit-sign.sh (loader + idblock + uboot + boot)"
    local burnflag=""
    if [ "$BURN" = 1 ]; then confirm_burn; burnflag="--burn-key-hash"; fi
    "$T/fit-sign.sh" --key-dir "$KEYS" --src-dir "$BUILD_TREE" --out-dir "$IMAGES/signed" $burnflag
    log "signed images in: $IMAGES/signed"
    return
  fi

  # Prebuilt-folder path: loader + idblock only.
  load_key "$T"
  local loader idb; loader="$(find_loader "$IMAGES")"; idb="$(find_idblock "$IMAGES")"
  [ -n "$loader" ] || die "no loader (download.bin / *loader*.bin) in $IMAGES"
  [ -n "$idb" ]    || die "no idblock*.img in $IMAGES"
  log "prebuilt-folder path: signing loader + idblock only (uboot.img/boot.img cannot be signed here)"

  if [ "$BURN" = 1 ]; then
    warn "--burn on the prebuilt-folder path does NOT work on RV1106."
    warn "It set 'ss --flag 0x20' (the RK3308/PX30 mechanism); bench-tested on a"
    warn "flashed RV1103 Mini, no OTP write occurred: no 'otp write key success',"
    warn "Verified-boot stayed 0, board unfused. RV1106 burns the key hash via the"
    warn "FIT mechanism instead (fit-sign.sh --burn-key-hash), which needs a real"
    warn "U-Boot build tree. Re-run with --build-tree <sdk-image-dir> --burn."
    die "prebuilt-folder --burn is a no-op on RV1106; use the --build-tree path"
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

# SHA-256 of the committed PUBLIC dev key's RSA modulus (secure-boot/dev-keys/).
# A burn armed with this key fuses the board to a key everyone has: recoverable
# (still updatable) but with zero secure-boot protection.
PUBLIC_DEV_KEY_MODULUS_SHA256="c8b597b50bbb94c7c700011c2aefc43eb97d3b391da28bc130936d8d9f530f17"

warn_if_public_dev_key() {
  command -v openssl >/dev/null 2>&1 || return 0
  local kf=""
  for f in "$KEYS/dev.key" "$KEYS/private_key.pem"; do [ -f "$f" ] && { kf="$f"; break; }; done
  [ -n "$kf" ] || return 0
  local mod; mod="$(openssl rsa -in "$kf" -noout -modulus 2>/dev/null | sha256sum | awk '{print $1}')"
  if [ "$mod" = "$PUBLIC_DEV_KEY_MODULUS_SHA256" ]; then
    warn "########################################################################"
    warn "## THIS IS THE COMMITTED PUBLIC DEV KEY — NOT A SECRET.                ##"
    warn "## Burning it gives the board NO protection (anyone can sign for it).  ##"
    warn "## The fuse is still one-time: this board can NEVER later move to a    ##"
    warn "## real secret key. Only do this on a sacrificial board, as a test of  ##"
    warn "## the burn mechanism itself. For real secure boot, re-sign with your  ##"
    warn "## own key first (Stage 2) and burn THAT.                              ##"
    warn "########################################################################"
  fi
}

confirm_burn() {
  warn_if_public_dev_key
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
