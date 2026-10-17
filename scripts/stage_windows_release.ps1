# Stage native/runtime DLLs next to the Windows desktop executable.
# Required after `flutter build windows` — Flutter does not copy the Rust bridge
# or LibRaw dependency into build\windows\x64\runner\Release.
#
# Usage:
#   .\scripts\stage_windows_release.ps1              # Release output
#   .\scripts\stage_windows_release.ps1 -Profile Debug

param(
    [ValidateSet('Release', 'Debug')]
    [string]$Profile = 'Release',

    # Local development only. Official artifacts must leave this disabled
    # until every included vendor's redistribution terms are cleared.
    [switch]$IncludeVendorSdks
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$NativeDir = Join-Path $ProjectRoot 'native\skotiq_native'
$DesktopDir = Join-Path $ProjectRoot 'apps\desktop'
$OutputDir = Join-Path $DesktopDir "build\windows\x64\runner\$Profile"

if (-not (Test-Path $OutputDir)) {
    throw "Flutter output directory not found: $OutputDir`nRun flutter build windows first."
}

function Copy-RequiredFile($source, $dest) {
    if (-not (Test-Path $source)) {
        throw "Required file not found: $source"
    }
    Copy-Item -Path $source -Destination $dest -Force
    Write-Host "  -> $dest" -ForegroundColor Green
}

function Copy-OptionalFile($source, $dest) {
    if (Test-Path $source) {
        Copy-Item -Path $source -Destination $dest -Force
        Write-Host "  -> $dest" -ForegroundColor DarkGreen
    }
}

function Assert-Dll64Bit($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x8664) {
        throw "DLL is not 64-bit: $path (machine=$machine)"
    }
}

Write-Host "Staging native DLLs for Windows $Profile -> $OutputDir" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# skotiq_bridge.dll (Rust)
# ---------------------------------------------------------------------------
$bridgeSource = Join-Path $NativeDir "target\$($Profile.ToLower())\skotiq_bridge.dll"
if (-not (Test-Path $bridgeSource)) {
    Write-Host "Bridge DLL missing; building cargo release..." -ForegroundColor Yellow
    Push-Location $NativeDir
    if ($Profile -eq 'Release') {
        cargo build --release --package skotiq_bridge
    } else {
        cargo build --package skotiq_bridge
    }
    Pop-Location
}

$bridgeDest = Join-Path $OutputDir 'skotiq_bridge.dll'
Write-Host "Copying skotiq_bridge.dll"
Copy-RequiredFile $bridgeSource $bridgeDest
Assert-Dll64Bit $bridgeDest
$srcHash = (Get-FileHash $bridgeSource -Algorithm SHA256).Hash
$dstHash = (Get-FileHash $bridgeDest -Algorithm SHA256).Hash
if ($srcHash -ne $dstHash) {
    throw "skotiq_bridge.dll copy verification failed (hash mismatch)"
}

# Also keep apps/desktop copies in sync (dev.ps1 / FRB expectations)
$bridgeMirrorDirs = @(
    (Join-Path $DesktopDir 'skotiq_bridge.dll'),
    (Join-Path $DesktopDir 'windows\skotiq_bridge.dll'),
    (Join-Path $DesktopDir "build\windows\x64\runner\Debug\skotiq_bridge.dll"),
    (Join-Path $DesktopDir "build\windows\x64\runner\Release\skotiq_bridge.dll")
)
foreach ($mirror in $bridgeMirrorDirs) {
    $mirrorDir = Split-Path -Parent $mirror
    if (Test-Path $mirrorDir) {
        Copy-Item -Path $bridgeSource -Destination $mirror -Force
    }
}

# ---------------------------------------------------------------------------
# libraw.dll (required to load skotiq_bridge.dll on Windows)
# ---------------------------------------------------------------------------
$librawSource = Join-Path $DesktopDir 'windows\runner\Release\libraw.dll'
if (-not (Test-Path $librawSource)) {
    $librawFallbacks = @(
        (Join-Path $ProjectRoot 'lib\libraw\libraw.dll'),
        (Join-Path $ProjectRoot 'libraw.dll')
    )
    foreach ($fb in $librawFallbacks) {
        if (Test-Path $fb) {
            $librawSource = $fb
            break
        }
    }
}

