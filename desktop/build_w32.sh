#!/bin/bash
# Внутри контейнера switch-wp-drivers (--device /dev/fuse --cap-add SYS_ADMIN).
# Собирает с нуля образ раздела Windows 10 ARM32 (12 ГиБ, начало на 10815 МиБ) из архива
# 15035 и накладывает все наши правки. Программа установки Windows остаётся включённой,
# но вместо oobe\windeploy.exe запускается swagent\setup.cmd: он сам вызывает windeploy
# и копирует журналы установки на раздел CRASHDUMP (\agent).
#   build_w32.sh архив.7z папка_для_образа
set -euo pipefail
ARCHIVE="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
cd "$WORK"
7z x -y -o"$WORK" "$ARCHIVE" sources/install.wim > /dev/null
IMAGE="$OUT/w32.img"
rm -f "$IMAGE"
truncate -s 12G "$IMAGE"
# -p: начало раздела в секторах (10815 МиБ), чтобы загрузочный сектор NTFS был верным.
mkntfs -F -Q -L Windows -p 22149120 -H 255 -S 63 "$IMAGE" > /dev/null
wimapply "$WORK/sources/install.wim" 1 "$IMAGE" 2>&1 | tr '\r' '\n' | grep -vE '^(Extracting|Applying|Creating)' | tail -2
rm -rf "$WORK/sources"

"$HERE/patch_desktop.sh" "$IMAGE"
"$HERE/skip_bcd_step.sh" "$IMAGE"

TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
cp "$HERE/setup.cmd" "$HERE/copylogs.cmd" "$HERE/boot.cmd" "$MNT/swagent/"
# Пользователя создаёт сама установка (unattend.xml), boot.cmd только пишет журнал.
echo done > "$MNT/swagent/user.done"
CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
echo "Исходные значения SYSTEM\\Setup:"
hivexget "$TMP/SYSTEM" '\Setup' | grep -E 'SetupType|SystemSetupInProgress|OOBEInProgress|SetupPhase|CmdLine'
cat > "$TMP/setup.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"CmdLine"="C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\setup.cmd"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/setup.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
hivexget "$CONFIG/SYSTEM" '\Setup' CmdLine
sync
echo "ГОТОВО: $IMAGE"
