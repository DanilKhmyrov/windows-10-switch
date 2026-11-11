@echo off
rem Windows 10 ARM64 on the Switch: diagnostics and settings, started by swagent with the CRASHDUMP drive letter as %1.
set LOG=%1:\agent\w64-log.txt
echo ==== BOOT %date% %time% >> %LOG%
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress >> %LOG% 2>&1
reg query HKLM\SYSTEM\Setup /v OOBEInProgress >> %LOG% 2>&1
net user >> %LOG% 2>&1
echo -- power >> %LOG%
powercfg /change monitor-timeout-ac 0 >> %LOG% 2>&1
powercfg /change monitor-timeout-dc 0 >> %LOG% 2>&1
powercfg /change standby-timeout-ac 0 >> %LOG% 2>&1
powercfg /change standby-timeout-dc 0 >> %LOG% 2>&1
powercfg /change disk-timeout-ac 0 >> %LOG% 2>&1
powercfg /change disk-timeout-dc 0 >> %LOG% 2>&1
powercfg /hibernate off >> %LOG% 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /v MaintenanceDisabled /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add HKLM\SYSTEM\CurrentControlSet\Control\CrashControl /v CrashDumpEnabled /t REG_DWORD /d 3 /f >> %LOG% 2>&1
echo -- system >> %LOG%
systeminfo >> %LOG% 2>&1
wmic memorychip get capacity >> %LOG% 2>&1
echo ==== DONE %time% >> %LOG%
