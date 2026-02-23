#!/bin/sh

set -u
set -e

# Overlay dev-specific startup script for MicroSD override
cp -a "${BR2_EXTERNAL_RPI_SEEDSIGNER_PATH}/../rootfs-overlay-dev/." "${TARGET_DIR}/"
