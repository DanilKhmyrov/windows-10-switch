# Starts at logon of user Switch (HKLM Run value SwUwp set by w32.cmd), without admin rights.
# 1) Logs the state of AppX packages to C:\swagent\uwp.txt.
# 2) Once (marker C:\swagent\uwp.done): re-registers all installed packages for this user,
#    the usual fix for a Start menu that opens but does not react.
$log = 'C:\swagent\uwp.txt'
try { Add-Content -Path $log -Value '' -ErrorAction Stop } catch { $log = Join-Path $env:LOCALAPPDATA 'swuwp.txt' }
function Log($text) { Add-Content -Path $log -Value $text -Encoding ASCII }

Log "==== LOGON $(Get-Date -Format s) user=$env:USERNAME"
try {
    $all = Get-AppxPackage
    Log "packages: $($all.Count)"
    foreach ($p in $all) {
        $states = ($p.PackageUserInformation | ForEach-Object { "$($_.UserSecurityId.Username)=$($_.InstallState)" }) -join ','
        Log ("{0} | {1} | {2}" -f $p.Name, $p.Status, $states)
    }
    $mine = Get-AppxPackage
    Log "packages for this user: $($mine.Count)"
    foreach ($name in 'ShellExperienceHost', 'Cortana', 'immersivecontrolpanel', 'AAD.BrokerPlugin') {
        $p = Get-AppxPackage -Name "*$name*"
        Log ("{0}: {1}" -f $name, $(if ($p) { "$($p.Status) $($p.InstallLocation)" } else { 'missing for user' }))
    }
} catch {
    Log "list failed: $_"
}

if (-not (Test-Path 'C:\swagent\uwp.done')) {
    Set-Content -Path 'C:\swagent\uwp.done' -Value 'done'
    Log "-- re-register"
    $manifests = @(Get-AppxPackage | ForEach-Object { Join-Path $_.InstallLocation 'AppxManifest.xml' })
    $manifests += @(Get-ChildItem 'C:\Windows\SystemApps\*\AppxManifest.xml' | ForEach-Object { $_.FullName })
    foreach ($manifest in ($manifests | Sort-Object -Unique)) {
        if (-not (Test-Path $manifest)) { continue }
        $p = @{ Name = Split-Path (Split-Path $manifest) -Leaf }
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            Log "ok $($p.Name)"
        } catch {
            Log "FAIL $($p.Name): $($_.Exception.Message)"
        }
    }
    Log "-- re-register done $(Get-Date -Format s)"
}
