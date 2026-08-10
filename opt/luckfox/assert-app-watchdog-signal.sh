#!/usr/bin/env bash
#
# assert-app-watchdog-signal.sh <SEEDSIGNER_CODE_DIR> [build_variant]
#
# Fail the build when the staged SeedSigner app cannot satisfy the OS boot
# watchdog. Shared by the GitHub Actions build and both local Docker builds
# (os-build.sh / build-local.sh) — change this script, never one caller. Run
# after the app clone/checkout (and after any checkout-reuse decision, so a
# stale reused checkout is caught too), BEFORE the expensive part of the build.
#
# WHY: start-seedsigner.sh arms a 120 s boot watchdog on EVERY boot, in BOTH
# variants: if /tmp/seedsigner-ready never appears, it reboots into rockusb
# Loader mode. The app writes that marker from signal_app_alive() — added in
# app commit 689483af (2026-07-28) and, at the time of writing, present only on
# the generalized-platform-detection branch: 'dev' and every release tag lack
# it. An image built from a signal-less ref boots the app, looks completely
# healthy — and reboots into Loader 120 s later, on every boot. Exactly the
# kind of failure that builds green and only shows up on hardware, so it is
# checked here instead: the app source is in hand and the check is free.
#
# SCOPE BY BUILD VARIANT (2nd argument). The hard failure exists to stop a
# PRODUCTION image from shipping and Loader-looping. Non-dev (production,
# shipped) builds therefore fail hard on a signal-less app. Dev (debuggable,
# never shipped) builds — which carry serial + adb, so the failure is visible
# and recoverable — downgrade to a warning, because automatic push/PR CI always
# builds the dev variant against the app's 'dev' branch (which predates the
# signal); a hard fail there would block all OS development until the app
# signal merges. The caller passes its variant: build-luckfox.yml passes the
# CI input, os-build.sh/build-local.sh pass $SEEDSIGNER_BUILD_VARIANT/
# $BUILD_VARIANT. An omitted/unknown variant defaults to non-dev (the safe,
# hard-failing direction).
#
# Escape hatch, for deliberately building an old app (bisect / A-B):
#   SEEDSIGNER_ALLOW_NO_WATCHDOG_SIGNAL=1  downgrades the failure to a warning.

set -eu

APP_DIR="${1:-}"
VARIANT="${2:-non-dev}"
if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
    echo "assert-app-watchdog-signal: seedsigner dir '${APP_DIR:-<empty>}' not found" >&2
    exit 1
fi

# Grep the whole tree, not one file: the write may move (it currently lives in
# signal_app_alive() in src/seedsigner/helpers/seedsigner_os.py). A false
# negative here would fail a good build; a false positive would ship a
# Loader-looping one — and the escape hatch below covers genuine refactors.
if grep -rq 'seedsigner-ready' "$APP_DIR/src" 2>/dev/null; then
    echo "✅ app carries the boot-watchdog liveness signal (seedsigner-ready)"
    exit 0
fi

if [ "${SEEDSIGNER_ALLOW_NO_WATCHDOG_SIGNAL:-0}" = "1" ] || [ "$VARIANT" = "dev" ]; then
    echo "⚠️  app has NO boot-watchdog liveness signal" >&2
    if [ "$VARIANT" = "dev" ]; then
        echo "⚠️  dev build (debuggable, never shipped): continuing with a warning" >&2
    else
        echo "⚠️  SEEDSIGNER_ALLOW_NO_WATCHDOG_SIGNAL=1, continuing anyway" >&2
    fi
    echo "⚠️  the image will reboot into Loader mode 120 s after every app start" >&2
    exit 0
fi

cat >&2 <<'EOF'
❌ assert-app-watchdog-signal: the staged SeedSigner app never writes
   /tmp/seedsigner-ready, so it cannot satisfy the Luckfox boot watchdog —
   start-seedsigner.sh reboots into rockusb Loader mode 120 s after app start
   when the marker never appears. The image would boot the app, look healthy,
   and Loader-loop on every boot.

   This is a non-dev (production) build, which is a hard gate: a shipped
   image must never Loader-loop. Dev builds (serial + adb, never shipped)
   warn instead.

   Use an app ref containing commit 689483af or later (2026-07-28), e.g. the
   generalized-platform-detection branch; 'dev' and all release tags predate
   it. (--seedsigner-ref locally / the seedsigner_branch CI input.)

   To build a signal-less app anyway (bisect / A-B), set
   SEEDSIGNER_ALLOW_NO_WATCHDOG_SIGNAL=1.
EOF
exit 1
