#!/bin/bash
# Puts a BCD on the card's boot partition. macOS does not mount EFI-type partitions by itself,
# hence sudo.   sudo ./desktop/put_bcd.sh disk4 62534975488 BCD [backup_of_old]
set -euo pipefail
DISK="$1"; EXPECTED="$2"; BCD="$3"; BACKUP="${4:-}"
INFO="$(diskutil info "$DISK")"
grep -q 'SD RAW' <<<"$INFO" && grep -q "($EXPECTED Bytes)" <<<"$INFO" || { echo "Wrong card"; exit 1; }
MNT="$(mktemp -d /tmp/switch-esp.XXXXXX)"
mount -t msdos "/dev/${DISK}s1" "$MNT"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"' EXIT
TARGET="$MNT/EFI/microsoft/boot/bcd"
[ -f "$TARGET" ] || TARGET="$MNT/EFI/Microsoft/Boot/BCD"
[ -f "$TARGET" ] || { echo "No BCD on the card"; ls -R "$MNT/EFI" | head; exit 1; }
ls -la "$(dirname "$TARGET")"
[ -n "$BACKUP" ] && cp "$TARGET" "$BACKUP" && chmod 644 "$BACKUP"
rm -f "$(dirname "$TARGET")"/BCD.LOG* "$(dirname "$TARGET")"/bcd.log*
cp "$BCD" "$TARGET"
cmp "$BCD" "$TARGET"
sync
echo "DONE: BCD written"
