#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN).
# Кладёт драйвер в образ MainOS и регистрирует его службой.
#   patch_mainos.sh mainos.img драйвер.sys имя_службы
# START=0 — загрузочный драйвер, 4 — выключен; ERROR_CONTROL=1 — сообщать об ошибке.
set -euo pipefail
IMAGE="$1"; DRIVER="$2"; SERVICE="$3"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
# Windows выключают кнопкой, поэтому том помечен незакрытым. ntfsfix сбрасывает журнал.
ntfsfix -d "$IMAGE"
ntfs-3g -o remove_hiberfile "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true' EXIT
SYS="$MNT/Windows/System32"
[ -f "$SYS/config/SYSTEM" ] || { echo "Нет SYSTEM"; exit 1; }
cp "$SYS/config/SYSTEM" "$TMP/SYSTEM"
cat > "$TMP/service.reg" <<REG
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\$SERVICE]
"Type"=dword:00000001
"Start"=dword:0000000${START:-1}
"ErrorControl"=dword:0000000${ERROR_CONTROL:-0}
"ImagePath"=str(2):"\\\\SystemRoot\\\\System32\\\\drivers\\\\$SERVICE.sys"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/service.reg"
cp "$DRIVER" "$SYS/Drivers/$SERVICE.sys"
cp "$TMP/SYSTEM" "$SYS/config/SYSTEM"
cmp "$DRIVER" "$SYS/Drivers/$SERVICE.sys"
cmp "$TMP/SYSTEM" "$SYS/config/SYSTEM"
sync
echo "ok: $SERVICE"
