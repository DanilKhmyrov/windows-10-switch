# One-time desktop test on the GPU: mesa-switch-woa's WDDM display driver with tgd3d (Direct3D on
# NVK Vulkan) takes over the running desktop from the basic display driver. GPU Desktop loader
# only (GPUTEST=1 GPUDISPLAY=1: GPU0 owns the boot framebuffer and Display A).
# Called by w64.cmd when agent\gpudesk\run.flag exists; the flag is deleted first.
# Results: agent\gpudesk\result.txt (written through, so a hang keeps what was reached).
#   powershell -NoProfile -ExecutionPolicy Bypass -File gpudesk.ps1 AGENT_DIR
# agent\gpudesk: driver\ (tegragpurender 0.1.0.202: tools/build.py --display
# --native-test-version 201, signed), app\ (TegraGpuD3DVk.dll in CPU-sync mode,
# libvulkan_nouveau.dll, nvk_windows_icd.json, libunwind.dll, nvk-windows-check.exe).
# The steps follow the author's tgd3d-default package (logon-default mode):
#  1. install the display driver; without a permit it stays gated (the basic display driver
#     keeps the screen);
#  2. register tgd3d in UserModeDriverName slots 1 and 2 and the ICD as VulkanDriverName;
#  3. one-time permit (TgGpuBootTest202.bin = 1, volatile AllowDesktopStart) and a device
#     restart: the driver takes over the boot framebuffer it found and DWM switches to tgd3d;
#  4. 30 s of passive observation. A reboot always returns to the gated state.
param([string]$Agent)
$src = Join-Path $Agent 'gpudesk'
$out = Join-Path $src 'result.txt'
function Log([string]$text) {
    $f = [IO.FileStream]::new($out, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try { $b = [Text.Encoding]::ASCII.GetBytes($text + "`r`n"); $f.Write($b, 0, $b.Length); $f.Flush($true) } finally { $f.Dispose() }
}
Remove-Item (Join-Path $src 'run.flag') -Force -ErrorAction SilentlyContinue
Log "==== gpudesk $(Get-Date -Format s)"
$id = 'ACPI\SWOA0F01\0'
if (-not (Get-PnpDevice -PresentOnly -InstanceId $id -ErrorAction SilentlyContinue)) { Log 'no GPU device, nothing done'; exit 0 }
function Prop($k) { (Get-PnpDeviceProperty -InstanceId $id -KeyName "DEVPKEY_Device_$k" -ErrorAction SilentlyContinue).Data }
function State {
    $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tegragpurender\Parameters' -ErrorAction SilentlyContinue
    $s = "  device version=$(Prop DriverVersion) problem=$(Prop ProblemCode) status=$((Get-PnpDevice -InstanceId $id).Status)"
    foreach ($n in 'BootPermitStatus', 'StartGateStatus', 'ResourceStatus', 'StartStep', 'StartStepStatus', 'HardwareStatus', 'PanelStatus') {
        if ($p -and $null -ne $p.$n) { $s += (" {0}=0x{1:X8}" -f $n, [uint32]$p.$n) }
    }
    $s
}
Log (State)
Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ForEach-Object { Log ("  display: {0} {1} {2}" -f $_.Status, $_.InstanceId, $_.FriendlyName) }

Log '-- 1. display driver'
$dst = 'C:\swagent\gpudesk'
# The 16 MB of contiguous memory the driver needs is only there early after boot: when the
# driver is already installed and registered, go straight to the switch.
$ready = (Prop DriverVersion) -eq '0.1.0.202' -and (Test-Path "$dst\app\TegraGpuD3DVk.dll")
if ($ready) { Log '  already installed, switching at once'; Copy-Item (Join-Path $src 'app\*') "$dst\app" -Force } else {
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force "$dst\driver", "$dst\app" | Out-Null
Copy-Item (Join-Path $src 'driver\*') "$dst\driver"
Copy-Item (Join-Path $src 'app\*') "$dst\app"
& (Join-Path $Agent 'wifi\inf2cat\Inf2Cat.exe') /driver:"$dst\driver" /os:10_NI_ARM64 2>&1 | Select-Object -Last 2 | ForEach-Object { Log "  $_" }
if (-not (Test-Path "$dst\driver\tegragpurender.cat")) { Log 'no catalog, stopped'; exit 1 }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Agent 'wifi\wifi_sign.ps1') "$dst\driver\tegragpurender.cat" 2>&1 | ForEach-Object { Log "  $_" }
pnputil /add-driver "$dst\driver\tegragpurender.inf" /install 2>&1 | ForEach-Object { Log "  $_" }
Start-Sleep -Seconds 10
Log (State)
if ((Prop DriverVersion) -ne '0.1.0.202') { Log 'the display driver is not bound, stopped'; exit 1 }
}

