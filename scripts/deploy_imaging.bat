@echo off
setlocal

:: Navigate to project root (assuming script is in scripts/)
cd /d "%~dp0.."

echo ==========================================
echo Skotiq Imaging Laptop Deployer
echo ==========================================

echo [1/5] Building Rust backend...
cd native/skotiq_native
call cargo build --release --manifest-path bridge/Cargo.toml
if %errorlevel% neq 0 (
    echo Rust build failed!
    pause
    exit /b %errorlevel%
)
cd ../..

echo [2/5] Building Flutter frontend...
cd apps/desktop
call flutter build windows --release
if %errorlevel% neq 0 (
    echo Flutter build failed!
    pause
    exit /b %errorlevel%
)

echo [3/5] Copying Skotiq Bridge DLL...
copy /Y "..\..\native\skotiq_native\target\release\skotiq_bridge.dll" "build\windows\x64\runner\Release\"
if %errorlevel% neq 0 (
    echo DLL copy failed!
    pause
    exit /b %errorlevel%
)

echo [4/5] Stopping remote instance...
ssh scdou@192.168.1.59 "taskkill /IM skotiq_desktop.exe /F"
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
