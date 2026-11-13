# Vulkan triangle on the GPU (NVK), shown in a window for 5 minutes. Works while the GPU driver runs
# in native mode (after the agent's gpuvk test, until the next reboot).
$vk = 'C:\swagent\gpuvk'
$env:NVK_I_WANT_A_BROKEN_VULKAN_DRIVER = '1'
$check = & "$vk\nvk-windows-check.exe" "$vk\libvulkan_nouveau.dll" 2>$null | Out-String
if ($check -notmatch '"native_ready_kmd":1') {
    Write-Host 'The GPU driver is not in native mode now (only after the gpuvk test, until a reboot).'
    Read-Host 'Enter to close'; exit 1
}
if ($check -notmatch '"kmt_luid":"([0-9a-f]{16})"') { Write-Host $check; Read-Host 'Enter to close'; exit 1 }
$luid = $Matches[1]
Write-Host "GPU adapter ${luid}: drawing with Vulkan, the window stays for 5 minutes..."
& "$vk\vk-triangle.exe" "$vk\libvulkan_nouveau.dll" $luid --preview
Write-Host "exit code $LASTEXITCODE"
Read-Host 'Enter to close'
