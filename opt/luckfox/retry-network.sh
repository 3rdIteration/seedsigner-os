#!/usr/bin/env bash
#
# retry-network.sh -- sourced by os-build.sh and build-local.sh (never run
# directly). It defines retry_sdk_step(), which wraps the Rockchip SDK build
# steps; it is not a build step of its own.
#
# WHY. opt/luckfox/configs/luckfox_pico_defconfig already hardens BR2_WGET with
# --retry-on-http-error, which rides out Buildroot mirror HTTP failures (429/5xx).
# It does NOT cover a TLS failure: wget aborts immediately on a certificate that
# does not verify, with no retry, e.g.
#
#   ERROR: cannot verify github.com's certificate ... 'dotcom.glb' doesn't match
#   requested host name 'github.com'
#   make[1]: *** [.../libraqm-0.10.3/.stamp_downloaded] Error 1
#
# And this repo's external packages (libraqm, ...) have a GitHub-only origin --
# Buildroot's backup mirror (sources.buildroot.net) does not carry the versions
# pinned here -- so once GitHub hiccups there is no fallback, and one bad minute
# kills a 1-2 h build. This is the Luckfox twin of opt/build.sh's
# run_buildroot_make, which the Pi/La Frite path has had since the 2026-08-23
# network-resilience work; the Luckfox path never inherited it.
#
# HOW. Retry the whole SDK step (uboot/kernel/rootfs/media/app/firmware) when,
# and only when, the failure looks transient. Buildroot is resumable -- its
# per-package .stamp_* files mean a retry picks up at the package that failed and
# keeps every tarball already downloaded -- so a retry that helps is cheap, and a
# retry that cannot help (a real compile or config error) is not attempted.
#
# Tunable: NETWORK_MAX_ATTEMPTS (default 5) and NETWORK_RETRY_DELAY seconds
# (default 120), overridable from the environment / build.sh passthrough.
# NETWORK_MAX_ATTEMPTS=1 restores fail-fast.

: "${NETWORK_MAX_ATTEMPTS:=5}"
: "${NETWORK_RETRY_DELAY:=120}"

# Failure signatures worth retrying: network/transport problems only, kept
# deliberately specific so a genuine build failure is never retried. The buildroot
# download stamp (\.stamp_downloaded) is what the libraqm failure produced.
NETWORK_TRANSIENT_RE='\.stamp_downloaded|ERROR (429|5[0-9][0-9]):|Connection (refused|timed out|reset)|Temporary failure in name resolution|Could not resolve host|Name or service not known|Unable to establish SSL connection|[Nn]etwork is unreachable|RPC failed|early EOF|fatal: unable to access|Service Unavailable|Bad Gateway|Gateway Time-?out|cannot verify .*certificate|doesn.t match requested host name|SSL certificate problem|[Cc]ertificate verification failed'

# retry_sdk_step "<description>" <command> [args...]
retry_sdk_step() {
    local what="$1"; shift
    local attempt=1 log rc had_e=0
    case "$-" in *e*) had_e=1 ;; esac

    while :; do
        log="$(mktemp)"
        # Run under `set +e` and read the command's own status via PIPESTATUS, so
        # this works whether or not the caller has `set -o pipefail` (a plain
        # `cmd | tee` would otherwise mask a failure in a no-pipefail caller).
        set +e
        "$@" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        [ "$had_e" = 1 ] && set -e

        if [ "$rc" -eq 0 ]; then
            rm -f "$log"
            return 0
        fi
        if ! grep -qE "$NETWORK_TRANSIENT_RE" "$log"; then
            echo "  [net-retry] $what: failed, and not for a transient network reason -- not retrying" >&2
            rm -f "$log"
            return 1
        fi
        if [ "$attempt" -ge "$NETWORK_MAX_ATTEMPTS" ]; then
            echo "  [net-retry] $what: transient failure persisted across $NETWORK_MAX_ATTEMPTS attempts" >&2
            rm -f "$log"
            return 1
        fi
        echo "  [net-retry] $what: transient network failure on attempt $attempt/$NETWORK_MAX_ATTEMPTS, retrying in ${NETWORK_RETRY_DELAY}s" >&2
        sleep "$NETWORK_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}
