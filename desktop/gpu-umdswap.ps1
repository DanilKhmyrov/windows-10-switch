param([string]$Folder)
$id = 'ACPI\SWOA0F01\0'
$subkey = 'SYSTEM\CurrentControlSet\Control\Class\' + (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Driver).Data
$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subkey, $true)
[string[]]$slots = @($key.GetValue('UserModeDriverName'))
$slots[1] = "$Folder\TegraGpuD3DVk.dll"; $slots[2] = $slots[1]
$key.SetValue('UserModeDriverName', $slots, [Microsoft.Win32.RegistryValueKind]::MultiString); $key.Dispose()
'slots: ' + ($slots -join ' | ')
Get-EtwTraceSession -Name swgpu -ErrorAction SilentlyContinue | Stop-EtwTraceSession -ErrorAction SilentlyContinue | Out-Null
$etl = "C:\swagent\gpudesk\trace-$(Get-Date -Format yyyyMMdd-HHmmss).etl"
New-EtwTraceSession -Name swgpu -LogFileMode 0x22 -MaximumFileSize 32 -LocalFilePath $etl -BufferSize 64 -MinimumBuffers 4 -MaximumBuffers 16 -FlushTimer 1 -ClockType Performance | Out-Null
Add-EtwTraceProvider -Guid '{5f0c4c6e-7a0b-4b52-9d3a-2f6d1e8b4a11}' -SessionName swgpu -Level 5 -MatchAnyKeyword 4294967295 | Out-Null
Add-EtwTraceProvider -Guid '{c27c1f9b-62e8-4e21-b29b-6bb2d585c6d0}' -SessionName swgpu -Level 5 -MatchAnyKeyword 4294967295 | Out-Null
"trace $etl"
$old = (Get-Process dwm).Id
Stop-Process -Name dwm -Force
Start-Sleep -Seconds 8
$d = Get-Process dwm -ErrorAction SilentlyContinue
"dwm old $old new $($d.Id) responding $($d.Responding)"
($d.Modules | Where-Object { $_.FileName -match 'swagent' } | ForEach-Object { $_.FileName }) -join ', '
