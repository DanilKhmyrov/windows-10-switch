#!/bin/bash
# Runs inside a container (--device /dev/fuse --cap-add SYS_ADMIN). Prepares Windows 10 ARM32 to boot:
# answer file, diagnostics service, blue screen settings, touch driver.   patch_desktop.sh w32.img
set -euo pipefail
IMAGE="$1"; HERE="$(dirname "$0")"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfs-3g "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
mkdir -p "$MNT/Windows/Panther" "$MNT/swagent"
cp "$HERE/unattend.xml" "$MNT/Windows/Panther/unattend.xml"
cp "$HERE/boot.cmd" "$MNT/swagent/boot.cmd"
cp "$HERE/../drivers/out/swhid.sys" "$MNT/Windows/System32/drivers/swhid.sys"
CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"
cat > "$TMP/system.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\swagent]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000000
"ObjectName"="LocalSystem"
"ImagePath"=str(2):"C:\\Windows\\System32\\cmd.exe /c start /b C:\\Windows\\System32\\cmd.exe /c C:\\swagent\\boot.cmd"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\swhid]
"Type"=dword:00000001
"Start"=dword:00000003
"ErrorControl"=dword:00000000
"ImagePath"=str(2):"\\SystemRoot\\System32\\drivers\\swhid.sys"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Enum\ACPI]

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Enum\ACPI\SWTS0001]

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Enum\ACPI\SWTS0001\0]
"Service"="swhid"
"Class"="HIDClass"
"ClassGUID"="{745a17a0-74d3-11d0-b6fe-00a0c90f57da}"
"ConfigFlags"=dword:00000000
"DeviceDesc"="Switch touch panel"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CrashControl]
"DisplayParameters"=dword:00000001
"AutoReboot"=dword:00000000
REG
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/system.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"
sync
echo ok
