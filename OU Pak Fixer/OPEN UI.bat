@echo off
REM STA is required for WinForms. New hidden PowerShell window = form only, no console.
start "Open Unleashed Pak Fixer" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Settings\Scripts\OU-UI.ps1"
