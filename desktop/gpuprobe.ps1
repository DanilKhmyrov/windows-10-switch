# One-time GPU drawing test with mesa-switch-woa's diagnostic driver (GPU Test loader only).
# Called by w64.cmd when agent\gpuprobe\run.flag exists; the flag is deleted first, so a hang or
# a crash is not repeated on the next boot. Results go to agent\gpuprobe\result.txt.
#   powershell -NoProfile -ExecutionPolicy Bypass -File gpuprobe.ps1 AGENT_DIR
# Steps: Wi-Fi state (it did not start under this loader), install tegragpuprobe (catalog made
# and signed on the console as for the other drivers; its version outranks the render driver),
# then performance-check.exe: the blue clear, then the shader triangle. Each reads its pixels
# back and reports pass or fail as JSON.
param([string]$Agent)
$src = Join-Path $Agent 'gpuprobe'
$out = Join-Path $src 'result.txt'
function Log([string]$text) { Add-Content -Path $out -Value $text -Encoding ascii }
Remove-Item (Join-Path $src 'run.flag') -Force -ErrorAction SilentlyContinue
Log "==== gpuprobe $(Get-Date -Format s)"

if (-not (Get-PnpDevice -PresentOnly -InstanceId 'ACPI\SWOA0F01\0' -ErrorAction SilentlyContinue)) {
    Log 'no GPU device: not the GPU Test loader, nothing done'
    exit 0
}

Log '-- Wi-Fi and PCIe devices'
Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -match '^PCI\\|SWOA|BCM|SDIO' -or $_.Class -eq 'Net'
} | ForEach-Object { Log ("  {0,-8} {1} | {2}" -f $_.Status, $_.InstanceId, $_.FriendlyName) }
Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object { Log ("  adapter {0} {1} {2}" -f $_.Name, $_.Status, $_.InterfaceDescription) }

Log '-- install tegragpuprobe'
$dst = 'C:\swagent\gpuprobe'
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item (Join-Path $src '*') $dst -Exclude 'result.txt', 'run.flag'
$inf2cat = Join-Path $Agent 'wifi\inf2cat\Inf2Cat.exe'
& $inf2cat /driver:$dst /os:10_NI_ARM64 2>&1 | Select-Object -Last 3 | ForEach-Object { Log "  $_" }
if (-not (Test-Path "$dst\tegragpuprobe.cat")) { Log 'no catalog, stopped'; exit 1 }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Agent 'wifi\wifi_sign.ps1') "$dst\tegragpuprobe.cat" 2>&1 |
    ForEach-Object { Log "  $_" }
& pnputil /add-driver "$dst\tegragpuprobe.inf" /install 2>&1 | ForEach-Object { Log "  $_" }
Start-Sleep -Seconds 10
$service = (Get-PnpDeviceProperty -InstanceId 'ACPI\SWOA0F01\0' -KeyName DEVPKEY_Device_Service).Data
$status = (Get-PnpDevice -InstanceId 'ACPI\SWOA0F01\0').Status
Log "  device service=$service status=$status"
if ($service -ne 'tegragpuprobe') { Log 'the probe driver is not bound, stopped'; exit 1 }

foreach ($test in '--gpu-clear-729', '--gpu-draw-729') {
    Log "-- performance-check --gpu-json $test"
    $text = & "$dst\performance-check.exe" --gpu-json $test 2>&1 | Out-String
    Log "  exit $LASTEXITCODE"
    Log $text
}
Log "==== done $(Get-Date -Format s)"
