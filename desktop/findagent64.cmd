@echo off
rem Sets AGENT to the drive letter of the small FAT boot partition (the one with \agent\w64.cmd).
rem Windows may leave that partition without a letter; then each volume without one is tried at W:,
rem and the one that matches keeps W: (mountvol assignments persist).
set AGENT=
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %%d:\agent\w64.cmd (set AGENT=%%d& goto :eof)
for /f %%v in ('mountvol ^| findstr /l /c:"Volume{"') do (
  mountvol W: %%v >nul 2>&1 && (
    if exist W:\agent\w64.cmd (set AGENT=W& goto :eof)
    mountvol W: /d >nul 2>&1
  )
)
