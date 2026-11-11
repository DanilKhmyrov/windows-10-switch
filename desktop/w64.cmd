@echo off
rem Windows 10/11 ARM64 on the Switch: settings, drivers and diagnostics. Started by swagent on every
rem boot with the boot partition's drive letter as %1. Logs go to %1:\agent\w64-log.txt.
set LOG=%1:\agent\w64-log.txt
echo ==== BOOT %date% %time% >> %LOG%
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress >> %LOG% 2>&1
reg query HKLM\SYSTEM\Setup /v OOBEInProgress >> %LOG% 2>&1
rem While Windows Setup is running (specialize/OOBE) only log: installing drivers or changing
rem settings here, and above all rebooting, breaks setup (the registry turns read-only during
rem shutdown and setup fails with "could not configure Windows to run on this hardware").
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress 2>nul | find "0x1" >nul && (
  echo -- setup in progress, nothing else to do >> %LOG%
  goto :eof
)
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
call :onedrive
call :wifi %1

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

rem OneDrive off (and per-user settings, see :odkey). The policy only stops syncing; the x86 installer (SysWOW64\OneDriveSetup.exe,
rem emulated, very slow here) still runs at every logon from each user's Run key. So: stop it,
rem disable the installer file, remove the Run entries of every profile and the update tasks.
:onedrive
echo -- onedrive >> %LOG%
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f >> %LOG% 2>&1
taskkill /f /im OneDriveSetup.exe >> %LOG% 2>&1
taskkill /f /im OneDrive.exe >> %LOG% 2>&1
for %%F in (C:\Windows\SysWOW64\OneDriveSetup.exe C:\Windows\System32\OneDriveSetup.exe) do if exist %%F call :odfile %%F
for /f "tokens=*" %%K in ('reg query HKU 2^>nul ^| findstr /r /c:"S-1-5-21-[0-9-]*$"') do call :odkey "%%K"
call :odprofile "C:\Users\Default"
for /d %%P in (C:\Users\*) do call :odprofile "%%P"
for /f "tokens=1 delims=," %%T in ('schtasks /query /fo csv /nh 2^>nul ^| findstr /i onedrive') do schtasks /delete /tn %%T /f >> %LOG% 2>&1
goto :eof

:odfile
takeown /f %1 >> %LOG% 2>&1
icacls %1 /grant *S-1-5-32-544:F >> %LOG% 2>&1
ren %1 OneDriveSetup.exe.off >> %LOG% 2>&1
goto :eof

:odprofile
if not exist "%~1\NTUSER.DAT" goto :eof
reg load HKU\SwProfile "%~1\NTUSER.DAT" >nul 2>&1 || goto :eof
call :odkey HKU\SwProfile
reg unload HKU\SwProfile >nul 2>&1
goto :eof

:odkey
echo   user keys of %~1 >> %LOG%
reg delete "%~1\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f >> %LOG% 2>nul
reg delete "%~1\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDrive /f >> %LOG% 2>nul
rem Touch keyboard button in the taskbar tray ("Always"), as there is no physical keyboard.
reg add "%~1\Software\Microsoft\TabletTip\1.7" /v TipbandDesiredVisibility /t REG_DWORD /d 1 /f >> %LOG% 2>nul
goto :eof

rem Wi-Fi (Windows 11 only; the device ACPI\SWOA0D01 exists only with a Wi-Fi UEFI build).
rem Package on the boot partition in agent\wifi: switchwifi.sys/.inf, the board firmware, the
rem test certificate (wifi.cer, wifi.pfx), wifi_sign.ps1 and Inf2Cat from the WDK (inf2cat\).
rem The catalog is made and signed here, then the package is installed with pnputil once per
rem driver build (marker: the staged copy in C:\swagent\wifi plus installed.ok).
:wifi
if not exist %1:\agent\wifi\switchwifi.inf goto :eof
ver | find "10.0.22" >nul || goto :eof
echo -- wifi >> %LOG%
set WD=C:\swagent\wifi
set FW=C:\Windows\System32\drivers\SwitchWOA
if not exist %FW% mkdir %FW%
copy /y %1:\agent\wifi\brcmfmac4356A3-pcie.bin %FW%\ >> %LOG% 2>&1
copy /y %1:\agent\wifi\brcmfmac4356A3-pcie.txt %FW%\ >> %LOG% 2>&1
if exist %WD%\installed.ok fc /b %1:\agent\wifi\switchwifi.sys %WD%\switchwifi.sys >nul 2>&1 && goto :wifireport
if exist %WD% rmdir /s /q %WD%
mkdir %WD%
copy /y %1:\agent\wifi\switchwifi.inf %WD%\ >> %LOG% 2>&1
copy /y %1:\agent\wifi\switchwifi.sys %WD%\ >> %LOG% 2>&1
certutil -addstore -f Root %1:\agent\wifi\wifi.cer >> %LOG% 2>&1
certutil -addstore -f TrustedPublisher %1:\agent\wifi\wifi.cer >> %LOG% 2>&1
%1:\agent\wifi\inf2cat\Inf2Cat.exe /driver:%WD% /os:10_NI_ARM64 >> %LOG% 2>&1
if not exist %WD%\switchwifi.cat (
  echo -- wifi: no catalog >> %LOG%
  goto :eof
)
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\wifi\wifi_sign.ps1 %WD%\switchwifi.cat %1:\agent\wifi\wifi.pfx >> %LOG% 2>&1 || (
  echo -- wifi: catalog not signed >> %LOG%
  goto :eof
)
pnputil /add-driver %WD%\switchwifi.inf /install >> %LOG% 2>&1
echo pnputil exit %errorlevel% >> %LOG%
if %errorlevel% equ 0 echo ok > %WD%\installed.ok
if %errorlevel% equ 3010 echo ok > %WD%\installed.ok
:wifireport
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWOA0D01" /s >> %LOG% 2>&1
sc query switchwifi >> %LOG% 2>&1
netsh wlan show interfaces >> %LOG% 2>&1
goto :eof
