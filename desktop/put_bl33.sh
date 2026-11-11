#!/bin/bash
# Кладёт новый загрузчик (bl33: прокладка + UEFI) на загрузочный раздел карты как wp/bl33.bin.
# Раздел с типом EFI macOS сама не подключает, поэтому нужен sudo. Прежний файл остаётся
# рядом как wp/bl33-prev.bin, чтобы его можно было вернуть.
#   sudo ./desktop/put_bl33.sh disk4 62534975488 новый_bl33.bin [папка, по умолчанию wp]
set -euo pipefail
DISK="$1"; EXPECTED="$2"; NEW="$3"; FOLDER="${4:-wp}"
INFO="$(diskutil info "$DISK")"
grep -q 'SD RAW' <<<"$INFO" && grep -q "($EXPECTED Bytes)" <<<"$INFO" || { echo "Это не та карта"; exit 1; }
[ -s "$NEW" ] || { echo "Нет файла $NEW"; exit 1; }
MNT="$(mktemp -d /tmp/switch-esp.XXXXXX)"
mount -t msdos "/dev/${DISK}s1" "$MNT"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"' EXIT
TARGET="$MNT/$FOLDER/bl33.bin"
[ -f "$TARGET" ] || { echo "На карте нет $FOLDER/bl33.bin"; ls "$MNT"; exit 1; }
ls -la "$MNT/$FOLDER"
cp "$TARGET" "$MNT/$FOLDER/bl33-prev.bin"
cp "$NEW" "$TARGET"
cmp "$NEW" "$TARGET"
sync
echo "ГОТОВО: bl33 записан, прежний сохранён как $FOLDER/bl33-prev.bin"
