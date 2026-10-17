# Build script for Skotiq native Rust library (Windows PowerShell)
# Builds for Windows

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$NativeDir = Join-Path $ProjectRoot "native\skotiq_native"

Set-Location $NativeDir

Write-Host "Building Skotiq native library..."
Write-Host "Project root: $ProjectRoot"
Write-Host "Native dir: $NativeDir"

# Build for Windows
Write-Host "Building for Windows..."
cargo build --release --manifest-path bridge\Cargo.toml

# Stage bridge + libraw + MSVC runtime into Flutter Release output
& (Join-Path $ScriptDir "stage_windows_release.ps1") -Profile Release

Write-Host "Build complete!"





