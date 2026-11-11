#!/bin/bash
# Builds UEFI in Docker. Output: uefi/out/NintendoSwitch.fd
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"

docker build -q -t switch-wp-uefi "$PROJECT/uefi"
docker run --rm \
    -e EDK2_COMMIT \
    -e ARCH \
    -e TARGET \
    -e CLEAN \
    -e WIN11 \
    -e WIFI \
    -v switch-wp-edk2:/work \
    -v "$PROJECT:/project" \
    switch-wp-uefi bash /project/uefi/container-build.sh
