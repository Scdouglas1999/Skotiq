# Copy libraw.dll to all necessary locations for development and production
# Run this after building or before testing
# IMPORTANT: Must use 64-bit RELEASE libraw.dll for x64 builds

$ErrorActionPreference = "Stop"

$dumpbin = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.43.34808\bin\Hostx64\x64\dumpbin.exe"

function Test-IsDebugBuild($path) {
    if (Test-Path $dumpbin) {
        $deps = & $dumpbin /dependents $path 2>$null
        return $deps -match "MSVCP140D.dll|VCRUNTIME140D.dll|ucrtbased.dll"
    }
    return $false
}

# Use the known 64-bit Release version from the runner directory
$sourceFile = "$PSScriptRoot\..\apps\desktop\windows\runner\Release\libraw.dll"

# Alternative source locations in priority order (all should be Release builds)
$alternativeSources = @(
    "$PSScriptRoot\..\lib\libraw\libraw.dll",
    "$PSScriptRoot\..\libraw.dll"
)

if (!(Test-Path $sourceFile) -or (Test-IsDebugBuild $sourceFile)) {
    if (Test-IsDebugBuild $sourceFile) {
        Write-Host "Primary source is a DEBUG build, looking for Release..." -ForegroundColor Yellow
    }
    foreach ($alt in $alternativeSources) {
        if ((Test-Path $alt) -and !(Test-IsDebugBuild $alt)) {
            $sourceFile = $alt
            Write-Host "Using alternative source: $sourceFile" -ForegroundColor Yellow
            break
        }
    }
}

if (!(Test-Path $sourceFile)) {
    Write-Error "No 64-bit Release libraw.dll source found!"
    exit 1
}

# Verify it's 64-bit
$bytes = [System.IO.File]::ReadAllBytes($sourceFile)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
if ($machine -ne 0x8664) {
    Write-Error "Source libraw.dll is NOT 64-bit! Machine type: $machine (expected 0x8664)"
    exit 1
}
Write-Host "Source libraw.dll verified as 64-bit (AMD64)" -ForegroundColor Green

# Verify it's a Release build (not Debug)
if (Test-IsDebugBuild $sourceFile) {
    Write-Error "Source libraw.dll is a DEBUG build! It requires Visual Studio to be installed."
    Write-Error "Please use a RELEASE build of libraw.dll that links to MSVCP140.dll (not MSVCP140D.dll)"
    exit 1
}
Write-Host "Source libraw.dll verified as RELEASE build" -ForegroundColor Green

$targets = @(
    # Tracked lib directory (primary source for builds)
    "..\lib\libraw\libraw.dll",

    # Root fallback (for other scripts that might reference it)
    "..\libraw.dll",
    "..\apps\desktop\libraw.dll",
    "..\apps\desktop\windows\libraw.dll",

    # Rust target directories
    "..\native\skotiq_native\target\debug\libraw.dll",
    "..\native\skotiq_native\target\release\libraw.dll",

    # Flutter runner directories
    "..\apps\desktop\windows\runner\Debug\libraw.dll",
    "..\apps\desktop\windows\runner\Release\libraw.dll",

    # Flutter build output directories (where the app runs from)
    "..\apps\desktop\build\windows\x64\runner\Debug\libraw.dll",
    "..\apps\desktop\build\windows\x64\runner\Release\libraw.dll"
)

$copiedCount = 0
$failedCount = 0

foreach ($target in $targets) {
    try {
        $dir = Split-Path -Parent $target
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "Created directory: $dir" -ForegroundColor Yellow
        }
        
        Copy-Item $sourceFile $target -Force
        Write-Host "Copied to: $target" -ForegroundColor Green
        $copiedCount++
    }
    catch {
        Write-Host "Failed to copy to: $target" -ForegroundColor Red
        Write-Host "  Error: $_" -ForegroundColor Red
        $failedCount++
    }
}

Write-Host "`n========================================"
Write-Host "LibRaw DLL Deployment Complete"
Write-Host "========================================"
Write-Host "Copied: $copiedCount"
if ($failedCount -gt 0) {
    Write-Host "Failed: $failedCount" -ForegroundColor Red
} else {
    Write-Host "Failed: $failedCount" -ForegroundColor Green
}

if ($failedCount -gt 0) {
    exit 1
}
