#!/bin/bash
# Launch a local Pi/Lafrite build that reproduces one of the two CI lineages.
#
# Usage: launch-pi.sh <tag> <app|osrepo> [dev]
#   app     = app-repo release lineage (build-buildroot.yml dispatch): OS provenance
#             is NOT set, so /etc/seedsigner-os-release records "unknown" for the
#             four SEEDSIGNER_OS_* fields. This is what lands on the seedsigner
#             (app) release.
#   osrepo  = OS-repo lineage (build.yml dispatch): provenance set to REPO/BRANCH/
#             COMMIT/DATE exactly as CI records them. BRANCH defaults to main;
#             override with SS_BRANCH=<branch> for other dispatch branches.
#   dev     = build the -dev variant images (pre-release OS-repo lineages ship these).
#
# The checkout must be at the tag's commit (any branch/detached state is fine — Pi
# builds do not read git state; provenance comes from the environment).
#
# Runs detached (`docker compose up -d`) so the build survives WSL idle shutdown.
set -euo pipefail

TAG="${1:?usage: launch-pi.sh <tag> <app|osrepo> [dev]}"
LINEAGE="${2:?lineage: app | osrepo}"
VARIANT="${3:-nondev}"   # nondev | dev

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_REPO_URL="https://github.com/3rdIteration/seedsigner"

if [ "$VARIANT" != "nondev" ] && [ "$VARIANT" != "dev" ]; then
    echo "variant must be nondev or dev, got: $VARIANT" >&2; exit 1
fi

# The checkout must contain exactly the tag's tree.
EXPECTED="$(git -C "$REPO_DIR" rev-parse "${TAG}^{commit}" 2>/dev/null || true)"
ACTUAL="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$EXPECTED" ]; then
    echo "tag $TAG not found in $REPO_DIR (fetch it first: git fetch origin refs/tags/$TAG)" >&2
    exit 1
fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "checkout is at ${ACTUAL:-?}, tag $TAG points at $EXPECTED" >&2
    echo "run: git -C \"$REPO_DIR\" checkout --detach $TAG && git -C \"$REPO_DIR\" submodule update --init opt/buildroot" >&2
    exit 1
fi

cd "$REPO_DIR"
mkdir -p images buildroot_dl .ccache .buildroot-ccache

export DOCKER_DEFAULT_PLATFORM=linux/amd64
# Cap parallelism: the container sees all host cores but the Docker VM's RAM is
# finite; unlimited -j OOMs on heavy packages. Job count never affects output bytes.
export PARALLEL_JOBS="${PARALLEL_JOBS:-8}"

DEVARG=""
[ "$VARIANT" = "dev" ] && DEVARG=" --dev"

case "$LINEAGE" in
    app)
        # Lineage A: the app-side workflow never sets SEEDSIGNER_OS_* -> "unknown".
        unset SEEDSIGNER_OS_REPO SEEDSIGNER_OS_BRANCH SEEDSIGNER_OS_COMMIT SEEDSIGNER_OS_DATE
        PROJECT="ss-rel-app${VARIANT}"
        ;;
    osrepo)
        # Lineage B: mirror build.yml's "Capture OS provenance" step.
        export SEEDSIGNER_OS_REPO="https://github.com/3rdIteration/seedsigner-os"
        export SEEDSIGNER_OS_BRANCH="${SS_BRANCH:-main}"
        export SEEDSIGNER_OS_COMMIT="$EXPECTED"
        export SEEDSIGNER_OS_DATE="$(git -C "$REPO_DIR" show -s --format=%cI "$TAG")"
        PROJECT="ss-rel-osrepo${VARIANT}"
        ;;
    *)
        echo "unknown lineage: $LINEAGE (use app | osrepo)" >&2; exit 1
        ;;
esac

export SS_ARGS="--all --smartcard${DEVARG} \
  --app-repo=${APP_REPO_URL} \
  --app-branch=${TAG}"

echo "== launching Pi/Lafrite build: lineage=$LINEAGE variant=$VARIANT tag=$TAG"
echo "   project=$PROJECT  (images -> $REPO_DIR/images/)"
docker compose -p "$PROJECT" up -d --build

cat <<EOF

Watch it:
  docker logs -f ${PROJECT}-build-images-1
Done when the container exits; exit code:
  docker inspect -f '{{.State.ExitCode}}' ${PROJECT}-build-images-1
Then compare with tools/release-verify/compare-hashes.py
EOF
