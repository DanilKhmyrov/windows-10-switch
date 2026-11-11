@echo off
rem Copies setup logs to %1 every 20 s ("once" = one pass).
:loop
xcopy /y /e /i /c /q C:\Windows\Panther %1\panther >nul 2>&1
xcopy /y /e /i /c /q C:\Windows\System32\Sysprep\Panther %1\panther-sysprep >nul 2>&1
copy /y C:\Windows\INF\setupapi.dev.log %1\setupapi.dev.log >nul 2>&1
if "%2"=="once" goto :eof
ping -n 20 127.0.0.1 >nul
goto loop
