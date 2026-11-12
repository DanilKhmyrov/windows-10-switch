@echo off
rem Started by setup.cmd during Windows setup (ARM64). Setup fails once in the specialize pass
rem with "could not update the computer's boot configuration" (BFSVC: Failed to get partition
rem name, 0xc0000452): the firmware keeps no boot variables. As soon as that error is in
rem setupact.log, mark the pass done (ChildCompletion\setup.exe = 3, the manual fix in the
rem README) and keep it set while setup runs, so setup continues after the error dialog.
rem   setupwatch.cmd LOGFOLDER
set P=C:\Windows\Panther\setupact.log
:wait
findstr /c:"ModifyBootEntries: Error modifying bcd boot entries" %P% >nul 2>&1 && goto found
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress 2>nul | find "0x1" >nul || goto :eof
ping -n 4 127.0.0.1 >nul
goto wait
:found
echo ==== setupwatch: boot configuration error seen %date% %time%, ChildCompletion setup.exe = 3 >> %1\setup.txt
:hold
reg add HKLM\SYSTEM\Setup\Status\ChildCompletion /v setup.exe /t REG_DWORD /d 3 /f >nul 2>&1
reg query HKLM\SYSTEM\Setup /v SystemSetupInProgress 2>nul | find "0x1" >nul || goto :eof
ping -n 2 127.0.0.1 >nul
goto hold
