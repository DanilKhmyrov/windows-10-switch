#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN).
# Добавляет запасной дисплей и настройки оболочки, возвращает службы доверенной среды.
#   patch_display.sh mainos.img {guid-класса}
set -euo pipefail
IMAGE="$1"; CLASS="$2"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ntfsfix -d "$IMAGE" >/dev/null
ntfs-3g -o remove_hiberfile "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
CONFIG="$MNT/Windows/System32/config"
cp "$CONFIG/SYSTEM" "$TMP/SYSTEM"; cp "$CONFIG/SOFTWARE" "$TMP/SOFTWARE"
INDEX="$(printf 'cd ControlSet001\\Control\\Class\\%s\nls\n' "$CLASS" | hivexsh "$TMP/SYSTEM" 2>/dev/null | grep -E '^[0-9]{4}$' | sort | tail -1 || true)"
if [ -n "$INDEX" ]; then NEXT="$(printf '%04d' $((10#$INDEX + 1)))"; else NEXT=0000; fi
python3 -I - "$TMP/system.reg" "$TMP/software.reg" "$CLASS" "$NEXT" <<'PY'
import sys
system, software, cls, index = sys.argv[1:5]
R = 'HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001'
def multi(items):
    raw = ''.join(i + '\0' for i in items) + '\0'
    return ','.join(f'{b:02x}' for b in raw.encode('utf-16-le'))
DEVICE_ID = 'ROOT\\BasicDisplay'
def esc(s): return s.replace('\\', '\\\\').replace('"', '\\"')
out = ['Windows Registry Editor Version 5.00', '']
out += [f'[{R}\\Control\\Class\\{cls}\\{index}]',
        '"DriverDesc"="Microsoft Basic Display Driver"', '"ProviderName"="Microsoft"',
        '"DriverDateData"=hex(3):00,80,8c,a3,c5,94,c6,01', '"DriverDate"="6-21-2006"',
        '"DriverVersion"="10.0.10586.0"', '"InfPath"="basicdisplay.inf"',
        '"InfSection"="MSBDD_Fallback"', '"MatchingDeviceId"="' + esc(DEVICE_ID) + '"', '']
out += [f'[{R}\\Enum\\Root\\BasicDisplay]', '', f'[{R}\\Enum\\Root\\BasicDisplay\\0000]',
        '"HardwareID"=hex(7):' + multi([DEVICE_ID]),
        '"ConfigFlags"=dword:00000000', '"DeviceReported"=dword:00000001',
        '"Service"="BasicDisplay"', '"Capabilities"=dword:00000000',
        f'"ClassGUID"="{cls}"',
        '"DeviceDesc"="@basicdisplay.inf,%msbddfallbackname%;Microsoft Basic Display Driver"',
        '"Driver"="' + esc(cls + chr(92) + index) + '"',
        '"Mfg"="@basicdisplay.inf,%std%;(Standard display types)"',
        '"ContainerID"="{00000000-0000-0000-FFFF-FFFFFFFFFFFF}"', '']
out += [f'[{R}\\Enum\\Root\\BasicDisplay\\0000\\Device Parameters]', '']
out += [f'[{R}\\Services\\BasicDisplay\\Video]', '"Service"="BasicDisplay"', '']
out += [f'[{R}\\Services\\LaunchAppSvc]',
        f'"DependOnService"=hex(7):{multi(["AccountProvSvc", "UserManager"])}', '']
for name, start in (('WindowsTrustedRT', 0), ('WindowsTrustedRTProxy', 0), ('TPM', 0),
                    ('cnghwassist', 0), ('ufnserialclass', 0), ('SensorsClx0101', 1), ('CAD', 1),
                    ('CellUserModeInterconnect', 1), ('HidMessageBroker_G1', 1),
                    ('HidMessageBroker_G2', 1), ('HidMessageBroker_G3', 1), ('HidMessageBroker_G4', 1)):
    out += [f'[{R}\\Services\\{name}]', f'"Start"=dword:{start:08x}', '']
open(system, 'w').write('\n'.join(out) + '\n')
open(software, 'w').write('Windows Registry Editor Version 5.00\n\n'
    '[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\UIX]\n'
    '"ResolutionOverrideWidth"=dword:000002d0\n"ResolutionOverrideHeight"=dword:00000500\n')
PY
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/system.reg"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$TMP/SOFTWARE" "$TMP/software.reg"
cp "$TMP/SYSTEM" "$CONFIG/SYSTEM"; cp "$TMP/SOFTWARE" "$CONFIG/SOFTWARE"
cmp "$TMP/SYSTEM" "$CONFIG/SYSTEM"; cmp "$TMP/SOFTWARE" "$CONFIG/SOFTWARE"
sync
echo "ok: display index $NEXT"
