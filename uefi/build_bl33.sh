#!/bin/bash
# Собирает 32-битный UEFI с нуля и упаковывает его в bl33 с прокладкой.
# Если сборка UEFI не удалась или файл не обновился, bl33 не создаётся.
#   ./uefi/build_bl33.sh выход.bin          (ARCH=AARCH64 — 64-битный UEFI, CLEAN=1 — чистый экран)
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
    echo "ОШИБКА: UEFI не собрался, bl33 не создан"
    exit 1
fi
[ "$FD" -nt "$STAMP" ] || { echo "ОШИБКА: $FD не обновился, bl33 не создан"; exit 1; }
python3 "$PROJECT/shim/build.py" "$MODE" "$FD" --clean --delay-ms 3000 -o "$OUT"
