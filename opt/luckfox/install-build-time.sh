#!/usr/bin/env bash
#
# install-build-time.sh <ROOTFS_DIR> <APP_GIT_DIR>
#
# Bake /etc/seedsigner-build-time, the default the boot clock is set from.
# Shared by the GitHub Actions build and both local Docker builds (os-build.sh /
# build-local.sh) -- change this script, never one caller.
#
# WHY ANY OF THIS EXISTS: the RV1106 has no battery-backed RTC, these images
# carry no NTP and no network, and nothing in the Luckfox tree ever set the
# clock. The device therefore came up at whatever the SoC left in its timer --
# in practice a date well in the future -- and the SeedSigner app validates a
# new GPG key's expiry against datetime.now(timezone.utc):
#
#     created = datetime.now(timezone.utc)
#     ...                       # default expiry 2029-12-31 (RSA-2048) / 2035-12-31
#     if expiration_dt <= created:
#         raise ValueError      # -> "Invalid expiration date"
#
# so key generation failed at the prompt, before it could `gpg --batch --import`
# anything. The Raspberry Pi and La Frite images have always avoided this: see
# the "Set the date to release so that GPG can work" block in
# opt/rootfs-overlay/start.sh, fed by /opt/src/.build_commit_time from
# opt/build.sh. This is the Luckfox equivalent; /start-seedsigner.sh reads the
# file at boot (init_system_clock).
#
# It also matters beyond the prompt: a key's creation time is an input to its
# fingerprint, so a key generated under a wrong clock is permanently wrong and
# cannot be corrected afterwards.
#
# REPRODUCIBILITY: the value is the committer date of the PINNED APP COMMIT --
# `git log -1 --format=%ct`, exactly the expression opt/build.sh uses for the Pi
# -- never a build wall clock. Same OS commit + same --seedsigner-ref => same
# byte. Do NOT "improve" this by sourcing SOURCE_DATE_EPOCH: it is 0
# (os-build.sh), which would ship a device whose clock reads 1970. That failure
# is invisible -- 1970 passes the app's expiry check -- while stamping every
# generated key with a 1970 creation date. The year floor below exists to catch
# exactly that edit.
#
# Format is plain `YYYY-MM-DD HH:MM` UTC rather than the ISO-8601 %cI already in
# /etc/seedsigner-os-release, because the target runs busybox date, which cannot
# parse ISO-8601 with a T and a UTC offset -- and %cI carries the committer's
# local offset, which varies per commit, so converting it correctly would mean
# offset arithmetic in busybox sh inside the one boot path that has to be
# unfailingly boring.

set -eu

ROOTFS="${1:-}"
APP_GIT_DIR="${2:-}"

if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "install-build-time: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi

DEST="$ROOTFS/etc/seedsigner-build-time"
MIN_YEAR=2020

log() { echo "  [build-time] $*"; }

echo "=== Baking build time ==="

VALUE=""
SOURCE=""

# 1. Explicit pin. The escape hatch for a bisect or a deliberate rebuild.
if [ -n "${SEEDSIGNER_BUILD_TIME:-}" ]; then
    VALUE="$SEEDSIGNER_BUILD_TIME"
    SOURCE="SEEDSIGNER_BUILD_TIME"
fi

# 2. The pinned app commit -- the normal path, and the reproducible one.
if [ -z "$VALUE" ] && [ -n "$APP_GIT_DIR" ] && [ -d "$APP_GIT_DIR" ]; then
    epoch="$(git -C "$APP_GIT_DIR" log -1 --format=%ct 2>/dev/null || true)"
    if [ -n "$epoch" ]; then
        VALUE="$(date -u -d "@${epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
        SOURCE="app commit $(git -C "$APP_GIT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    fi
fi

# 3. The date the provenance marker recorded, for a checkout whose .git is gone.
if [ -z "$VALUE" ] && [ -n "${SEEDSIGNER_APP_DATE:-}" ] && [ "${SEEDSIGNER_APP_DATE}" != "unknown" ]; then
    VALUE="$(date -u -d "$SEEDSIGNER_APP_DATE" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
    SOURCE="SEEDSIGNER_APP_DATE"
fi

if [ -z "$VALUE" ]; then
    echo "install-build-time: ERROR -- could not resolve a build time" >&2
    echo "  tried: \$SEEDSIGNER_BUILD_TIME, git log in '${APP_GIT_DIR:-<empty>}', \$SEEDSIGNER_APP_DATE" >&2
    exit 1
fi

# Shape check. A glob rather than a regex so this needs nothing but the shell.
case "$VALUE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]) ;;
    *)
        echo "install-build-time: ERROR -- '$VALUE' (from $SOURCE) is not 'YYYY-MM-DD HH:MM'" >&2
        exit 1
        ;;
esac

# Year floor. See the SOURCE_DATE_EPOCH warning in the header: this is the guard
# against silently shipping a 1970 clock, which nothing downstream would report.
YEAR="${VALUE%%-*}"
if [ "$YEAR" -lt "$MIN_YEAR" ]; then
    echo "install-build-time: ERROR -- '$VALUE' (from $SOURCE) predates $MIN_YEAR" >&2
    echo "  a pre-$MIN_YEAR clock stamps every generated GPG key with a bogus creation" >&2
    echo "  date and is not reported anywhere at runtime. Refusing to bake it." >&2
    exit 1
fi

mkdir -p "$ROOTFS/etc"
printf '%s\n' "$VALUE" > "$DEST"
chmod 0644 "$DEST"

# Assert rather than warn. A silent miss ships a device that falls back to the
# hard-coded constant in /start-seedsigner.sh with no build-time signal.
[ -s "$DEST" ] || {
    echo "install-build-time: ERROR -- $DEST was not written" >&2
    exit 1
}

log "baked /etc/seedsigner-build-time = '$VALUE' UTC (source: $SOURCE)"
echo "=== Build time baked ==="
