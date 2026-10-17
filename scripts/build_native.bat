@echo off
REM Build script for Skotiq native Rust library (Windows Batch)
REM Builds for Windows

setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set PROJECT_ROOT=%SCRIPT_DIR%..
set NATIVE_DIR=%PROJECT_ROOT%\native\skotiq_native

cd /d "%NATIVE_DIR%"

echo Building Skotiq native library...
echo Project root: %PROJECT_ROOT%
echo Native dir: %NATIVE_DIR%

REM Build for Windows
echo Building for Windows...
cargo build --release --manifest-path bridge\Cargo.toml

REM Copy to Flutter app directory
set LIB_NAME=skotiq_bridge.dll
set TARGET_DIR=%PROJECT_ROOT%\apps\desktop\build\windows\x64\runner\Release
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%"
copy "target\release\%LIB_NAME%" "%TARGET_DIR%\" /Y
echo Copied %LIB_NAME% to %TARGET_DIR%

echo Build complete!





