#!/usr/bin/env bash
#
# prepare-app-checkout.sh <PARENT_DIR> <REF> [REPO_URL]
#
# Leave $PARENT_DIR/seedsigner checked out at exactly <REF>, whether or not a
# checkout is already sitting there. Shared by CI (build-luckfox.yml) and both
# local Docker builds (os-build.sh / build-local.sh) -- change this script,
# never one caller.
#
# WHY: the app is the one component this repo does not pin, and the local
# builds keep its checkout in storage that OUTLIVES the build -- the Docker
# volume 'seedsigner-repos' for os-build.sh, the worktree for build-local.sh.
# Both used to clone it only `if [ ! -d seedsigner ]`, so every build after the
# first silently reused whatever was cloned first: --seedsigner-ref was
# accepted, echoed back, and ignored. Asking for a release tag could quietly
# rebuild a months-old dev checkout -- and then assert-app-watchdog-signal.sh
# fails naming the ref you asked for, which does carry the signal. Matching by
# NAME is not enough either: a 'dev' checkout from three months ago is still
# called 'dev', so a branch ref has to be compared by commit as well.
#
# So <REF> is resolved to a commit AT THE REMOTE and compared against HEAD. On
# a mismatch the checkout is deleted and re-cloned: ~250 MB, only when the code
# actually differs, and it guarantees a pristine tree (submodules included)
# rather than a half-updated one. The luckfox-pico SDK sitting beside it in the
# same volume (37 GB) is never touched here.
#
# The app checkout is DISPOSABLE by design: the build mutates it in place
# (compile-translations.sh writes .mo files and slims fonts inside the
# translations submodule), so hand edits there do not survive a build anyway.
# To hold one in place regardless:
#   SEEDSIGNER_KEEP_APP_CHECKOUT=1  reuse whatever is there, warn, never delete.

set -eu

PARENT_DIR="${1:-}"
REF="${2:-}"
REPO_URL="${3:-${SEEDSIGNER_REPO_URL:-https://github.com/3rdIteration/seedsigner.git}}"

if [ -z "$PARENT_DIR" ] || [ -z "$REF" ]; then
    echo "usage: prepare-app-checkout.sh <PARENT_DIR> <REF> [REPO_URL]" >&2
    exit 1
fi

mkdir -p "$PARENT_DIR"
DIR="$PARENT_DIR/seedsigner"