if (-not (Test-Path $librawSource)) {
    throw @"
libraw.dll not found. skotiq_bridge.dll depends on it and will not load.

Place a 64-bit RELEASE libraw.dll at:
  apps\desktop\windows\runner\Release\libraw.dll

Or run: .\scripts\copy_libraw.ps1
"@
}

$librawDest = Join-Path $OutputDir 'libraw.dll'
Write-Host "Copying libraw.dll"
Copy-RequiredFile $librawSource $librawDest
Assert-Dll64Bit $librawDest

# ---------------------------------------------------------------------------
# Dart native assets (sqlite3 and any future package build-hook outputs)
# ---------------------------------------------------------------------------
$nativeAssetsDir = Join-Path $DesktopDir 'build\native_assets\windows'
if (-not (Test-Path $nativeAssetsDir)) {
    throw "Dart native-assets directory not found: $nativeAssetsDir"
}

Write-Host "Copying Dart native assets"
$nativeAssetDlls = @(Get-ChildItem -Path $nativeAssetsDir -Filter '*.dll' -File)
if ($nativeAssetDlls.Count -eq 0) {
    throw "No Dart native-asset DLLs found in: $nativeAssetsDir"
}
foreach ($dll in $nativeAssetDlls) {
    $dest = Join-Path $OutputDir $dll.Name
    Copy-RequiredFile $dll.FullName $dest
    Assert-Dll64Bit $dest
}

$sqliteDest = Join-Path $OutputDir 'sqlite3.dll'
if (-not (Test-Path $sqliteDest)) {
    throw "sqlite3.dll was not produced by Dart build hooks"
}

# ---------------------------------------------------------------------------
# MSVC runtime (bundled for machines without VS installed)
# ---------------------------------------------------------------------------
Write-Host "Copying MSVC runtime DLLs (optional, from System32)"
$runtimeDlls = @(
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'msvcp140.dll'
)
foreach ($name in $runtimeDlls) {
    $src = Join-Path $env:SystemRoot "System32\$name"
    Copy-OptionalFile $src (Join-Path $OutputDir $name)
}

# ---------------------------------------------------------------------------
# Vendor device SDKs (camera / focuser / filter-wheel drivers the native bridge
# loads at runtime). sdk_loader searches next to the executable first, so any
# DLL in native\sdk\windows\ ships beside the exe and is found without the user
# installing the vendor's driver package. An empty folder bundles nothing.
# ---------------------------------------------------------------------------
$sdkDir = Join-Path $ProjectRoot 'native\sdk\windows'
if ($IncludeVendorSdks -and (Test-Path $sdkDir)) {
    $sdkDlls = @(Get-ChildItem -Path $sdkDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)
    if ($sdkDlls.Count -gt 0) {
        Write-Host "Bundling $($sdkDlls.Count) vendor device SDK DLL(s) from native\sdk\windows" -ForegroundColor Cyan
        foreach ($dll in $sdkDlls) {
            $dest = Join-Path $OutputDir $dll.Name
            Copy-RequiredFile $dll.FullName $dest
            Assert-Dll64Bit $dest
        }
    }
    else {
        Write-Host "No vendor SDK DLLs in native\sdk\windows (devices need vendor drivers installed)" -ForegroundColor DarkYellow
    }
}
elseif ($IncludeVendorSdks) {
    Write-Host "Vendor SDK staging requested, but native\sdk\windows does not exist" -ForegroundColor DarkYellow
}
else {
    Write-Host "Vendor SDK staging disabled (official release-safe default)" -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# Verify load chain
# ---------------------------------------------------------------------------
foreach ($required in @('skotiq_bridge.dll', 'libraw.dll', 'sqlite3.dll')) {
    $path = Join-Path $OutputDir $required
    if (-not (Test-Path $path)) {
        throw "Staging incomplete: missing $required"
    }
}

Write-Host ""
Write-Host "Staging complete. Launch:" -ForegroundColor Yellow
Write-Host "  $(Join-Path $OutputDir 'skotiq.exe')"
