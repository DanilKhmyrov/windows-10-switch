#!/bin/bash
# Builds the UEFI from scratch and packs it into bl33 together with the shim.
# If the UEFI build fails or the file was not updated, no bl33 is produced.
#   ./uefi/build_bl33.sh output.bin          (ARCH=AARCH64: 64-bit UEFI, CLEAN=1: clean screen,
#                                             WIN11=1: boots the partition marked for Windows 11 and prepares Wi-Fi)
set -euo pipefail
OUT="$1"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-ARM}"
if [ "$ARCH" = ARM ]; then BASE=NintendoSwitch-arm; MODE=chain32; else BASE=NintendoSwitch; MODE=chain; fi
FD="$PROJECT/uefi/out/$BASE.fd"
[ "${CLEAN:-0}" = 1 ] && FD="$PROJECT/uefi/out/$BASE-clean.fd"
[ "${WIN11:-0}" = 1 ] && FD="${FD%.fd}-win11.fd"
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
# Delay for BPMP memory training: the 64-bit UEFI keeps its early memory above 4 GB and needs longer.
DELAY=3000; [ "$ARCH" = ARM ] || DELAY=10000
python3 "$PROJECT/shim/build.py" "$MODE" "$FD" --clean --delay-ms "$DELAY" -o "$OUT"
