#!/bin/bash
# Только читает карту: таблица разделов, загрузочные сектора и полное чтение
# раздела Windows в поисках ошибок чтения. Ничего не записывает на карту.
#   sudo ./desktop/diag_card.sh disk4 62534975488 папка/для/отчёта
set -uo pipefail

DISK="$1"
EXPECTED_BYTES="$2"
OUT="$3"
WIN_MIB=10815
WIN_SIZE_MIB=12288

INFO="$(diskutil info "$DISK")"
grep -q 'Device / Media Name: *SD RAW' <<<"$INFO" || { echo "Это не карта из Hekate: $DISK"; exit 1; }
grep -q "($EXPECTED_BYTES Bytes)" <<<"$INFO" || { echo "Размер карты не совпал"; exit 1; }
mkdir -p "$OUT"

echo "Читаю таблицу разделов..."
dd if="/dev/r$DISK" of="$OUT/mbr.bin" bs=512 count=1 2>/dev/null
# Логические разделы: заголовки EBR в начале расширенного раздела и дальше по цепочке.
for mib in 2016 2023 3600 5464 10814; do
    dd if="/dev/r$DISK" of="$OUT/ebr-$mib.bin" bs=1m skip="$mib" count=1 2>/dev/null
done
dd if="/dev/r$DISK" of="$OUT/esp-head.bin" bs=1m skip=2 count=4 2>/dev/null
dd if="/dev/r$DISK" of="$OUT/win-head.bin" bs=1m skip="$WIN_MIB" count=1 2>/dev/null

echo "Читаю раздел Windows целиком ($WIN_SIZE_MIB МиБ), это займёт несколько минут..."
ERRORS=0
for ((start = 0; start < WIN_SIZE_MIB; start += 256)); do
    if ! dd if="/dev/r$DISK" of=/dev/null bs=1m skip=$((WIN_MIB + start)) count=256 2>"$OUT/dd-err.txt"; then
        echo "ОШИБКА чтения около $((WIN_MIB + start)) МиБ: $(cat "$OUT/dd-err.txt")" | tee -a "$OUT/read-errors.txt"
        ERRORS=$((ERRORS + 1))
    fi
    printf "\r  прочитано %d из %d МиБ" "$((start + 256))" "$WIN_SIZE_MIB"
done
echo
echo "Ошибок чтения: $ERRORS" | tee "$OUT/read-summary.txt"
chmod -R a+r "$OUT"
echo "ГОТОВО: диагностика записана в $OUT"
