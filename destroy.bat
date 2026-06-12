@echo off
title UK VPN - Destroy
REM Double-click me when you are done streaming. Deletes the server and stops billing.

REM Self-elevate: removing the machine VPN + certs needs admin.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\destroy.ps1"

echo.
echo Press any key to close...
pause >nul
