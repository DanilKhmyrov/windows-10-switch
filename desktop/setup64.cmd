@echo off
rem ARM64: runs instead of oobe\windeploy.exe; copies setup logs to \agent\a64 on the boot partition.
set L=C:\swagent
call C:\swagent\findagent.cmd
if defined AGENT set L=%AGENT%:\agent\a64
mkdir %L% 2>nul
echo ==== SETUP %date% %time% >> %L%\setup.txt
reg query HKLM\SYSTEM\Setup >> %L%\setup.txt 2>&1
start "" /b C:\Windows\System32\cmd.exe /c C:\swagent\copylogs.cmd %L%
start "" /b C:\Windows\System32\cmd.exe /c C:\swagent\setupwatch.cmd %L%
C:\Windows\System32\oobe\windeploy.exe
echo windeploy exit %errorlevel% %time% >> %L%\setup.txt
reg query HKLM\SYSTEM\Setup >> %L%\setup.txt 2>&1
call C:\swagent\copylogs.cmd %L% once
