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
rem Settings that only need to be applied once per agent version: skipped while this w64.cmd
rem equals the copy saved after the last full run. The agent used to spend minutes on every boot
rem here (PowerShell is slow on this CPU and SD card) while the user was already working.
set ONCE=1
if exist C:\swagent\w64-applied.cmd fc /b %~f0 C:\swagent\w64-applied.cmd >nul 2>&1 && set ONCE=
if not defined ONCE (
  echo -- settings unchanged since the last full run, skipped >> %LOG%
  goto :afteronce
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
rem Passwords never expire: once Wi-Fi syncs the clock (2022 -> today), the empty password of
rem Player set during setup would count as years old and Windows would force a change.
net accounts /maxpwage:unlimited >> %LOG% 2>&1
powershell -NoProfile -Command "Get-LocalUser | Where-Object Enabled | Set-LocalUser -PasswordNeverExpires $true" >> %LOG% 2>&1
call :crashdumps %1
call :onedrive
call :noupdate
call :defender %1
copy /y %~f0 C:\swagent\w64-applied.cmd >nul 2>&1
:afteronce
call :removewin10 %1
call :dumpcopy %1
call :ssh %1
set WIFIREBOOT=
call :wifi %1
call :bt %1
call :audio %1
call :gpu %1

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
if defined WIFIREBOOT set REBOOT=1
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
call :gpureport
call :perf %1
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
rem Package on the boot partition in agent\wifi: switchwifi.sys/.inf, the board firmware,
rem wifi_sign.ps1 and Inf2Cat from the WDK (inf2cat\). The catalog is made here and signed with
rem test certificates the console makes for itself (wifi_sign.ps1), then the package is installed
rem with pnputil once per driver build (marker: the staged copy in C:\swagent\wifi plus
rem installed-local.ok).
:wifi
if not exist %1:\agent\wifi\switchwifi.inf goto :eof
ver | find "10.0.22" >nul || goto :eof
echo -- wifi >> %LOG%
set WD=C:\swagent\wifi
set FW=C:\Windows\System32\drivers\SwitchWOA
if not exist %FW% mkdir %FW%
copy /y %1:\agent\wifi\brcmfmac4356A3-pcie.bin %FW%\ >> %LOG% 2>&1
copy /y %1:\agent\wifi\brcmfmac4356A3-pcie.txt %FW%\ >> %LOG% 2>&1
if exist %WD%\installed-local.ok fc /b %1:\agent\wifi\switchwifi.sys %WD%\switchwifi.sys >nul 2>&1 && goto :wifireport
if exist %WD% rmdir /s /q %WD%
mkdir %WD%
copy /y %1:\agent\wifi\switchwifi.inf %WD%\ >> %LOG% 2>&1
copy /y %1:\agent\wifi\switchwifi.sys %WD%\ >> %LOG% 2>&1
rem Certificates of the first test builds (made on the Mac) are no longer trusted.
certutil -delstore Root "Switch Windows Test Root" >> %LOG% 2>&1
certutil -delstore Root "Switch Windows Test Driver" >> %LOG% 2>&1
certutil -delstore TrustedPublisher "Switch Windows Test Driver" >> %LOG% 2>&1
%1:\agent\wifi\inf2cat\Inf2Cat.exe /driver:%WD% /os:10_NI_ARM64 >> %LOG% 2>&1
if not exist %WD%\switchwifi.cat (
  echo -- wifi: no catalog >> %LOG%
  goto :wifireport
)
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\wifi\wifi_sign.ps1 %WD%\switchwifi.cat >> %LOG% 2>&1 || (
  echo -- wifi: catalog not signed >> %LOG%
  goto :wifireport
)
pnputil /add-driver %WD%\switchwifi.inf /install >> %LOG% 2>&1
echo pnputil exit %errorlevel% >> %LOG%
if %errorlevel% equ 0 echo ok > %WD%\installed-local.ok
if %errorlevel% equ 3010 echo ok > %WD%\installed-local.ok
rem Reboot once after a new driver: Windows restarts the device in place, and a stopped
rem BCM4356 needs the fresh preparation that UEFI does at boot (scan works, joining fails).
if exist %WD%\installed-local.ok set WIFIREBOOT=1
:wifireport
if exist %1:\agent\wifi\wifi_clean.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\wifi\wifi_clean.ps1 >> %LOG% 2>&1
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWOA0D01" /s >> %LOG% 2>&1
sc query switchwifi >> %LOG% 2>&1
pnputil /enum-devices /instanceid "ACPI\SWOA0D01\0" /drivers >> %LOG% 2>&1
netsh wlan show interfaces >> %LOG% 2>&1
goto :eof

rem Bluetooth (Windows 11 only; ACPI\SWOA0B01 from the Windows 11 UEFI). Package in agent\bt:
rem switchbt.sys/.inf and the Broadcom patch BCM4356A3.hcd. Catalog and signing as for Wi-Fi
rem (Inf2Cat from agent\wifi\inf2cat, wifi_sign.ps1); installed once per driver build.
:bt
if not exist %1:\agent\bt\switchbt.inf goto :eof
if not exist %1:\agent\wifi\inf2cat\Inf2Cat.exe goto :eof
ver | find "10.0.22" >nul || goto :eof
echo -- bluetooth >> %LOG%
set BD=C:\swagent\bt
set FW=C:\Windows\System32\drivers\SwitchWOA
if not exist %FW% mkdir %FW%
copy /y %1:\agent\bt\BCM4356A3.hcd %FW%\ >> %LOG% 2>&1
if exist %BD%\installed-local.ok fc /b %1:\agent\bt\switchbt.sys %BD%\switchbt.sys >nul 2>&1 && goto :btreport
if exist %BD% rmdir /s /q %BD%
mkdir %BD%
copy /y %1:\agent\bt\switchbt.inf %BD%\ >> %LOG% 2>&1
copy /y %1:\agent\bt\switchbt.sys %BD%\ >> %LOG% 2>&1
%1:\agent\wifi\inf2cat\Inf2Cat.exe /driver:%BD% /os:10_NI_ARM64 >> %LOG% 2>&1
if not exist %BD%\switchbt.cat (
  echo -- bluetooth: no catalog >> %LOG%
  goto :btreport
)
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\wifi\wifi_sign.ps1 %BD%\switchbt.cat >> %LOG% 2>&1 || (
  echo -- bluetooth: catalog not signed >> %LOG%
  goto :btreport
)
pnputil /add-driver %BD%\switchbt.inf /install >> %LOG% 2>&1
echo pnputil exit %errorlevel% >> %LOG%
if %errorlevel% equ 0 echo ok > %BD%\installed-local.ok
if %errorlevel% equ 3010 echo ok > %BD%\installed-local.ok
:btreport
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWOA0B01" /s >> %LOG% 2>&1
reg query HKLM\SYSTEM\CurrentControlSet\Services\switchbt\Parameters >> %LOG% 2>&1
sc query switchbt >> %LOG% 2>&1
sc query bthserv >> %LOG% 2>&1
goto :eof

rem Audio (Windows 11 only; ACPI\SWOA0C01 from the Windows 11 UEFI). Package in agent\audio:
rem switchaudio.sys/.inf. Catalog and signing as for Wi-Fi; installed once per driver build.
:audio
if not exist %1:\agent\audio\switchaudio.inf goto :eof
if not exist %1:\agent\wifi\inf2cat\Inf2Cat.exe goto :eof
ver | find "10.0.22" >nul || goto :eof
echo -- audio >> %LOG%
set AD=C:\swagent\audio
if exist %AD%\installed-local.ok fc /b %1:\agent\audio\switchaudio.sys %AD%\switchaudio.sys >nul 2>&1 && goto :audioreport
if exist %AD% rmdir /s /q %AD%
mkdir %AD%
copy /y %1:\agent\audio\switchaudio.inf %AD%\ >> %LOG% 2>&1
copy /y %1:\agent\audio\switchaudio.sys %AD%\ >> %LOG% 2>&1
%1:\agent\wifi\inf2cat\Inf2Cat.exe /driver:%AD% /os:10_NI_ARM64 >> %LOG% 2>&1
if not exist %AD%\switchaudio.cat (
  echo -- audio: no catalog >> %LOG%
  goto :audioreport
)
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\wifi\wifi_sign.ps1 %AD%\switchaudio.cat >> %LOG% 2>&1 || (
  echo -- audio: catalog not signed >> %LOG%
  goto :audioreport
)
pnputil /add-driver %AD%\switchaudio.inf /install >> %LOG% 2>&1
echo pnputil exit %errorlevel% >> %LOG%
if %errorlevel% equ 0 echo ok > %AD%\installed-local.ok
if %errorlevel% equ 3010 echo ok > %AD%\installed-local.ok
:audioreport
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWOA0C01" /s >> %LOG% 2>&1
reg query HKLM\SYSTEM\CurrentControlSet\Services\switchaudio\Parameters >> %LOG% 2>&1
sc query switchaudio >> %LOG% 2>&1
goto :eof

rem Experimental GPU (Windows 11 only; ACPI\SWOA0F01 from the GPU test loader): the GM20B render
rem driver of mesa-switch-woa from agent\gpu (tegragpurender.sys/.inf, tegragpuno3d.dll and the
rem NVIDIA tegra21x firmware). Catalog and signing as for Wi-Fi; installed once per driver build.
:gpu
if not exist %1:\agent\gpu\tegragpurender.inf goto :eof
if not exist %1:\agent\wifi\inf2cat\Inf2Cat.exe goto :eof
ver | find "10.0.22" >nul || goto :eof
echo -- gpu >> %LOG%
set GD=C:\swagent\gpu
if exist %GD%\installed-local.ok fc /b %1:\agent\gpu\tegragpurender.sys %GD%\tegragpurender.sys >nul 2>&1 && goto :eof
if exist %GD% rmdir /s /q %GD%
mkdir %GD%
copy /y %1:\agent\gpu\*.* %GD%\ >> %LOG% 2>&1
%1:\agent\wifi\inf2cat\Inf2Cat.exe /driver:%GD% /os:10_NI_ARM64 >> %LOG% 2>&1
if not exist %GD%\tegragpurender.cat (
  echo -- gpu: no catalog >> %LOG%
  goto :eof
)
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\wifi\wifi_sign.ps1 %GD%\tegragpurender.cat >> %LOG% 2>&1 || (
  echo -- gpu: catalog not signed >> %LOG%
  goto :eof
)
pnputil /add-driver %GD%\tegragpurender.inf /install >> %LOG% 2>&1
echo pnputil exit %errorlevel% >> %LOG%
if %errorlevel% equ 0 echo ok > %GD%\installed-local.ok
if %errorlevel% equ 3010 echo ok > %GD%\installed-local.ok
goto :eof

rem The GPU driver needs swbatt's power bridge, which may start after it at boot: restart the
rem device once from here, then log its state and the driver's own status values.
:gpureport
reg query "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\SWOA0F01" >nul 2>&1 || goto :eof
rem Only with the GPU test loader: the device is not present under the regular one.
powershell -NoProfile -Command "if (Get-PnpDevice -PresentOnly -InstanceId 'ACPI\SWOA0F01\0' -ErrorAction SilentlyContinue) { 'present' }" | find "present" >nul || goto :eof
echo -- gpu state >> %LOG%
pnputil /enum-devices /instanceid "ACPI\SWOA0F01\0" /drivers >> %LOG% 2>&1
rem Get-PnpDevice reports OK/Error/Unknown in English on every display language.
powershell -NoProfile -Command "(Get-PnpDevice -InstanceId 'ACPI\SWOA0F01\0').Status" | find "OK" >nul || (
  echo -- gpu: restarting the device >> %LOG%
  pnputil /restart-device "ACPI\SWOA0F01\0" >> %LOG% 2>&1
  timeout /t 15 /nobreak >nul
  pnputil /enum-devices /instanceid "ACPI\SWOA0F01\0" /drivers >> %LOG% 2>&1
)
reg query HKLM\SYSTEM\CurrentControlSet\Services\tegragpurender\Parameters >> %LOG% 2>&1
goto :eof

rem One-time removal of the Windows 10 partition right after C:, which then takes its space.
rem Only on Windows 11 and only when agent\remove-win10.flag exists; the flag goes first.
:removewin10
if not exist %1:\agent\remove-win10.flag goto :eof
ver | find "10.0.22" >nul || goto :eof
del %1:\agent\remove-win10.flag
echo -- remove windows 10 >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\remove_win10.ps1 >> %LOG% 2>&1
goto :eof

rem Crash dumps of user-mode programs (Windows Error Reporting LocalDumps): minidumps in
rem C:\swagent\dumps, at most 10; those not yet on the card are copied to agent\dumps.
:crashdumps
set LD=HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps
reg add "%LD%" /v DumpFolder /t REG_EXPAND_SZ /d C:\swagent\dumps /f >nul 2>&1
reg add "%LD%" /v DumpType /t REG_DWORD /d 1 /f >nul 2>&1
reg add "%LD%" /v DumpCount /t REG_DWORD /d 10 /f >nul 2>&1
goto :eof

:dumpcopy
if not exist C:\swagent\dumps goto :eof
if not exist %1:\agent\dumps mkdir %1:\agent\dumps
echo -- crash dumps >> %LOG%
for %%F in (C:\swagent\dumps\*.dmp) do if not exist "%1:\agent\dumps\%%~nxF" (
  echo %%~nxF >> %LOG%
  copy /y "%%F" %1:\agent\dumps\ >nul 2>&1
)
goto :eof

rem One-time performance measurement when agent\perf.flag exists (the flag goes first): the
rem last boot times recorded by Windows, then WinSAT disk (sequential and random 4 KB reads of C:),
rem CPU and memory. Results go to the log and to agent\perf.txt.
:perf
if not exist %1:\agent\perf.flag goto :eof
del %1:\agent\perf.flag
echo -- perf >> %LOG%
set PF=%1:\agent\perf.txt
echo ==== perf %date% %time% >> %PF%
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100} -MaxEvents 5 -ErrorAction SilentlyContinue | ForEach-Object { $x=[xml]$_.ToXml(); $d=@{}; $x.Event.EventData.Data | ForEach-Object { $d[$_.Name]=$_.'#text' }; 'boot ' + $_.TimeCreated + ' total_ms=' + $d.BootTime + ' mainpath_ms=' + $d.MainPathBootTime + ' postboot_ms=' + $d.BootPostBootTime }" >> %PF% 2>&1
powershell -NoProfile -Command "$b=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime; 'boot started ' + $b + ', agent at ' + (Get-Date) + ' = ' + [int]((Get-Date)-$b).TotalSeconds + ' s'" >> %PF% 2>&1
rem SD read speed on the recovery image, which nothing reads during a normal boot (not cached):
rem 128 MB sequentially in 1 MB blocks, then 2000 random 4 KB reads further into the file.
powershell -NoProfile -Command "$f='C:\Windows\System32\Recovery\winre.wim'; $s=[IO.File]::Open($f,'Open','Read','ReadWrite'); $buf=New-Object byte[] 1MB; $t=[Diagnostics.Stopwatch]::StartNew(); for($i=0;$i -lt 128;$i++){ [void]$s.Read($buf,0,1MB) }; $t.Stop(); 'sequential read: ' + [math]::Round(128/$t.Elapsed.TotalSeconds,1) + ' MB/s'; $r=New-Object Random 7; $b4=New-Object byte[] 4096; $t=[Diagnostics.Stopwatch]::StartNew(); for($i=0;$i -lt 2000;$i++){ $s.Position=(200MB + [long]($r.Next(0,100000))*4096); [void]$s.Read($b4,0,4096) }; $t.Stop(); 'random 4 KB reads: ' + [math]::Round(2000/$t.Elapsed.TotalSeconds) + ' per second (' + [math]::Round(8/$t.Elapsed.TotalSeconds,2) + ' MB/s)'; $s.Close()" >> %PF% 2>&1
echo ==== perf done %time% >> %PF%
type %PF% >> %LOG%
goto :eof

