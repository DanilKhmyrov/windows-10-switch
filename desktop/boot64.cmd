@echo off
rem Started by the swagent service on every boot (Windows 10 ARM64): runs \agent\w64.cmd from the
rem boot partition, with its drive letter as %1.
call C:\swagent\findagent.cmd
if defined AGENT call %AGENT%:\agent\w64.cmd %AGENT%
