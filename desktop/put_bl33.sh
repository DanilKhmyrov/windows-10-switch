#!/bin/bash
# Puts a new loader (bl33: shim + UEFI) on the card's boot partition as wp/bl33.bin.
# macOS does not mount EFI-type partitions by itself, hence sudo. The previous file is kept
# next to it as wp/bl33-prev.bin so it can be restored.
#   sudo ./desktop/put_bl33.sh disk4 62534975488 new_bl33.bin [folder, default wp]
set -euo pipefail
DISK="$1"; EXPECTED="$2"; NEW="$3"; FOLDER="${4:-wp}"
INFO="$(diskutil info "$DISK")"
grep -q 'SD RAW' <<<"$INFO" && grep -q "($EXPECTED Bytes)" <<<"$INFO" || { echo "Wrong card"; exit 1; }
[ -s "$NEW" ] || { echo "No file $NEW"; exit 1; }
MNT="$(mktemp -d /tmp/switch-esp.XXXXXX)"
mount -t msdos "/dev/${DISK}s1" "$MNT"
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT"' EXIT
TARGET="$MNT/$FOLDER/bl33.bin"
[ -f "$TARGET" ] || { echo "No $FOLDER/bl33.bin on the card"; ls "$MNT"; exit 1; }
ls -la "$MNT/$FOLDER"
cp "$TARGET" "$MNT/$FOLDER/bl33-prev.bin"
cp "$NEW" "$TARGET"
cmp "$NEW" "$TARGET"
sync
echo "DONE: bl33 written, the previous one is saved as $FOLDER/bl33-prev.bin"
