#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN). Регистрирует службу,
# которая при старте Windows запускает D:\agent\run.cmd с раздела CRASHDUMP.
#   patch_agent.sh mainos.img
set -euo pipefail
IMAGE="$1"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfsfix -d "$IMAGE" >/dev/null
ntfs-3g -o remove_hiberfile "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
cat > "$TMP/service.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\swagent]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000000
"ObjectName"="LocalSystem"
"ImagePath"=str(2):"C:\\Windows\\System32\\cmd.exe /c start /b C:\\Windows\\System32\\cmd.exe /c D:\\agent\\run.cmd"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/service.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
sync
echo "ok: swagent"
