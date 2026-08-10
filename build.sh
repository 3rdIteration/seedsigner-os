#!/bin/bash
#
# Unified SeedSigner OS build dispatcher.
#
# Routes to one of the two coexisting build pipelines in this repo:
#   * Raspberry Pi / La Frite  -> Buildroot (opt/build.sh) run via docker compose
#   * Luckfox Pico             -> Rockchip vendor-SDK build under opt/luckfox/
#
# The two pipelines are independent (different toolchains, containers and
# outputs); this wrapper just picks the right one from a single command.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./build.sh <target> [options]

Raspberry Pi / La Frite (Buildroot, via docker compose -> opt/build.sh):
  --pi0 | --pi2 | --pi02w | --pi4 | --lafrite | --all   [--smartcard] [--dev] [...]
      Builds images/seedsigner_os.*.img
      Any extra flags are forwarded verbatim to opt/build.sh.

Luckfox Pico (Rockchip SDK, via opt/luckfox/build.sh):
  --luckfox [build|interactive|shell|clean|status] [--microsd] [--nand] \
            [--model mini|max|both] [--jobs N] [...]
      Builds SD / NAND / eMMC artifacts into opt/luckfox/build-output/
      Any extra args are forwarded verbatim to opt/luckfox/build.sh.
      With no sub-args, defaults to: build --microsd

Examples:
  ./build.sh --pi0 --smartcard --dev
  ./build.sh --luckfox build --microsd --model mini
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

case "$1" in
  --luckfox)
    shift
    # Default to a standard automated SD build when no sub-command is given.
    if [[ $# -eq 0 ]]; then
      set -- build --microsd
    fi
    exec "$REPO_DIR/opt/luckfox/build.sh" "$@"
    ;;
  --pi0|--pi2|--pi02w|--pi4|--lafrite|-a|--all)
    # Delegate to the Buildroot pipeline. docker-compose passes ${SS_ARGS} as the
    # command to opt/build.sh (the container entrypoint).
    export SS_ARGS="$*"
    exec docker compose -f "$REPO_DIR/docker-compose.yml" up \
      --force-recreate --build --exit-code-from build-images
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Error: unknown target '$1'" >&2
    echo >&2
    usage
    exit 1
    ;;
esac
