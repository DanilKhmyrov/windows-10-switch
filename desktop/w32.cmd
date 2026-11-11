@echo off
rem Started by swagent on every boot with the CRASHDUMP drive letter as %1.
rem First boot after OOBE: creates user Switch (empty password), enables autologon, reboots.
rem Every boot: writes diagnostics to %1:\agent\w32-log.txt.
set LOG=%1:\agent\w32-log.txt
set WL=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
echo ==== BOOT %date% %time% >> %LOG%
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress >> %LOG% 2>&1
reg query HKLM\SYSTEM\Setup /v OOBEInProgress >> %LOG% 2>&1
net user >> %LOG% 2>&1
if not exist C:\swagent\user2.done (
  net user Switch "" /add >> %LOG% 2>&1
  net user Switch /active:yes >> %LOG% 2>&1
  net localgroup Administrators Switch /add >> %LOG% 2>&1
  wmic useraccount where name='Switch' set PasswordExpires=false >> %LOG% 2>&1
  reg add "%WL%" /v AutoAdminLogon /t REG_SZ /d 1 /f >> %LOG% 2>&1
  reg add "%WL%" /v DefaultUserName /t REG_SZ /d Switch /f >> %LOG% 2>&1
  reg add "%WL%" /v DefaultPassword /t REG_SZ /d "" /f >> %LOG% 2>&1
  reg add "%WL%" /v DefaultDomainName /t REG_SZ /d "%COMPUTERNAME%" /f >> %LOG% 2>&1
  reg delete "%WL%" /v AutoLogonCount /f >> %LOG% 2>&1
  net user >> %LOG% 2>&1
  reg query "%WL%" >> %LOG% 2>&1
  echo done > C:\swagent\user2.done
  echo ==== USER DONE, rebooting %time% >> %LOG%
  shutdown /r /t 20 /f >> %LOG% 2>&1
)
set EK=HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWTS0001\0
set HG={745a17a0-74d3-11d0-b6fe-00a0c90f57da}
set CK=HKLM\SYSTEM\CurrentControlSet\Control\Class\%HG%\0099
reg query "%EK%" /v Service >nul 2>&1
if errorlevel 1 (
  echo -- binding SWTS0001 to swhid >> %LOG%
  reg add "%CK%" /v DriverDesc /t REG_SZ /d "Switch touch panel" /f >> %LOG% 2>&1
  reg add "%CK%" /v ProviderName /t REG_SZ /d "switch-wp" /f >> %LOG% 2>&1
  reg add "%CK%" /v DriverVersion /t REG_SZ /d "1.0.0.0" /f >> %LOG% 2>&1
  reg add "%CK%" /v DriverDate /t REG_SZ /d "11-9-2026" /f >> %LOG% 2>&1
  reg add "%CK%" /v MatchingDeviceId /t REG_SZ /d "acpi\swts0001" /f >> %LOG% 2>&1
  reg add "%EK%" /v Service /t REG_SZ /d swhid /f >> %LOG% 2>&1
  reg add "%EK%" /v ClassGUID /t REG_SZ /d %HG% /f >> %LOG% 2>&1
  reg add "%EK%" /v Driver /t REG_SZ /d %HG%\0099 /f >> %LOG% 2>&1
  reg add "%EK%" /v Mfg /t REG_SZ /d "switch-wp" /f >> %LOG% 2>&1
  reg add "%EK%" /v ConfigFlags /t REG_DWORD /d 0 /f >> %LOG% 2>&1
  reg query "%EK%" >> %LOG% 2>&1
  echo ==== TOUCH BOUND, rebooting %time% >> %LOG%
  shutdown /r /t 20 /f >> %LOG% 2>&1
)
echo -- power and background tasks >> %LOG%
powercfg /change monitor-timeout-ac 0 >> %LOG% 2>&1
powercfg /change monitor-timeout-dc 0 >> %LOG% 2>&1
powercfg /change standby-timeout-ac 0 >> %LOG% 2>&1
powercfg /change standby-timeout-dc 0 >> %LOG% 2>&1
powercfg /change disk-timeout-ac 0 >> %LOG% 2>&1
powercfg /change disk-timeout-dc 0 >> %LOG% 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\PNP0D40\0\Device Parameters\WDF" /v IdleInWorkingState /t REG_DWORD /d 0 /f >> %LOG% 2>&1
for /f "delims=" %%k in ('reg query HKLM\SYSTEM\CurrentControlSet\Enum\SD /s /k /f "Device Parameters" ^| find "Device Parameters"') do reg add "%%k\Storport" /v EnableIdlePowerManagement /t REG_DWORD /d 0 /f >> %LOG% 2>&1
powercfg /query SCHEME_CURRENT SUB_DISK >> %LOG% 2>&1
powercfg /hibernate off >> %LOG% 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" /v MaintenanceDisabled /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f >> %LOG% 2>&1
sc config WSearch start= disabled >> %LOG% 2>&1
sc stop WSearch >> %LOG% 2>&1
sc config SysMain start= disabled >> %LOG% 2>&1
sc stop SysMain >> %LOG% 2>&1
schtasks /Change /TN "\Microsoft\Windows\Defrag\ScheduledDefrag" /Disable >> %LOG% 2>&1
reg add HKLM\SYSTEM\CurrentControlSet\Control\CrashControl /v CrashDumpEnabled /t REG_DWORD /d 3 /f >> %LOG% 2>&1
powercfg /query SCHEME_CURRENT SUB_VIDEO >> %LOG% 2>&1
echo -- battery >> %LOG%
set BK=HKLM\SYSTEM\CurrentControlSet\Enum\Root\SWBATT\0000
set BG={72631e54-78a4-11d0-bcf7-00aa00b7b32a}
set BC=HKLM\SYSTEM\CurrentControlSet\Control\Class\%BG%\0099
if not exist C:\Windows\System32\drivers\swbatt.sys copy /y %1:\agent\swbatt.sys C:\Windows\System32\drivers\swbatt.sys >> %LOG% 2>&1
call :update swbatt %1
call :update swhid %1
reg query "%BK%" /v Service >nul 2>&1
if errorlevel 1 (
  echo -- creating ROOT\SWBATT >> %LOG%
  reg add HKLM\SYSTEM\CurrentControlSet\Services\swbatt /v Type /t REG_DWORD /d 1 /f >> %LOG% 2>&1
  reg add HKLM\SYSTEM\CurrentControlSet\Services\swbatt /v Start /t REG_DWORD /d 3 /f >> %LOG% 2>&1
  reg add HKLM\SYSTEM\CurrentControlSet\Services\swbatt /v ErrorControl /t REG_DWORD /d 0 /f >> %LOG% 2>&1
  reg add HKLM\SYSTEM\CurrentControlSet\Services\swbatt /v ImagePath /t REG_EXPAND_SZ /d \SystemRoot\System32\drivers\swbatt.sys /f >> %LOG% 2>&1
  reg add "%BC%" /v DriverDesc /t REG_SZ /d "Switch battery" /f >> %LOG% 2>&1
  reg add "%BC%" /v ProviderName /t REG_SZ /d "switch-wp" /f >> %LOG% 2>&1
  reg add "%BC%" /v DriverVersion /t REG_SZ /d "1.0.0.0" /f >> %LOG% 2>&1
  reg add "%BC%" /v DriverDate /t REG_SZ /d "11-10-2026" /f >> %LOG% 2>&1
  reg add "%BC%" /v MatchingDeviceId /t REG_SZ /d "root\swbatt" /f >> %LOG% 2>&1
  reg add "%BK%" /v HardwareID /t REG_MULTI_SZ /d "ROOT\SWBATT" /f >> %LOG% 2>&1
  reg add "%BK%" /v DeviceDesc /t REG_SZ /d "Switch battery" /f >> %LOG% 2>&1
  reg add "%BK%" /v Mfg /t REG_SZ /d "switch-wp" /f >> %LOG% 2>&1
  reg add "%BK%" /v Class /t REG_SZ /d Battery /f >> %LOG% 2>&1
  reg add "%BK%" /v ClassGUID /t REG_SZ /d %BG% /f >> %LOG% 2>&1
  reg add "%BK%" /v Driver /t REG_SZ /d %BG%\0099 /f >> %LOG% 2>&1
  reg add "%BK%" /v ConfigFlags /t REG_DWORD /d 0 /f >> %LOG% 2>&1
  reg add "%BK%" /v Service /t REG_SZ /d swbatt /f >> %LOG% 2>&1
  reg query "%BK%" >> %LOG% 2>&1
  echo ==== BATTERY ADDED, rebooting %time% >> %LOG%
  shutdown /r /t 20 /f >> %LOG% 2>&1
)
sc query swbatt >> %LOG% 2>&1
powercfg /batteryreport /output %1:\agent\battery.html >> %LOG% 2>&1
echo -- uwp >> %LOG%
copy /y %1:\agent\uwp.ps1 C:\swagent\uwp.ps1 >> %LOG% 2>&1
icacls C:\swagent /grant *S-1-5-32-545:(OI)(CI)M >> %LOG% 2>&1
schtasks /delete /tn SwUwp /f >nul 2>&1
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v SwUwp /t REG_SZ /d "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\swagent\uwp.ps1" /f >> %LOG% 2>&1
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v SwRunTest /t REG_SZ /d "cmd /c echo %%USERNAME%% %%DATE%% %%TIME%% >> C:\swagent\runtest.txt" /f >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$PSVersionTable.PSVersion; Get-AppxPackage -AllUsers | Format-Table Name,Status,@{n='Users';e={($_.PackageUserInformation | %%{ $_.UserSecurityId.Username + '=' + $_.InstallState }) -join ','}} -AutoSize | Out-String -Width 300" > C:\swagent\uwp-system.txt 2>&1
echo -- fresh profile >> %LOG%
if not exist C:\swagent\player.done (
  net user Player "" /add >> %LOG% 2>&1
  net user Player /active:yes >> %LOG% 2>&1
  net localgroup Administrators Player /add >> %LOG% 2>&1
  wmic useraccount where name='Player' set PasswordExpires=false >> %LOG% 2>&1
  reg add "%WL%" /v AutoAdminLogon /t REG_SZ /d 1 /f >> %LOG% 2>&1
  reg add "%WL%" /v DefaultUserName /t REG_SZ /d Player /f >> %LOG% 2>&1
  reg add "%WL%" /v DefaultPassword /t REG_SZ /d "" /f >> %LOG% 2>&1
  echo done > C:\swagent\player.done
  echo ==== PLAYER CREATED, rebooting %time% >> %LOG%
  shutdown /r /t 20 /f >> %LOG% 2>&1
)
echo -- touch >> %LOG%
sc config TabletInputService start= auto >> %LOG% 2>&1
sc start TabletInputService >> %LOG% 2>&1
sc query TabletInputService >> %LOG% 2>&1
set "HK=HKLM\SYSTEM\CurrentControlSet\Enum\HID\SWTS0001\3&f3d4b3f&0&0000"
reg query "%HK%" >> %LOG% 2>&1
if not exist C:\swagent\touch2.done (
  echo -- reinstalling HID touch child >> %LOG%
  reg add "%HK%" /v ConfigFlags /t REG_DWORD /d 0x20 /f >> %LOG% 2>&1
  echo done > C:\swagent\touch2.done
  echo ==== TOUCH CHILD REINSTALL, rebooting %time% >> %LOG%
  shutdown /r /t 20 /f >> %LOG% 2>&1
)
sc query swhid >> %LOG% 2>&1
sc qc swhid >> %LOG% 2>&1
reg query HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWTS0001\0 >> %LOG% 2>&1
reg query HKLM\SYSTEM\CurrentControlSet\Enum\HID /s /f SWTS >> %LOG% 2>&1
driverquery | find /i "hid" >> %LOG% 2>&1
echo ==== DONE %time% >> %LOG%
goto :eof

rem Replaces driver %1 with %2:\agent\%1.sys when that file differs from the installed one.
rem A loaded driver file cannot be overwritten, so versions alternate between %1.sys and %1_b.sys.
:update
reg query HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath >nul 2>&1 || goto :eof
if not exist %2:\agent\%1.sys goto :eof
set CURF=%1.sys
set NEWF=%1_b.sys
reg query HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath | find /i "%1_b.sys" >nul && (set CURF=%1_b.sys& set NEWF=%1.sys)
fc /b %2:\agent\%1.sys C:\Windows\System32\drivers\%CURF% >nul 2>&1 && goto :eof
echo -- updating %1: %CURF% to %NEWF% >> %LOG%
copy /y %2:\agent\%1.sys C:\Windows\System32\drivers\%NEWF% >> %LOG% 2>&1
reg add HKLM\SYSTEM\CurrentControlSet\Services\%1 /v ImagePath /t REG_EXPAND_SZ /d \SystemRoot\System32\drivers\%NEWF% /f >> %LOG% 2>&1
echo ==== %1 UPDATED, rebooting %time% >> %LOG%
shutdown /r /t 20 /f >> %LOG% 2>&1
goto :eof
