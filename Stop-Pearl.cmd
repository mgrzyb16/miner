@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Pearl.ps1" -Stop %*
pause
