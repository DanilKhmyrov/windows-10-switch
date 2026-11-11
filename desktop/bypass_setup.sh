#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN). Загружает образ как уже
# установленную Windows: снимает флаги программы установки. Пользователя создаёт boot.cmd.
#   bypass_setup.sh w32.img
set -euo pipefail
IMAGE="$1"; HERE="$(dirname "$0")"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
cp "$HERE/boot.cmd" "$MNT/swagent/boot.cmd"
rm -f "$MNT/swagent/user.done"
CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
cat > "$TMP/setup.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"SystemSetupInProgress"=dword:00000000
"OOBEInProgress"=dword:00000000
"SetupType"=dword:00000000
"SetupPhase"=dword:00000000
"CmdLine"=""
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/setup.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cmp "$HERE/boot.cmd" "$MNT/swagent/boot.cmd"
sync
echo ok
