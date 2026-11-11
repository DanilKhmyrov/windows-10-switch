#!/bin/bash
# Read-only: partition table, boot sectors and a full read of the Windows
# partition looking for read errors. Writes nothing to the card.
#   sudo ./desktop/diag_card.sh disk4 62534975488 report/folder
set -uo pipefail

DISK="$1"
EXPECTED_BYTES="$2"
OUT="$3"
WIN_MIB=10815
WIN_SIZE_MIB=12288

INFO="$(diskutil info "$DISK")"
grep -q 'Device / Media Name: *SD RAW' <<<"$INFO" || { echo "Not a Hekate SD card: $DISK"; exit 1; }
grep -q "($EXPECTED_BYTES Bytes)" <<<"$INFO" || { echo "Card size does not match"; exit 1; }
mkdir -p "$OUT"

echo "Reading the partition table..."
dd if="/dev/r$DISK" of="$OUT/mbr.bin" bs=512 count=1 2>/dev/null
# Logical partitions: EBR headers at the start of the extended partition and along the chain.
for mib in 2016 2023 3600 5464 10814; do
    dd if="/dev/r$DISK" of="$OUT/ebr-$mib.bin" bs=1m skip="$mib" count=1 2>/dev/null
done
dd if="/dev/r$DISK" of="$OUT/esp-head.bin" bs=1m skip=2 count=4 2>/dev/null
dd if="/dev/r$DISK" of="$OUT/win-head.bin" bs=1m skip="$WIN_MIB" count=1 2>/dev/null

echo "Reading the whole Windows partition ($WIN_SIZE_MIB MiB), this takes a few minutes..."
ERRORS=0
for ((start = 0; start < WIN_SIZE_MIB; start += 256)); do
    if ! dd if="/dev/r$DISK" of=/dev/null bs=1m skip=$((WIN_MIB + start)) count=256 2>"$OUT/dd-err.txt"; then
        echo "READ ERROR near $((WIN_MIB + start)) MiB: $(cat "$OUT/dd-err.txt")" | tee -a "$OUT/read-errors.txt"
        ERRORS=$((ERRORS + 1))
    fi
    printf "\r  read %d of %d MiB" "$((start + 256))" "$WIN_SIZE_MIB"
done
echo
echo "Read errors: $ERRORS" | tee "$OUT/read-summary.txt"
chmod -R a+r "$OUT"
echo "DONE: diagnostics written to $OUT"
