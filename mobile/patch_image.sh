#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN): правит BCD и реестр образа телефона.
#   patch_image.sh mainos.img BCD
set -euo pipefail
IMAGE="$1"; BCD="$2"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
python3 -I "$(dirname "$0")/prepare.py" "$TMP/bcd.reg" "$TMP/system.reg"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\BCD' "$BCD" "$TMP/bcd.reg"
printf 'cd \\Objects\\{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\Elements\\24000002\ndel\ncommit\n' | hivexsh -w "$BCD"
ntfsfix -d "$IMAGE" >/dev/null
ntfs-3g -o remove_hiberfile "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
HIVE="$MNT/Windows/System32/config/SYSTEM"
cp "$HIVE" "$TMP/SYSTEM"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/system.reg"
cp "$TMP/SYSTEM" "$HIVE"
cmp "$TMP/SYSTEM" "$HIVE"
sync
echo "ok"