rem Microsoft Defender off, only when agent\defender-off.flag exists (on the SD card and this CPU
rem its real-time scans and 220 MB signature downloads slow everything down). Policies,
rem preferences and its scheduled tasks. Windows ignores these while Tamper Protection is on: that
rem switch can only be turned off by hand in Windows Security. Leftover signature installers and
rem kernel live dumps are deleted either way.
:defender
del /q C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Temp\mpam-*.exe >nul 2>&1
del /q C:\Windows\LiveKernelReports\*.dmp >nul 2>&1
if not exist %1:\agent\defender-off.flag goto :eof
echo -- defender off >> %LOG%
set DEF=HKLM\SOFTWARE\Policies\Microsoft\Windows Defender
reg add "%DEF%" /v DisableAntiSpyware /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%DEF%\Real-Time Protection" /v DisableRealtimeMonitoring /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%DEF%\Real-Time Protection" /v DisableBehaviorMonitoring /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%DEF%\Real-Time Protection" /v DisableOnAccessProtection /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%DEF%\Real-Time Protection" /v DisableScanOnRealtimeEnable /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%DEF%\Real-Time Protection" /v DisableIOAVProtection /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%DEF%\Spynet" /v SpynetReporting /t REG_DWORD /d 0 /f >> %LOG% 2>&1
reg add "%DEF%\Spynet" /v SubmitSamplesConsent /t REG_DWORD /d 2 /f >> %LOG% 2>&1
reg add "%DEF%\Signature Updates" /v UpdateOnStartUp /t REG_DWORD /d 0 /f >> %LOG% 2>&1
reg add "%DEF%\Signature Updates" /v ScheduleDay /t REG_DWORD /d 8 /f >> %LOG% 2>&1
reg add "%DEF%\Scan" /v ScheduleDay /t REG_DWORD /d 8 /f >> %LOG% 2>&1
powershell -NoProfile -Command "Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true -DisableIOAVProtection $true -MAPSReporting 0 -SubmitSamplesConsent 2 -SignatureScheduleDay 8 -ScanScheduleDay 8 -ErrorAction SilentlyContinue; Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null; $s=Get-MpComputerStatus -ErrorAction SilentlyContinue; 'defender: tamper protection ' + $s.IsTamperProtected + ', real-time ' + $s.RealTimeProtectionEnabled" >> %LOG% 2>&1
del /q C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Temp\mpam-*.exe >nul 2>&1
del /q C:\Windows\LiveKernelReports\*.dmp >nul 2>&1
goto :eof

