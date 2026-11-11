#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN): возвращает образ в режим
# программы установки, но вместо oobe\windeploy.exe запускает swagent\setup.cmd, который
# сам вызывает windeploy и копирует журналы на CRASHDUMP. Кусты SYSTEM и SECURITY берутся
# уже восстановленные hive_recover.py (папка с SYSTEM.rec и SECURITY.rec).
#   setup_mode.sh win.img папка_с_кустами
set -euo pipefail
IMAGE="$1"; HIVES="$2"; HERE="$(dirname "$0")"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfsfix -d "$IMAGE"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
CONFIG="$MNT/Windows/System32/config"

cp "$HIVES/SYSTEM.rec" "$TMP/SYSTEM"; cp "$HIVES/SECURITY.rec" "$TMP/SECURITY"

cat > "$TMP/setup.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"SystemSetupInProgress"=dword:00000001
"OOBEInProgress"=dword:00000001
"SetupType"=dword:00000002
"SetupPhase"=dword:00000004
"CmdLine"="C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\setup.cmd"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/setup.reg"
hivexget "$TMP/SYSTEM" '\Setup'

for HIVE in SYSTEM SECURITY; do
    cp "$TMP/$HIVE" "$CONFIG/$HIVE"
    cmp "$TMP/$HIVE" "$CONFIG/$HIVE"
    # Журналы уже применены: пустые журналы Windows не воспроизводит.
    : > "$CONFIG/$HIVE.LOG1"; : > "$CONFIG/$HIVE.LOG2"
done
cp "$HERE/setup.cmd" "$HERE/copylogs.cmd" "$MNT/swagent/"
echo done > "$MNT/swagent/user.done"
sync
echo ok
