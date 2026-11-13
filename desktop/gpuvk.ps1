# One-time Vulkan triangle test with mesa-switch-woa's NVK (GPU Test loader only). Called by
# w64.cmd when agent\gpuvk\run.flag exists; the flag is deleted first. Results: agent\gpuvk\result.txt.
#   powershell -NoProfile -ExecutionPolicy Bypass -File gpuvk.ps1 AGENT_DIR
# agent\gpuvk holds: driver\ (tegragpurender 0.1.0.200, the native-submission build of
# drivers/build_gpu.sh NATIVE=200, with firmware), libvulkan_nouveau.dll, nvk_windows_icd.json,
# nvk-windows-check.exe, vk-triangle.exe and vulkan-1.dll (drivers/nvk/build.sh).
# Steps:
#  1. the diagnostic tegragpuprobe package is removed and the native render driver installed;
#  2. the author's one-time start permit is given (volatile key AllowDesktopStart and
#     TgGpuBootTest200.bin with 1, which the driver resets to 0 before touching the GPU) and the
#     device restarted, so it starts with native submission once; after any reboot it starts
#     without it (the permit file reads 0);
#  3. nvk-windows-check: the ICD finds the adapter and its LUID;
#  4. vk-triangle: a Vulkan draw on the GM20B, pixels read back and checked.
param([string]$Agent)
$src = Join-Path $Agent 'gpuvk'
$out = Join-Path $src 'result.txt'
function Log([string]$text) { Add-Content -Path $out -Value $text -Encoding ascii }
Remove-Item (Join-Path $src 'run.flag') -Force -ErrorAction SilentlyContinue
Log "==== gpuvk $(Get-Date -Format s)"
$id = 'ACPI\SWOA0F01\0'
if (-not (Get-PnpDevice -PresentOnly -InstanceId $id -ErrorAction SilentlyContinue)) {
    Log 'no GPU device: not the GPU Test loader, nothing done'; exit 0
}
function DeviceState {
    $svc = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Service).Data
    $ver = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_DriverVersion).Data
    $st = (Get-PnpDevice -InstanceId $id).Status
    "  device service=$svc version=$ver status=$st"
}
Log (DeviceState)

Log '-- 1. driver'
$probe = pnputil /enum-drivers | Out-String
foreach ($block in ($probe -split "(\r?\n){2,}")) {
    if ($block -match 'tegragpuprobe\.inf' -and $block -match '(oem\d+\.inf)') {
        Log "  removing $($Matches[1]) (tegragpuprobe)"
        pnputil /delete-driver $Matches[1] /uninstall /force 2>&1 | ForEach-Object { Log "  $_" }
    }
}
$dst = 'C:\swagent\gpunative'
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item (Join-Path $src 'driver\*') $dst
& (Join-Path $Agent 'wifi\inf2cat\Inf2Cat.exe') /driver:$dst /os:10_NI_ARM64 2>&1 | Select-Object -Last 2 | ForEach-Object { Log "  $_" }
if (-not (Test-Path "$dst\tegragpurender.cat")) { Log 'no catalog, stopped'; exit 1 }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Agent 'wifi\wifi_sign.ps1') "$dst\tegragpurender.cat" 2>&1 | ForEach-Object { Log "  $_" }
pnputil /add-driver "$dst\tegragpurender.inf" /install 2>&1 | ForEach-Object { Log "  $_" }
Start-Sleep -Seconds 10
Log (DeviceState)
$ver = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_DriverVersion).Data
if ($ver -ne '0.1.0.200') { Log 'the native driver is not bound, stopped'; exit 1 }

Log '-- 2. one-time native start'
$path = 'SYSTEM\CurrentControlSet\Services\tegragpurender\AllowDesktopStart'
$key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($path,
    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Microsoft.Win32.RegistryOptions]::Volatile)
$key.Close()
$permit = New-Object byte[] 4096
$permit[0] = 1
[IO.File]::WriteAllBytes("$env:SystemRoot\System32\drivers\TgGpuBootTest200.bin", $permit)
pnputil /restart-device $id 2>&1 | ForEach-Object { Log "  $_" }
Start-Sleep -Seconds 20
Log (DeviceState)
$p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tegragpurender\Parameters' -ErrorAction SilentlyContinue
foreach ($n in 'BootPermitStatus', 'StartGateStatus', 'ResourceStatus', 'HardwareStatus') {
    if ($p -and $null -ne $p.$n) { Log ("  {0} = 0x{1:X8}" -f $n, $p.$n) }
}
$left = [IO.File]::ReadAllBytes("$env:SystemRoot\System32\drivers\TgGpuBootTest200.bin")[0]
Log "  permit byte now $left (0 = consumed)"

Log '-- 3. nvk-windows-check'
$vk = 'C:\swagent\gpuvk'
if (Test-Path $vk) { Remove-Item $vk -Recurse -Force }
New-Item -ItemType Directory -Force $vk | Out-Null
Copy-Item (Join-Path $src '*') $vk -Exclude 'result.txt', 'run.flag', 'driver'
$env:NVK_I_WANT_A_BROKEN_VULKAN_DRIVER = '1'
$check = & "$vk\nvk-windows-check.exe" "$vk\libvulkan_nouveau.dll" 2>&1 | Out-String
Log "  exit $LASTEXITCODE"
Log $check
if ($check -notmatch '"kmt_luid":"([0-9a-f]{16})"') { Log 'no LUID, stopped'; exit 1 }
$luid = $Matches[1]

Log "-- 4. vk-triangle $luid"
$tri = & "$vk\vk-triangle.exe" "$vk\libvulkan_nouveau.dll" $luid 2>&1 | Out-String
Log "  exit $LASTEXITCODE"
Log $tri
Log (DeviceState)
Log "==== done $(Get-Date -Format s)"
