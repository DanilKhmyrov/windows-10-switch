#!/bin/bash
# Читает или записывает раздел MainOS карты с Windows. Нужен sudo.
#   sudo ./drivers/card_mainos.sh read  disk4 62534975488 mainos.img
#   sudo ./drivers/card_mainos.sh write disk4 62534975488 mainos.img
set -euo pipefail
MODE="$1"; DISK="$2"; EXPECTED_BYTES="$3"; IMAGE="$4"
PART="${DISK}s2"
INFO="$(diskutil info "$DISK")"
grep -q 'Device / Media Name: *SD RAW' <<<"$INFO" || { echo "Это не карта из Hekate: $DISK"; exit 1; }
grep -q "($EXPECTED_BYTES Bytes)" <<<"$INFO" || { echo "Неверный размер диска $DISK"; exit 1; }
diskutil info "$PART" | grep -q 'Volume Name: *MainOS' || { echo "$PART — не MainOS"; exit 1; }
diskutil unmount "/dev/$PART" || true
case "$MODE" in
    read)
        dd if="/dev/r$PART" of="$IMAGE" bs=1m
        chown "${SUDO_USER:-root}" "$IMAGE"
        ;;
    write)
        dd if="$IMAGE" of="/dev/r$PART" bs=1m
        sync
        cmp -n "$(stat -f %z "$IMAGE")" "$IMAGE" "/dev/r$PART" && echo "ГОТОВО: запись проверена"
        ;;
    *) echo "Режим: read или write"; exit 1 ;;
esac
