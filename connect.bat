@echo off
title UK VPN - Connect
REM Double-click me. Spins up a London VPN and connects this PC to it.

REM Self-elevate: cert import + machine VPN need admin.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\connect.ps1"

echo.
echo Press any key to close...
pause >nul
