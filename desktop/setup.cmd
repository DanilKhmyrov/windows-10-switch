@echo off
rem Runs instead of oobe\windeploy.exe; copies setup logs to CRASHDUMP\agent.
set L=C:\swagent
for %%d in (D E F G H I J K) do if exist %%d:\agent\w32.cmd set L=%%d:\agent
echo ==== SETUP %date% %time% >> %L%\w32-setup.txt
reg query HKLM\SYSTEM\Setup >> %L%\w32-setup.txt 2>&1
start "" /b C:\Windows\System32\cmd.exe /c C:\swagent\copylogs.cmd %L%
C:\Windows\System32\oobe\windeploy.exe
echo windeploy exit %errorlevel% %time% >> %L%\w32-setup.txt
reg query HKLM\SYSTEM\Setup >> %L%\w32-setup.txt 2>&1
call C:\swagent\copylogs.cmd %L% once