rem OpenSSH server (Windows 11) from agent\ssh, by ssh_setup.ps1: key login from the Mac only.
rem The network address is written to agent\ip.txt about 90 s later, once Wi-Fi is up.
:ssh
if not exist %1:\agent\ssh\authorized_keys goto :eof
ver | find "10.0.22" >nul || goto :eof
echo -- ssh >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -File %1:\agent\ssh_setup.ps1 %1:\agent >> %LOG% 2>&1
start "" /b cmd /c "timeout /t 90 /nobreak >nul & ipconfig > %1:\agent\ip.txt 2>&1"
goto :eof

rem Windows Update off, on every boot (Windows may turn parts of it back on). A feature update
rem to 24H2 or later would not boot on the Cortex-A57 (it needs ARMv8.1 atomics), and driver
rem updates could replace ours. Policies first, then the services and their scheduled tasks.
:noupdate
echo -- windows update off >> %LOG%
set WU=HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
reg add %WU% /v TargetReleaseVersion /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add %WU% /v ProductVersion /t REG_SZ /d "Windows 11" /f >> %LOG% 2>&1
reg add %WU% /v TargetReleaseVersionInfo /t REG_SZ /d 23H2 /f >> %LOG% 2>&1
reg add %WU% /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add %WU% /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add %WU%\AU /v NoAutoUpdate /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching /v SearchOrderConfig /t REG_DWORD /d 0 /f >> %LOG% 2>&1
for %%S in (wuauserv UsoSvc) do (
  sc stop %%S >nul 2>&1
  sc config %%S start= disabled >> %LOG% 2>&1
)
rem The medic service is protected against sc config; its registry value can still be set by SYSTEM.
reg add HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc /v Start /t REG_DWORD /d 4 /f >> %LOG% 2>&1
powershell -NoProfile -Command "foreach ($p in '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\WaaSMedic\') { Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue | Where-Object State -ne 'Disabled' | ForEach-Object { $t = $_; try { Disable-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null; 'disabled ' + $t.TaskPath + $t.TaskName } catch { 'kept ' + $t.TaskPath + $t.TaskName } } }" >> %LOG% 2>&1
goto :eof
