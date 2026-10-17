@echo off
title Skotiq Headless Server
color 0A
echo ========================================
echo Skotiq 2.0 - Headless Mode
echo ========================================
echo.
echo Starting headless server...
echo.
echo Build target (from apps\desktop):
echo   flutter build windows --release
echo.
echo The release binary accepts --headless via main.dart and runs the
echo headless API server (same entry as lib\main_headless.dart).
echo.
echo Make sure:
echo   1. Windows Firewall rules are set
echo   2. Both devices are on the same WiFi network
echo   3. Watch this window for connection info
echo.
echo Press Ctrl+C to stop the server
echo.
echo ========================================
echo.

cd /d "%~dp0"
if not exist "build\windows\x64\runner\Release\skotiq_desktop.exe" (
    echo ERROR: Executable not found!
    echo Please build the app first with: flutter build windows --release
    pause
    exit /b 1
)

echo Running: build\windows\x64\runner\Release\skotiq_desktop.exe --headless
echo.
echo NOTE: If you don't see output below, the app may be running but
echo       Flutter Windows apps don't show console output by default.
echo       Check Task Manager to see if the process is running.
echo.
echo ========================================
echo.

build\windows\x64\runner\Release\skotiq_desktop.exe --headless

echo.
echo ========================================
echo Server stopped.
pause
