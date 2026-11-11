#!/bin/bash
# Builds the UEFI from scratch and packs it into bl33 together with the shim.
# If the UEFI build fails or the file was not updated, no bl33 is produced.
#   ./uefi/build_bl33.sh output.bin          (ARCH=AARCH64: 64-bit UEFI, CLEAN=1: clean screen)
set -euo pipefail
OUT="$1"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-ARM}"
if [ "$ARCH" = ARM ]; then BASE=NintendoSwitch-arm; MODE=chain32; else BASE=NintendoSwitch; MODE=chain; fi
FD="$PROJECT/uefi/out/$BASE.fd"
[ "${CLEAN:-0}" = 1 ] && FD="$PROJECT/uefi/out/$BASE-clean.fd"
STAMP="$(mktemp)"
LOG="$(mktemp)"
trap 'rm -f "$STAMP" "$LOG"' EXIT
sleep 1
if ! (cd "$PROJECT/uefi" && ARCH="$ARCH" ./build.sh > "$LOG" 2>&1); then
    grep -E "error|failed" "$LOG" | head -20
    echo "ERROR: UEFI did not build, no bl33 produced"
    exit 1
fi
[ "$FD" -nt "$STAMP" ] || { echo "ERROR: $FD was not updated, no bl33 produced"; exit 1; }
python3 "$PROJECT/shim/build.py" "$MODE" "$FD" --clean --delay-ms 3000 -o "$OUT"
