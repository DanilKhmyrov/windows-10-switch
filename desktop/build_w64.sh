#!/bin/bash
# Внутри контейнера switch-wp-drivers (--device /dev/fuse --cap-add SYS_ADMIN).
# Собирает образ раздела Windows 10 ARM64 (24 ГиБ, начало на 23104 МиБ) из ESD и
# накладывает те же приёмы, что сработали на ARM32: файл ответов (пользователь Player),
# служба swagent с журналом на CRASHDUMP (\agent\w64.cmd), пропуск шага BCD, обёртка
# установки с журналами (\agent\a64). Драйверы ARM32 сюда не кладутся.
# Файлы загрузчика для CRASHDUMP складываются в <папка>/esp64.
#   build_w64.sh образ.esd индекс папка BCD_ARM64
set -euo pipefail
ESD="$1"; INDEX="$2"; OUT="$3"; BCD="$4"; HERE="$(cd "$(dirname "$0")" && pwd)"
START_MIB=23104; SIZE_MIB=24576
IMAGE="$OUT/w64.img"
rm -f "$IMAGE"
truncate -s "${SIZE_MIB}M" "$IMAGE"
mkntfs -F -Q -L Windows64 -p $((START_MIB * 2048)) -H 255 -S 63 "$IMAGE" > /dev/null
wimapply "$ESD" "$INDEX" "$IMAGE" 2>&1 | tr '\r' '\n' | grep -vE '^(Extracting|Applying|Creating)' | tail -2

TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
mkdir -p "$MNT/Windows/Panther" "$MNT/swagent"
cp "$HERE/unattend64.xml" "$MNT/Windows/Panther/unattend.xml"
cp "$HERE/boot64.cmd" "$MNT/swagent/boot.cmd"
cp "$HERE/setup64.cmd" "$MNT/swagent/setup.cmd"
cp "$HERE/copylogs.cmd" "$MNT/swagent/copylogs.cmd"

# Шаг Sysprep_Specialize_Bcd не может открыть хранилище BCD без переменных UEFI.
python3 - "$MNT/Windows/System32/Sysprep/ActionFiles/Specialize.xml" <<'PY'
import re, sys
p = sys.argv[1]
raw = open(p, "rb").read()
enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
t = raw.decode(enc)
new, n = re.subn(r"<imaging[^>]*>(?:(?!</imaging>).)*Microsoft-Windows-Sysprep-SpBcd(?:(?!</imaging>).)*</imaging>\s*", "", t, flags=re.S)
if n == 0:
    raise SystemExit("SpBcd step not found")
print(f"removed SpBcd steps: {n}")
open(p, "wb").write(new.encode(enc))
PY

CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
echo "Исходные SYSTEM\\Setup:"
hivexget "$TMP/SYSTEM" '\Setup' | grep -E 'SetupType|SystemSetupInProgress|OOBEInProgress|SetupPhase|CmdLine' || true
cat > "$TMP/system.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\swagent]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000000
"ObjectName"="LocalSystem"
"ImagePath"=str(2):"C:\\Windows\\System32\\cmd.exe /c start /b C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\boot.cmd"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CrashControl]
"DisplayParameters"=dword:00000001
"AutoReboot"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\Setup]
"CmdLine"="C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\setup.cmd"
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/system.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"; cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
hivexget "$CONFIG/SYSTEM" '\Setup' CmdLine

# Загрузчик ARM64 для раздела CRASHDUMP.
ESP="$OUT/esp64"
rm -rf "$ESP"; mkdir -p "$ESP/EFI/Boot" "$ESP/EFI/Microsoft/Boot"
cp -r "$MNT/Windows/Boot/EFI/." "$ESP/EFI/Microsoft/Boot/"
cp -r "$MNT/Windows/Boot/Fonts" "$ESP/EFI/Microsoft/Boot/Fonts"
cp "$MNT/Windows/Boot/EFI/bootmgfw.efi" "$ESP/EFI/Boot/bootaa64.efi"
cp "$BCD" "$ESP/EFI/Microsoft/Boot/BCD"
du -sh "$ESP"
sync
echo "ГОТОВО: $IMAGE"
