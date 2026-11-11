@echo off
set LOG=D:\agent\log.txt
ping -n 30 127.0.0.1 >nul
echo ==== BOOT >> %LOG%
devcon status "@ACPI\SWTS0001\0" >> %LOG% 2>&1
sc query swhid >> %LOG% 2>&1
