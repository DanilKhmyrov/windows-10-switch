#!/bin/bash
# Записывает образ диска на карту, подключённую через USB-режим Hekate.
#   sudo ./windows/write_card.sh disk4 62534975488 путь/к/disk.img
# Второй аргумент — точный размер карты в байтах. Всё содержимое карты будет стёрто.
set -euo pipefail

DISK="$1"
EXPECTED_BYTES="$2"
IMAGE="$3"
BLOCK_SIZE=1048576

INFO="$(diskutil info "$DISK")"
ACTUAL_BYTES="$(grep 'Disk Size:' <<<"$INFO" | sed -E 's/.*\(([0-9]+) Bytes\).*/\1/')"

[ "$(uname)" = Darwin ] || { echo "Скрипт только для macOS"; exit 1; }
grep -q 'Device / Media Name: *SD RAW' <<<"$INFO" || { echo "Это не карта из Hekate: $DISK"; exit 1; }
grep -q 'Protocol: *USB' <<<"$INFO" || { echo "$DISK подключён не по USB"; exit 1; }
grep -q 'Removable Media: *Removable' <<<"$INFO" || { echo "$DISK не съёмный диск"; exit 1; }
[ "$ACTUAL_BYTES" = "$EXPECTED_BYTES" ] || { echo "Размер $ACTUAL_BYTES, ожидался $EXPECTED_BYTES"; exit 1; }

IMAGE_BYTES="$(stat -f %z "$IMAGE")"
[ "$IMAGE_BYTES" -le "$ACTUAL_BYTES" ] || { echo "Образ больше карты"; exit 1; }
[ $((IMAGE_BYTES % BLOCK_SIZE)) = 0 ] || { echo "Размер образа не кратен 1 МиБ"; exit 1; }
BLOCKS=$((IMAGE_BYTES / BLOCK_SIZE))

echo "Записываю на /dev/$DISK..."
diskutil unmountDisk "/dev/$DISK"
dd if="$IMAGE" of="/dev/r$DISK" bs=1m
sync

echo "Сверяю запись..."
diskutil unmountDisk "/dev/$DISK"
EXPECTED_HASH="$(shasum -a 256 "$IMAGE" | cut -d' ' -f1)"
ACTUAL_HASH="$(dd if="/dev/r$DISK" bs=1m count="$BLOCKS" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
    echo "ОШИБКА: данные на карте не совпали с образом"
    exit 1
fi
echo "ГОТОВО: запись проверена"
diskutil mountDisk "/dev/$DISK" || true
