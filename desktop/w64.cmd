@echo off
rem Windows 10 ARM64 on the Switch: settings, drivers and diagnostics. Started by swagent on every
rem boot with the boot partition's drive letter as %1. Logs go to %1:\agent\w64-log.txt.
set LOG=%1:\agent\w64-log.txt
echo ==== BOOT %date% %time% >> %LOG%
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress >> %LOG% 2>&1
reg query HKLM\SYSTEM\Setup /v OOBEInProgress >> %LOG% 2>&1
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

rem ---- Drivers: swhid (touch, ACPI\SWTS0001) and swbatt (battery and fan, ROOT\SWBATT) ----
set REBOOT=
call :update swhid %1
call :update swbatt %1
call :service swhid
call :service swbatt
set EK=HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWTS0001\0
set HG={745a17a0-74d3-11d0-b6fe-00a0c90f57da}
set CK=HKLM\SYSTEM\CurrentControlSet\Control\Class\%HG%\0099
reg query "%EK%" /v Service >nul 2>&1
if errorlevel 1 if exist C:\Windows\System32\drivers\swhid.sys (
  echo -- binding SWTS0001 to swhid >> %LOG%
  reg add "%CK%" /v DriverDesc /t REG_SZ /d "Switch touch panel" /f >> %LOG% 2>&1
  reg add "%CK%" /v ProviderName /t REG_SZ /d "windows-10-switch" /f >> %LOG% 2>&1
  reg add "%CK%" /v DriverVersion /t REG_SZ /d "1.0.0.0" /f >> %LOG% 2>&1
  reg add "%CK%" /v DriverDate /t REG_SZ /d "11-11-2026" /f >> %LOG% 2>&1
  reg add "%CK%" /v MatchingDeviceId /t REG_SZ /d "acpi\swts0001" /f >> %LOG% 2>&1
  reg add "%EK%" /v Service /t REG_SZ /d swhid /f >> %LOG% 2>&1
  reg add "%EK%" /v ClassGUID /t REG_SZ /d %HG% /f >> %LOG% 2>&1
  reg add "%EK%" /v Class /t REG_SZ /d HIDClass /f >> %LOG% 2>&1
  reg add "%EK%" /v Driver /t REG_SZ /d %HG%\0099 /f >> %LOG% 2>&1
  reg add "%EK%" /v Mfg /t REG_SZ /d "windows-10-switch" /f >> %LOG% 2>&1
  reg add "%EK%" /v ConfigFlags /t REG_DWORD /d 0 /f >> %LOG% 2>&1
  set REBOOT=1
)
set BK=HKLM\SYSTEM\CurrentControlSet\Enum\Root\SWBATT\0000
set BG={72631e54-78a4-11d0-bcf7-00aa00b7b32a}
set BC=HKLM\SYSTEM\CurrentControlSet\Control\Class\%BG%\0099
reg query "%BK%" /v Service >nul 2>&1
if errorlevel 1 if exist C:\Windows\System32\drivers\swbatt.sys (
  echo -- creating ROOT\SWBATT >> %LOG%
  reg add "%BC%" /v DriverDesc /t REG_SZ /d "Switch battery" /f >> %LOG% 2>&1
  reg add "%BC%" /v ProviderName /t REG_SZ /d "windows-10-switch" /f >> %LOG% 2>&1
  reg add "%BC%" /v DriverVersion /t REG_SZ /d "1.0.0.0" /f >> %LOG% 2>&1
  reg add "%BC%" /v DriverDate /t REG_SZ /d "11-11-2026" /f >> %LOG% 2>&1
  reg add "%BC%" /v MatchingDeviceId /t REG_SZ /d "root\swbatt" /f >> %LOG% 2>&1
  reg add "%BK%" /v HardwareID /t REG_MULTI_SZ /d "ROOT\SWBATT" /f >> %LOG% 2>&1
  reg add "%BK%" /v DeviceDesc /t REG_SZ /d "Switch battery" /f >> %LOG% 2>&1
  reg add "%BK%" /v Mfg /t REG_SZ /d "windows-10-switch" /f >> %LOG% 2>&1
  reg add "%BK%" /v Class /t REG_SZ /d Battery /f >> %LOG% 2>&1
  reg add "%BK%" /v ClassGUID /t REG_SZ /d %BG% /f >> %LOG% 2>&1
  reg add "%BK%" /v Driver /t REG_SZ /d %BG%\0099 /f >> %LOG% 2>&1
  reg add "%BK%" /v ConfigFlags /t REG_DWORD /d 0 /f >> %LOG% 2>&1
  reg add "%BK%" /v Service /t REG_SZ /d swbatt /f >> %LOG% 2>&1
  set REBOOT=1
)
sc config TabletInputService start= auto >> %LOG% 2>&1
sc start TabletInputService >nul 2>&1
if defined REBOOT (
  echo ==== DRIVERS INSTALLED, rebooting %time% >> %LOG%
  shutdown /r /t 20 /f >> %LOG% 2>&1
  goto :eof
)
echo -- drivers >> %LOG%
sc query swhid >> %LOG% 2>&1
sc query swbatt >> %LOG% 2>&1
reg query HKLM\SYSTEM\CurrentControlSet\Enum\HID /s /f SWTS >> %LOG% 2>&1
copy /y C:\swagent\bat.txt %1:\agent\bat64.txt >nul 2>&1
powercfg /batteryreport /output %1:\agent\battery64.html >> %LOG% 2>&1
echo -- system >> %LOG%
wmic cpu get NumberOfLogicalProcessors,CurrentClockSpeed >> %LOG% 2>&1
wmic OS get FreePhysicalMemory,TotalVisibleMemorySize >> %LOG% 2>&1
echo ==== DONE %time% >> %LOG%
goto :eof

rem Creates the kernel service for driver %1 if it does not exist yet.
:service
reg query HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath >nul 2>&1 && goto :eof
if not exist C:\Windows\System32\drivers\%1.sys goto :eof
echo -- creating service %1 >> %LOG%
reg add HKLM\SYSTEM\CurrentControlSet\Services\%1 /v Type /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add HKLM\SYSTEM\CurrentControlSet\Services\%1 /v Start /t REG_DWORD /d 3 /f >> %LOG% 2>&1
reg add HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ErrorControl /t REG_DWORD /d 0 /f >> %LOG% 2>&1
reg add HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath /t REG_EXPAND_SZ /d \SystemRoot\System32\drivers\%1.sys /f >> %LOG% 2>&1
set REBOOT=1
goto :eof

rem Installs or updates driver %1 from %2:\agent\arm64\%1.sys when that file differs from the installed one.
rem A loaded driver file cannot be overwritten, so versions alternate between %1.sys and %1_b.sys.
:update
if not exist %2:\agent\arm64\%1.sys goto :eof
set CURF=%1.sys
set NEWF=%1.sys
reg query HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath >nul 2>&1 || goto :copy
set NEWF=%1_b.sys
reg query HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath | find /i "%1_b.sys" >nul && (set CURF=%1_b.sys& set NEWF=%1.sys)
fc /b %2:\agent\arm64\%1.sys C:\Windows\System32\drivers\%CURF% >nul 2>&1 && goto :eof
:copy
echo -- installing %1 as %NEWF% >> %LOG%
copy /y %2:\agent\arm64\%1.sys C:\Windows\System32\drivers\%NEWF% >> %LOG% 2>&1
reg query HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath >nul 2>&1 && (
  reg add HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath /t REG_EXPAND_SZ /d \SystemRoot\System32\drivers\%NEWF% /f >> %LOG% 2>&1
  set REBOOT=1
)
goto :eof
