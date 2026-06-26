@echo off
title UK VPN - Join
REM Double-click me on any laptop that has the AWS CLI logged in.
REM Finds the account's UK VPN (or creates a fresh ~5h one) and joins THIS device.
REM Same engine as connect.bat - "join" is just the friendlier name for an extra laptop.

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
