@echo off
rem Started by the swagent service on every boot.
set WL=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon
if not exist C:\swagent\user.done (
  net user Switch "" /add > C:\swagent\user.log 2>&1
  net localgroup Administrators Switch /add >> C:\swagent\user.log 2>&1
  reg add "%WL%" /v AutoAdminLogon /t REG_SZ /d 1 /f >> C:\swagent\user.log 2>&1
  reg add "%WL%" /v DefaultUserName /t REG_SZ /d Switch /f >> C:\swagent\user.log 2>&1
  reg add "%WL%" /v DefaultPassword /t REG_SZ /d "" /f >> C:\swagent\user.log 2>&1
  reg add "%WL%" /v DefaultDomainName /t REG_SZ /d "%COMPUTERNAME%" /f >> C:\swagent\user.log 2>&1
  echo done > C:\swagent\user.done
  for %%d in (D E F G H I J K) do if exist %%d:\agent copy /y C:\swagent\user.log %%d:\agent\w32-user.log >nul
  shutdown /r /t 15
  goto :eof
)
for %%d in (D E F G H I J K) do if exist %%d:\agent\w32.cmd (call %%d:\agent\w32.cmd %%d & goto :eof)
