@echo off
setlocal

:: Navigate to project root (assuming script is in scripts/)
cd /d "%~dp0.."

echo ==========================================
echo Skotiq Imaging Laptop Deployer
echo ==========================================

echo [1/5] Building Rust backend, [2/5] Building Flutter frontend...
call dart scripts\build.dart desktop windows
if %errorlevel% neq 0 (
    echo Build failed!
    pause
    exit /b %errorlevel%
)
cd apps/desktop

echo [3/5] Copying Skotiq Bridge DLL...
copy /Y "..\..\native\skotiq_native\target\release\skotiq_bridge.dll" "build\windows\x64\runner\Release\"
if %errorlevel% neq 0 (
    echo DLL copy failed!
    pause
    exit /b %errorlevel%
)

echo [4/5] Stopping remote instance...
ssh scdou@192.168.1.59 "taskkill /IM skotiq.exe /F"
:: Don't fail if not running - just continue

echo [5/5] Deploying to 192.168.1.59...
scp -r "build\windows\x64\runner\Release\*" "scdou@192.168.1.59:\"C:/Program Files/Skotiq/\""
if %errorlevel% neq 0 (
    echo Deployment failed!
    pause
    exit /b %errorlevel%
)

echo ==========================================
echo Deployment Success!
echo ==========================================
pause
