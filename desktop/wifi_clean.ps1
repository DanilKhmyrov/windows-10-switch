# Removes older SwitchWifi packages from the driver store, keeping the one bound to the Wi-Fi
# device (ACPI\SWOA0D01). Called by w64.cmd on every Windows 11 boot; does nothing when there
# is only one package.
#   powershell -NoProfile -ExecutionPolicy Bypass -File wifi_clean.ps1
$device = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\SWOA0D01\0' -ErrorAction SilentlyContinue
if (-not $device -or $device.DeviceDesc -notmatch '@(oem\d+\.inf)') {
    'wifi clean: no package bound to the device'
    exit 0
}
$active = $Matches[1]
# pnputil prints one block per package, separated by blank lines; the labels are localized,
# so only the file names are matched.
$blocks = (pnputil /enum-drivers | Out-String) -split '(?:\r?\n){2,}'
foreach ($block in $blocks) {
    if ($block -notmatch 'switchwifi\.inf') { continue }
    if ($block -notmatch '(oem\d+\.inf)') { continue }
    $name = $Matches[1]
    if ($name -ne $active) {
        pnputil /delete-driver $name
        "wifi clean: removed $name (bound: $active)"
    }
}