# Describe a checkout in a way that works for a branch AND a tag: `rev-parse
# --abbrev-ref HEAD` returns the literal string "HEAD" on the detached checkout
# a tag clone produces.
checkout_desc() {
    local sha ref
    sha="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    ref="$(git -C "$DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [ -z "$ref" ]; then
        ref="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        [ "$ref" = "HEAD" ] && ref="detached"
    fi
    echo "ref=$ref commit=$sha"
}

# The commit <REF> names at the remote, or "" when the remote cannot resolve it
# (a raw commit, a typo, or no network). A branch wins over a same-named tag,
# matching `git clone -b`; an annotated tag resolves through its peeled ^{}
# line, which is the commit -- the tag object itself is not checkout-able.
remote_sha() {
    local out tags
    out="$(git ls-remote "$REPO_URL" "refs/heads/$REF" 2>/dev/null | head -1 | cut -f1)"
    if [ -z "$out" ]; then
        tags="$(git ls-remote "$REPO_URL" "refs/tags/$REF" 2>/dev/null || true)"
        out="$(printf '%s\n' "$tags" | grep '\^{}$' | head -1 | cut -f1 || true)"
        [ -z "$out" ] && out="$(printf '%s\n' "$tags" | head -1 | cut -f1 || true)"
    fi
    printf '%s' "$out"
}

remote_reachable() {
    git ls-remote --exit-code "$REPO_URL" HEAD >/dev/null 2>&1
}

looks_like_commit() {
    printf '%s' "$REF" | grep -Eq '^[0-9a-f]{7,40}$'
}

# Does the checkout correspond to <REF> by NAME? Only used when the remote is
# unreachable, where a name is the best evidence available.
checkout_name_matches() {
    local branch tag
    branch="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)"
    tag="$(git -C "$DIR" describe --tags --exact-match 2>/dev/null || true)"
    [ "$branch" = "$REF" ] && return 0
    [ -n "$tag" ] && [ "$tag" = "$REF" ] && return 0
    return 1
}

clone_fresh() {
    rm -rf "$DIR"
    if [ -n "$WANT" ]; then
        # `-b` takes a branch OR a tag, so a release tag needs no special
        # handling -- it just checks out detached at the tag.
        git clone "$REPO_URL" --depth=1 -b "$REF" --single-branch --recurse-submodules "$DIR"
    else
        # `git clone -b` does NOT accept a commit, so a commit ref needs the
        # default branch first and then a targeted fetch of that commit.
        git clone "$REPO_URL" --depth=1 --single-branch "$DIR"
        git -C "$DIR" fetch --depth=1 origin "$REF"
        git -C "$DIR" checkout --detach FETCH_HEAD
        git -C "$DIR" submodule update --init --recursive
    fi
    echo "✅ seedsigner cloned at '$REF' ($(checkout_desc))"
}

WANT="$(remote_sha)"

if [ ! -d "$DIR" ]; then
    if [ -z "$WANT" ] && ! looks_like_commit; then
        echo "prepare-app-checkout: '$REF' is not a branch, tag or commit at $REPO_URL" >&2
        echo "  check it exists: git ls-remote $REPO_URL '*$REF*'" >&2
        exit 1
    fi
    echo "Cloning seedsigner application code (ref: $REF)..."
    clone_fresh
    exit 0
fi

if [ "${SEEDSIGNER_KEEP_APP_CHECKOUT:-0}" = "1" ]; then
    echo "⚠️  SEEDSIGNER_KEEP_APP_CHECKOUT=1 — keeping $(checkout_desc) as-is;" >&2
    echo "⚠️  the requested ref '$REF' was NOT applied" >&2
    exit 0
fi

HAVE="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo none)"

if [ -n "$WANT" ]; then
    if [ "$HAVE" = "$WANT" ]; then
        echo "✅ seedsigner already at ref '$REF' ($(checkout_desc)) — reused"
        exit 0
    fi
    echo "↻ seedsigner checkout is $(checkout_desc), but ref '$REF' is ${WANT:0:7}"
    echo "↻ re-cloning (the app checkout is disposable; the luckfox-pico SDK is untouched)"
    clone_fresh
    exit 0
fi

# The remote could not resolve <REF>: a raw commit, a typo, or no network.
case "$HAVE" in
    "$REF"*)
        echo "✅ seedsigner already at commit $REF ($(checkout_desc)) — reused"
        exit 0
        ;;
esac

if ! remote_reachable; then
    # Offline: never delete a checkout that cannot be replaced.
    if checkout_name_matches; then
        echo "⚠️  cannot reach $REPO_URL — reusing $(checkout_desc), which matches '$REF' by name" >&2
        echo "⚠️  it may be behind the remote; this build is NOT pinned to what '$REF' means today" >&2
        exit 0
    fi
    echo "prepare-app-checkout: cannot reach $REPO_URL, and the existing checkout" >&2
    echo "  ($(checkout_desc)) is not '$REF' — refusing to build the wrong app ref." >&2
    exit 1
fi

if looks_like_commit; then
    echo "↻ seedsigner checkout is $(checkout_desc), commit '$REF' requested — re-cloning"
    clone_fresh
    exit 0
fi

echo "prepare-app-checkout: '$REF' is not a branch, tag or commit at $REPO_URL" >&2
echo "  the existing checkout ($(checkout_desc)) was left alone." >&2
echo "  check the ref exists: git ls-remote $REPO_URL '*$REF*'" >&2
exit 1
