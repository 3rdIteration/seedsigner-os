#!/usr/bin/env bash
#
# install-gnupg-home.sh <ROOTFS_DIR>
#
# Stage the GnuPG agent/scdaemon configuration that /start-seedsigner.sh seeds
# into the runtime GNUPGHOME. Shared by the GitHub Actions build and both local
# Docker builds (os-build.sh / build-local.sh) — change this script, never one
# caller.
#
# WHY ANY OF THIS EXISTS: the SeedSigner app never sets GNUPGHOME and never
# passes `gpg --homedir`, so gpg resolves its home from $HOME — which under
# BusyBox init is "/", i.e. /.gnupg on the read-only squashfs root. S01overlay
# deliberately does not overlay "/", so every write gpg needs (pubring.kbx,
# private-keys-v1.d/, trustdb.gpg, random_seed, lock files, and the S.gpg-agent
# / S.scdaemon sockets — there is no /run/user/0 here) fails with "read-only
# file system". That is what broke GPG key generation and key import on the Pro
# Max and Pico Pi. start-seedsigner.sh points GNUPGHOME at /tmp/.gnupg instead;
# this script provides the config it seeds there.
#
# The Pi/La Frite images get the equivalent files from
# opt/rootfs-overlay/root/.gnupg/ via BR2_ROOTFS_OVERLAY. The Luckfox defconfigs
# set BR2_ROOTFS_OVERLAY="" and opt/luckfox/Dockerfile copies only configs/,
# files/, scripts/ and *.sh, so opt/rootfs-overlay/ is not reachable from the
# Luckfox Docker build context and the files are duplicated under files/gnupg/.
#
# The config is staged into /usr/share (never overlaid, never pruned by
# harden-nondev.sh / optimize-nondev.sh) rather than pre-created at a homedir:
# CI runs as a non-root user, and a homedir owned by the wrong uid makes gpg
# print "unsafe ownership" warnings onto stderr, which the app captures.

set -u

ROOTFS="${1:-}"
if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then
    echo "install-gnupg-home: rootfs dir '${ROOTFS:-<empty>}' not found" >&2
    exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files/gnupg"
DEST="$ROOTFS/usr/share/seedsigner/gnupg"

log() { echo "  [gnupg] $*"; }

echo "=== Staging GnuPG agent/scdaemon config ==="

if [ ! -d "$SRC" ]; then
    echo "install-gnupg-home: template dir not found: $SRC" >&2
    exit 1
fi

mkdir -p "$DEST"

for conf in gpg-agent.conf scdaemon.conf; do
    if [ ! -f "$SRC/$conf" ]; then
        echo "install-gnupg-home: ERROR — missing template $SRC/$conf" >&2
        exit 1
    fi
    cp -v "$SRC/$conf" "$DEST/$conf"
    chmod 0644 "$DEST/$conf"
done

# Assert rather than warn. A silent miss ships a device where gpg-agent falls
# back to its compiled-in defaults and scdaemon may fight pcscd for the SEC1210
# reader — a smartcard regression with no build-time signal.
for conf in gpg-agent.conf scdaemon.conf; do
    [ -f "$DEST/$conf" ] || {
        echo "install-gnupg-home: ERROR — $DEST/$conf was not installed" >&2
        exit 1
    }
done
log "staged gpg-agent.conf + scdaemon.conf in /usr/share/seedsigner/gnupg"

# Sanity checks only: report, never fail. A rootfs without gpg is a legitimate
# configuration (the GPG features simply won't be reachable), and failing the
# build over it would be worse than saying so.
[ -x "$ROOTFS/usr/bin/gpg" ] || log "WARNING: no /usr/bin/gpg in the rootfs — GPG features will not work"
if [ ! -e "$ROOTFS/usr/bin/pinentry" ]; then
    log "WARNING: /usr/bin/pinentry absent, but gpg-agent.conf names it"
    log "  (harmless in practice: the app drives gpg with --pinentry-mode loopback)"
    ls "$ROOTFS/usr/bin/"pinentry* 2>/dev/null || true
fi

echo "=== GnuPG config staged ==="
