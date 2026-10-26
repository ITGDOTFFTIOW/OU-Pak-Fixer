@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\Fix-OUPaks.ps1" -ChangeFolder
pause
