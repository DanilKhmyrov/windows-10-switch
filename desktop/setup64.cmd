@echo off
rem ARM64: runs instead of oobe\windeploy.exe; copies setup logs to CRASHDUMP\agent\a64.
set L=C:\swagent
for %%d in (D E F G H I J K) do if exist %%d:\agent\w64.cmd set L=%%d:\agent\a64
mkdir %L% 2>nul
echo ==== SETUP %date% %time% >> %L%\setup.txt
reg query HKLM\SYSTEM\Setup >> %L%\setup.txt 2>&1
start "" /b C:\Windows\System32\cmd.exe /c C:\swagent\copylogs.cmd %L%
C:\Windows\System32\oobe\windeploy.exe
echo windeploy exit %errorlevel% %time% >> %L%\setup.txt
reg query HKLM\SYSTEM\Setup >> %L%\setup.txt 2>&1
call C:\swagent\copylogs.cmd %L% once
