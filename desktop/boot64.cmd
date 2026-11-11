@echo off
rem Started by the swagent service on every boot (Windows 10 ARM64): runs \agent\w64.cmd from CRASHDUMP.
for %%d in (D E F G H I J K) do if exist %%d:\agent\w64.cmd (call %%d:\agent\w64.cmd %%d & goto :eof)