Log '-- 2. tgd3d and NVK registration'
$subkey = 'SYSTEM\CurrentControlSet\Control\Class\' + (Prop Driver)
$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subkey, $true)
try {
    [string[]]$slots = @($key.GetValue('UserModeDriverName'))
    Log ("  UserModeDriverName before: " + ($slots -join ' | '))
    if ($slots.Count -ne 4) { Log 'unexpected UMD slots, stopped'; exit 1 }
    $slots[1] = "$dst\app\TegraGpuD3DVk.dll"; $slots[2] = $slots[1]
    $key.SetValue('UserModeDriverName', $slots, [Microsoft.Win32.RegistryValueKind]::MultiString)
    $key.SetValue('VulkanDriverName', "$dst\app\nvk_windows_icd.json", [Microsoft.Win32.RegistryValueKind]::String)
    Log ("  UserModeDriverName now:    " + (@($key.GetValue('UserModeDriverName')) -join ' | '))
} finally { $key.Dispose() }

Log '-- trace'
# ETW session for tgd3d {5f0c4c6e-...} and the kernel driver {c27c1f9b-...}: a preallocated
# circular file (its size is on disk from the start), flushed every second, so a hang keeps all
# but the last second. Read it later with app\tgd3d-trace-export.exe FILE.etl.
$etl = "$dst\trace-$(Get-Date -Format yyyyMMdd-HHmmss).etl"
Get-EtwTraceSession -Name swgpu -ErrorAction SilentlyContinue | Remove-EtwTraceSession -ErrorAction SilentlyContinue
try {
    New-EtwTraceSession -Name swgpu -LogFileMode 0x22 -MaximumFileSize 32 -LocalFilePath $etl -BufferSize 64 `
        -MinimumBuffers 4 -MaximumBuffers 16 -FlushTimer 1 -ClockType Performance | Out-Null
    Add-EtwTraceProvider -Guid '{5f0c4c6e-7a0b-4b52-9d3a-2f6d1e8b4a11}' -SessionName swgpu -Level 5 -MatchAnyKeyword 4294967295 | Out-Null
    Add-EtwTraceProvider -Guid '{c27c1f9b-62e8-4e21-b29b-6bb2d585c6d0}' -SessionName swgpu -Level 5 -MatchAnyKeyword 4294967295 | Out-Null
    Log "  trace session swgpu -> $etl"
} catch { Log "  trace not started: $($_.Exception.Message)" }

Log '-- 3. one-time switch on the running desktop'
$svc = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\tegragpurender', $true)
try {
    $data = [byte[]]::new(4096); $data[0] = 1
    $permit = "$env:windir\System32\drivers\TgGpuBootTest202.bin"
    $f = [IO.FileStream]::new($permit, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try { $f.Write($data, 0, $data.Length); $f.Flush($true) } finally { $f.Dispose() }
    $svc.CreateSubKey('AllowDesktopStart', [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Microsoft.Win32.RegistryOptions]::Volatile).Close()
    Log "  permit armed, restarting the device $(Get-Date -Format s)"
    pnputil /restart-device $id 2>&1 | ForEach-Object { Log "  $_" }
    $limit = (Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 500 } while ((Prop ProblemCode) -ne 0 -and (Get-Date) -lt $limit)
    Log (State)
} finally {
    $svc.DeleteSubKey('AllowDesktopStart', $false); $svc.Dispose()
}
Log "  permit byte now $([IO.File]::ReadAllBytes($permit)[0]) (0 = consumed)"
Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | ForEach-Object { Log ("  display: {0} {1} {2}" -f $_.Status, $_.InstanceId, $_.FriendlyName) }

Log '-- 4. observation (30 s)'
foreach ($i in 1..3) {
    Start-Sleep -Seconds 10
    $dwm = Get-Process dwm -ErrorAction SilentlyContinue
    Log ("  +{0}s: {1}; dwm pid {2}, started {3}" -f ($i * 10), (State).Trim(), ($dwm.Id -join ','), ($dwm.StartTime -join ','))
}
$dwm = Get-Process dwm -ErrorAction SilentlyContinue
if ($dwm) {
    $mods = $dwm | ForEach-Object { $_.Modules } | Where-Object { $_.ModuleName -match 'TegraGpu|vulkan|nouveau|BasicRender|d3d1' } | Select-Object -ExpandProperty ModuleName -Unique
    Log ("  dwm modules: " + ($mods -join ', '))
}
Get-WinEvent -FilterHashtable @{LogName = 'System'; StartTime = (Get-Date).AddMinutes(-3)} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Display|dxgkrnl|Dwm|tegragpu' -or $_.Id -in 4101, 4097 } |
    ForEach-Object { Log ("  event {0} {1} {2}" -f $_.TimeCreated.ToString('s'), $_.ProviderName, $_.Id) }
Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-3); Level = 1, 2} -ErrorAction SilentlyContinue |
    Select-Object -First 10 | ForEach-Object { Log ("  app error {0} {1} {2}: {3}" -f $_.TimeCreated.ToString('s'), $_.ProviderName, $_.Id, (($_.Message -split "`n")[0])) }
Log "==== done $(Get-Date -Format s)"
