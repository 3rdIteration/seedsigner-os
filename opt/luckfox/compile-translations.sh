#!/usr/bin/env bash
#
# compile-translations.sh — compile SeedSigner translation catalogs (.po -> .mo)
# inside a seedsigner source checkout, so the Luckfox image ships working
# multi-language support.
#
#   usage: compile-translations.sh <seedsigner_checkout_dir>
#
# This mirrors the Raspberry Pi build's compile_translations_and_fonts() in
# opt/build.sh. It MUST run against the source checkout BEFORE that checkout is
# copied into the rootfs and BEFORE the top-level l10n/ overlay is pruned: the
# fork's `setup.py compile_catalog` override merges the fork overlay catalogs
# (l10n/fork/<locale>/messages.po) into the upstream seedsigner-translations
# submodule catalogs before writing each .mo. Plain `pybabel compile` would drop
# the fork-added strings, so we deliberately use `setup.py compile_catalog`.
#
# It also slims the bundled CJK / complex-script NotoSans fonts down to just the
# glyphs used by the translations (optional; keeps the SPI-NAND rootfs small).
#
# The script degrades gracefully: if python3 / venv / pip or the translation
# catalog is unavailable it prints a warning and exits 0 rather than failing the
# build (the image is then simply English-only). This lets it be called from the
# SDK-container build paths (os-build.sh / build-local.sh) where the toolchain
# may be minimal, while the GitHub Actions runner (build-luckfox.yml) always has
# a full python3.

set -u

SS_DIR="${1:-}"
if [ -z "$SS_DIR" ]; then
  echo "compile-translations: usage: compile-translations.sh <seedsigner_checkout_dir>" >&2
  exit 0
fi

TRANSLATIONS_REL="src/seedsigner/resources/seedsigner-translations"

if [ ! -d "$SS_DIR/$TRANSLATIONS_REL/l10n" ]; then
  echo "compile-translations: no catalog at $SS_DIR/$TRANSLATIONS_REL/l10n — skipping i18n compile (English-only)"
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "compile-translations: python3 not found — skipping i18n compile (English-only)" >&2
  exit 0
fi

if ! cd "$SS_DIR"; then
  echo "compile-translations: cannot cd to $SS_DIR — skipping" >&2
  exit 0
fi

# Isolated venv, created OUTSIDE the checkout so it is never copied into the
# rootfs, and removed on exit. (The only changes we want left in the checkout
# are the compiled .mo files and the slimmed fonts.)
VENV_PARENT="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ss-l10n-venv.$$")"
mkdir -p "$VENV_PARENT" 2>/dev/null || true
VENV="$VENV_PARENT/venv"
trap 'rm -rf "$VENV_PARENT" 2>/dev/null || true' EXIT
if ! python3 -m venv "$VENV" 2>/dev/null; then
  if command -v virtualenv >/dev/null 2>&1 && virtualenv "$VENV" >/dev/null 2>&1; then
    :
  else
    echo "compile-translations: python venv/virtualenv unavailable — skipping i18n compile (English-only)" >&2
    exit 0
  fi
fi
# shellcheck disable=SC1091
. "$VENV/bin/activate"

python3 -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true

# Babel (+ setuptools) drives `setup.py compile_catalog`.
if [ -f l10n/requirements-l10n.txt ]; then
  pip_target="-r l10n/requirements-l10n.txt"
else
  pip_target="Babel==2.16.0 setuptools>=82.0.0"
fi
# shellcheck disable=SC2086
if ! python3 -m pip install --quiet $pip_target; then
  echo "compile-translations: could not install Babel — skipping i18n compile (English-only)" >&2
  deactivate 2>/dev/null || true
  exit 0
fi
# fonttools (pyftsubset) is only needed for the optional font-slimming step.
python3 -m pip install --quiet fonttools >/dev/null 2>&1 || true

# Drop any stale .mo then compile (applies the fork overlay merge).
rm -f "$TRANSLATIONS_REL"/l10n/*/LC_MESSAGES/*.mo 2>/dev/null || true
if ! python3 setup.py compile_catalog; then
  echo "compile-translations: 'setup.py compile_catalog' failed — image will be English-only" >&2
  deactivate 2>/dev/null || true
  exit 0
fi

# --- Optional: slim bundled fonts to only the glyphs the translations use ------
extract_tool="$TRANSLATIONS_REL/tools/extract_characters_from_babel_mo.py"
if [ -d "$TRANSLATIONS_REL/fonts" ] && [ -f "$extract_tool" ] && command -v pyftsubset >/dev/null 2>&1; then
  all_chars=""
  for f in "$TRANSLATIONS_REL"/l10n/*/LC_MESSAGES/messages.mo; do
    [ -f "$f" ] || continue
    locale=$(basename "$(dirname "$(dirname "$f")")")
    chars=$(cd "$TRANSLATIONS_REL/tools" && python3 extract_characters_from_babel_mo.py "$locale" 2>/dev/null) \
      || echo "compile-translations: char extraction failed for locale $locale" >&2
    all_chars="${all_chars}${chars}"
  done
  all_chars="${all_chars}\n\r"
  for font in NotoSansAR NotoSansJP NotoSansKR NotoSansSC NotoSansTH; do
    src="$TRANSLATIONS_REL/fonts/${font}-Regular.ttf"
    [ -f "$src" ] || continue
    orig="$TRANSLATIONS_REL/fonts/${font}-Regular-Original.ttf"
    mv "$src" "$orig" || continue
    if ! pyftsubset "$orig" --text="$all_chars" --output-file="$src"; then
      echo "compile-translations: font subset failed for $font — restoring full font" >&2
      mv "$orig" "$src" 2>/dev/null || true
    fi
  done
  rm -f "$TRANSLATIONS_REL"/fonts/NotoSans*Regular-Original*.ttf
else
  echo "compile-translations: font-slim tooling or fonts absent — keeping full fonts"
fi

deactivate 2>/dev/null || true
mo_count=$(ls "$TRANSLATIONS_REL"/l10n/*/LC_MESSAGES/messages.mo 2>/dev/null | wc -l)
echo "compile-translations: done — ${mo_count} locale catalog(s) compiled"
exit 0
