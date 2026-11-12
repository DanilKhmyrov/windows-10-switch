# Removes the Windows 10 partition that directly follows the running Windows 11 (C:) and grows
# C: over the freed space plus the free space after it. Run once by w64.cmd when
# agent\remove-win10.flag exists (the agent deletes the flag first).
#   powershell -NoProfile -ExecutionPolicy Bypass -File remove_win10.ps1
# Nothing is changed unless every check passes: the partition starts exactly where C: ends, is a
# 20-30 GB NTFS data partition, is not the boot or system partition and is not C: itself.
$ErrorActionPreference = 'Stop'
$c = Get-Partition -DriveLetter C
$parts = Get-Partition -DiskNumber $c.DiskNumber
"win10 removal: C: disk $($c.DiskNumber) partition $($c.PartitionNumber) offset $($c.Offset) size $($c.Size)"
$parts | ForEach-Object { "  partition $($_.PartitionNumber) offset $($_.Offset) size $($_.Size) type $($_.Type) letter '$($_.DriveLetter)' boot $($_.IsBoot) system $($_.IsSystem)" }
$next = $parts | Where-Object { $_.Offset -eq ($c.Offset + $c.Size) }
if (-not $next) { 'win10 removal: no partition right after C:, nothing changed'; exit 1 }
$fs = (Get-Volume -Partition $next -ErrorAction SilentlyContinue).FileSystem
if ($next.PartitionNumber -eq $c.PartitionNumber -or $next.IsBoot -or $next.IsSystem -or
        $next.DriveLetter -eq 'C' -or $fs -ne 'NTFS' -or $next.Size -lt 20GB -or $next.Size -gt 30GB) {
    "win10 removal: partition $($next.PartitionNumber) ($fs, $($next.Size) bytes) failed the checks, nothing changed"
    exit 1
}
"win10 removal: removing partition $($next.PartitionNumber) ($fs, $($next.Size) bytes)"
Remove-Partition -DiskNumber $c.DiskNumber -PartitionNumber $next.PartitionNumber -Confirm:$false
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
"win10 removal: growing C: from $($c.Size) to $max bytes"
Resize-Partition -DriveLetter C -Size $max
"win10 removal: done, C: is now $((Get-Partition -DriveLetter C).Size) bytes"
