#!/bin/bash
# Внутри контейнера (--device /dev/fuse --cap-add SYS_ADMIN). Включает экран ошибок
# и отключает драйверы оборудования телефона.   patch_services.sh mainos.img
set -euo pipefail
IMAGE="$1"
SERVICES="QcTrEE QcUsbFnFilter qcPILC qcQDSS qcpep qcpmic qcscm qcspmi COEX CameraESP Icaros_KMD_ESP_Thermal GpuEnergyDrv WindowsTrustedRT WindowsTrustedRTProxy TPM cnghwassist ufnserialclass SensorsClx0101 CAD CellUserModeInterconnect HidMessageBroker_G1 HidMessageBroker_G2 HidMessageBroker_G3 HidMessageBroker_G4"
TMP="$(mktemp -d)"; MNT="$TMP/mnt"; mkdir "$MNT"
ROOT='HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001'
{
    printf 'Windows Registry Editor Version 5.00\n\n[%s\\Control\\CrashControl]\n' "$ROOT"
    printf '"DisplayDisabled"=dword:00000000\n"AutoReboot"=dword:00000000\n"DisplayParameters"=dword:00000001\n"CrashDumpEnabled"=dword:00000000\n\n'
    for service in $SERVICES; do
        printf '[%s\\Services\\%s]\n"Start"=dword:00000004\n\n' "$ROOT" "$service"
    done
} > "$TMP/services.reg"
ntfsfix -d "$IMAGE" >/dev/null
ntfs-3g -o remove_hiberfile "$IMAGE" "$MNT"
trap 'fusermount -u "$MNT" 2>/dev/null || true' EXIT
HIVE="$MNT/Windows/System32/config/SYSTEM"
cp "$HIVE" "$TMP/SYSTEM"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$TMP/SYSTEM" "$TMP/services.reg"
cp "$TMP/SYSTEM" "$HIVE"
cmp "$TMP/SYSTEM" "$HIVE"
sync
echo ok
