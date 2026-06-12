@echo off
title UK VPN - Add this Windows laptop
REM Double-click to put THIS extra Windows laptop on the already-running UK VPN.
REM Needs the 'uk-vpn-devices' folder (from connect.bat) on this PC's Desktop.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\add-windows-device.ps1"

echo.
echo Press any key to close...
pause >nul
