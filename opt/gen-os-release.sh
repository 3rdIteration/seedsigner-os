#!/bin/bash
#
# Generate the SeedSigner OS identity + build-provenance marker.
#
# Emits an os-release-style KEY=VALUE file that (a) positively identifies a
# SeedSigner OS (Buildroot) image to the app, and (b) records build provenance
# (repo / branch / commit / date) for both seedsigner-os and the seedsigner app.
#
# Usage:
#   gen-os-release.sh <output-file>
#
# Inputs (all optional; anything unresolved is written as "unknown"):
#   Explicit values via environment variables:
#     SEEDSIGNER_OS_REPO   SEEDSIGNER_OS_BRANCH   SEEDSIGNER_OS_COMMIT   SEEDSIGNER_OS_DATE
#     SEEDSIGNER_APP_REPO  SEEDSIGNER_APP_BRANCH  SEEDSIGNER_APP_COMMIT  SEEDSIGNER_APP_DATE
#   Or point these at local git checkouts to derive commit/date/branch:
#     SEEDSIGNER_OS_GIT_DIR   SEEDSIGNER_APP_GIT_DIR

set -u

OUT="${1:?usage: gen-os-release.sh <output-file>}"

git_log_field() {  # <git-dir> <format>
    [ -n "$1" ] || return 1
    git -C "$1" log -1 --format="$2" 2>/dev/null
}

git_branch() {  # <git-dir>
    [ -n "$1" ] || return 1
    local b
    b="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    # Detached HEAD (e.g. a commit-id checkout) is not a useful branch name.
    [ "$b" = "HEAD" ] && return 1
    printf '%s' "$b"
}

resolve() {  # <explicit-value> <git-dir> <kind: commit|date|branch>
    if [ -n "$1" ]; then printf '%s' "$1"; return; fi
    case "$3" in
        commit) git_log_field "$2" '%H' ;;
        date)   git_log_field "$2" '%cI' ;;
        branch) git_branch "$2" ;;
    esac
}

field() { printf '%s' "${1:-unknown}"; }

OS_REPO="${SEEDSIGNER_OS_REPO:-}"
OS_BRANCH="$(resolve "${SEEDSIGNER_OS_BRANCH:-}" "${SEEDSIGNER_OS_GIT_DIR:-}" branch)"
OS_COMMIT="$(resolve "${SEEDSIGNER_OS_COMMIT:-}" "${SEEDSIGNER_OS_GIT_DIR:-}" commit)"
OS_DATE="$(resolve "${SEEDSIGNER_OS_DATE:-}" "${SEEDSIGNER_OS_GIT_DIR:-}" date)"

APP_REPO="${SEEDSIGNER_APP_REPO:-}"
APP_BRANCH="$(resolve "${SEEDSIGNER_APP_BRANCH:-}" "${SEEDSIGNER_APP_GIT_DIR:-}" branch)"
APP_COMMIT="$(resolve "${SEEDSIGNER_APP_COMMIT:-}" "${SEEDSIGNER_APP_GIT_DIR:-}" commit)"
APP_DATE="$(resolve "${SEEDSIGNER_APP_DATE:-}" "${SEEDSIGNER_APP_GIT_DIR:-}" date)"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
NAME="SeedSigner OS"
ID=seedsigner-os
SEEDSIGNER_OS_REPO=$(field "$OS_REPO")
SEEDSIGNER_OS_BRANCH=$(field "$OS_BRANCH")
SEEDSIGNER_OS_COMMIT=$(field "$OS_COMMIT")
SEEDSIGNER_OS_DATE=$(field "$OS_DATE")
SEEDSIGNER_APP_REPO=$(field "$APP_REPO")
SEEDSIGNER_APP_BRANCH=$(field "$APP_BRANCH")
SEEDSIGNER_APP_COMMIT=$(field "$APP_COMMIT")
SEEDSIGNER_APP_DATE=$(field "$APP_DATE")
EOF

echo "Generated $OUT:"
cat "$OUT"
