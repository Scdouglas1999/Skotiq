$ErrorActionPreference = 'Stop'

function Assert-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "$name not found on PATH. Please install or add it to PATH."
    }
}

function Copy-File($source, $destination) {
    if (-not (Test-Path $source)) {
        throw "Required file not found: $source"
    }
    $destDir = Split-Path -Parent $destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item $source $destination -Force
}

function Copy-IfExists($source, $destination) {
    if (Test-Path $source) {
        $destDir = Split-Path -Parent $destination
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item $source $destination -Force
        Write-Host "Copied optional vendor DLL: $([IO.Path]::GetFileName($source))"
    } else {
        Write-Host "Optional vendor DLL not found, skipping: $source" -ForegroundColor DarkYellow
    }
}

function Assert-Dll64Bit($path) {
    if (-not (Test-Path $path)) {
        throw "DLL not found: $path"
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    if ($machine -ne 0x8664) {
        throw "DLL is NOT 64-bit: $path (machine type: $machine, expected 0x8664 for AMD64)"
    }
    Write-Host "Verified 64-bit: $([IO.Path]::GetFileName($path))" -ForegroundColor DarkGreen
}

function Assert-DllReleaseBuild($path) {
    # Check if DLL links to Debug runtime (MSVCP140D.dll, VCRUNTIME140D.dll, ucrtbased.dll)
    $dumpbin = "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.43.34808\bin\Hostx64\x64\dumpbin.exe"
    if (Test-Path $dumpbin) {
        $deps = & $dumpbin /dependents $path 2>$null
        if ($deps -match "MSVCP140D.dll|VCRUNTIME140D.dll|ucrtbased.dll") {
            throw "DLL is a DEBUG build (requires VS to be installed): $path. Please use a RELEASE build."
        }
        Write-Host "Verified RELEASE build: $([IO.Path]::GetFileName($path))" -ForegroundColor DarkGreen
    }
}

function Invoke-Step($name, [scriptblock]$action) {
    Write-Host "==> $name" -ForegroundColor Cyan
    & $action
    Write-Host "[OK] $name" -ForegroundColor Green
}

# Authenticode-sign the given files when a code-signing cert is provisioned.
# Fail-closed: a blank WINDOWS_SIGNING_CERT_BASE64 is a no-op (ship unsigned
# beta); a SET-but-broken cert throws rather than silently shipping unsigned.
function Invoke-AuthenticodeSign([string[]]$paths) {
    $certB64 = $env:WINDOWS_SIGNING_CERT_BASE64
    if ([string]::IsNullOrWhiteSpace($certB64)) {
        Write-Host "WINDOWS_SIGNING_CERT_BASE64 not set: skipping Authenticode signing (unsigned beta)." -ForegroundColor DarkYellow
        return
    }
    $targets = @($paths | Where-Object { Test-Path $_ })
    if ($targets.Count -eq 0) {
        Write-Host "Authenticode: no files to sign." -ForegroundColor DarkYellow
        return
    }
    $signtool = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $signtool) {
        throw "WINDOWS_SIGNING_CERT_BASE64 is set but signtool.exe was not found under the Windows 10 SDK."
    }
    $pfx = Join-Path ([IO.Path]::GetTempPath()) "skotiq_codesign.pfx"
    try {
        [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($certB64))
        & $signtool.FullName sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
            /f $pfx /p $env:WINDOWS_SIGNING_CERT_PASSWORD @targets
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit $LASTEXITCODE)" }
        & $signtool.FullName verify /pa @targets
        if ($LASTEXITCODE -ne 0) { throw "signtool verify failed (exit $LASTEXITCODE)" }
        Write-Host "Authenticode-signed $($targets.Count) file(s)." -ForegroundColor DarkGreen
    }
    finally {
        Remove-Item $pfx -Force -ErrorAction SilentlyContinue
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Assert-Tool cargo
Assert-Tool flutter
Assert-Tool iscc

$rustDir = Join-Path $repoRoot "native/skotiq_native"
$desktopDir = Join-Path $repoRoot "apps/desktop"
$dllSource = Join-Path $rustDir "target/release/skotiq_bridge.dll"
$releaseDir = Join-Path $desktopDir "build/windows/x64/runner/Release"
$dllDest = Join-Path $releaseDir "skotiq_bridge.dll"
$installerScript = Join-Path $desktopDir "installer/installer.iss"
$installerOutDir = Join-Path $desktopDir "build/installer"

# Required runtime/vendor DLLs bundled into the installer so end users have camera drivers
$vendorDlls = @(
    # Visual C++ Runtime (Modern) - Required for most modern SDKs (ZWO, Touptek, etc.)
    @{
        Source = "$env:SystemRoot\System32\vcruntime140.dll"
        Dest   = Join-Path $releaseDir "vcruntime140.dll"
    }
    @{
        Source = "$env:SystemRoot\System32\vcruntime140_1.dll"
        Dest   = Join-Path $releaseDir "vcruntime140_1.dll"
    }
    @{
        Source = "$env:SystemRoot\System32\msvcp140.dll"
        Dest   = Join-Path $releaseDir "msvcp140.dll"
    }
    # Visual C++ 2013 Runtime - Required for older drivers (e.g. Moravian)
    @{
        Source = "$env:SystemRoot\System32\msvcp120.dll"
        Dest   = Join-Path $releaseDir "msvcp120.dll"
    }
    @{
        Source = "$env:SystemRoot\System32\msvcr120.dll"
        Dest   = Join-Path $releaseDir "msvcr120.dll"
    }
    # Visual C++ 2010 Runtime - Required for legacy drivers (e.g. Atik)
    @{
        Source = "$env:SystemRoot\System32\msvcp100.dll"
        Dest   = Join-Path $releaseDir "msvcp100.dll"
    }
    @{
        Source = "$env:SystemRoot\System32\msvcr100.dll"
        Dest   = Join-Path $releaseDir "msvcr100.dll"
    }
    # Core - LibRaw (MUST be 64-bit RELEASE build - Debug builds require VS installed)
    @{
        Source = Join-Path $repoRoot "apps/desktop/windows/runner/Release/libraw.dll"
        Dest   = Join-Path $releaseDir "libraw.dll"
        Verify64Bit = $true
        VerifyReleaseBuild = $true
    }
    # ZWO cameras (ASI Windows SDK v1.40)
    @{
        Source = Join-Path $repoRoot "SDKs/ZWO/ASI_Camera_SDK/ASI_Windows_SDK_V1.40/ASI SDK/lib/x64/ASICamera2.dll"
        Dest   = Join-Path $releaseDir "ASICamera2.dll"
    }
    # ZWO EAF focuser
    @{
        Source = Join-Path $repoRoot "SDKs/ZWO/EAF_SDK/EAF_Windows_SDK_V1.6/EAF SDK/lib/Win64/EAF_focuser.dll"
        Dest   = Join-Path $releaseDir "EAF_focuser.dll"
    }
    # ZWO EFW filter wheel
    @{
        Source = Join-Path $repoRoot "SDKs/ZWO/EFW_SDK/EFW_Windows_SDK_V1.7/EFW SDK/lib/Win64/EFW_filter.dll"
        Dest   = Join-Path $releaseDir "EFW_filter.dll"
    }
    # QHY (WinMix x64)
    @{
        Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/qhyccd.dll"
        Dest   = Join-Path $releaseDir "qhyccd.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/tbb.dll"
        Dest   = Join-Path $releaseDir "tbb.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/ftd2xx.dll"
        Dest   = Join-Path $releaseDir "ftd2xx.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/winusb.dll"
        Dest   = Join-Path $releaseDir "winusb.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/msvcp90.dll"
        Dest   = Join-Path $releaseDir "msvcp90.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/msvcr90.dll"
        Dest   = Join-Path $releaseDir "msvcr90.dll"
    }
    # Atik
    @{
        Source = Join-Path $repoRoot "SDKs/Atik/extracted/lib/Windows/64/AtikCameras.dll"
        Dest   = Join-Path $releaseDir "AtikCameras.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/Atik/extracted/lib/Windows/64/Atik.Core.dll"
        Dest   = Join-Path $releaseDir "Atik.Core.dll"
    }
    # Player One
    @{
        Source = Join-Path $repoRoot "SDKs/PlayerOne/PlayerOne_Camera_SDK_Windows_V3.7.1/lib/x64/PlayerOneCamera.dll"
        Dest   = Join-Path $releaseDir "PlayerOneCamera.dll"
    }
    # Moravian
    @{
        Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/cXusb.dll"
        Dest   = Join-Path $releaseDir "cXusb.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/gXeth.dll"
        Dest   = Join-Path $releaseDir "gXeth.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/gXusb.dll"
        Dest   = Join-Path $releaseDir "gXusb.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/sfw.dll"
        Dest   = Join-Path $releaseDir "sfw.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/sfweth.dll"
        Dest   = Join-Path $releaseDir "sfweth.dll"
    }
    # SVBony
    @{
        Source = Join-Path $repoRoot "SDKs/SVBony/SVBONY/lib/x64/SVBCameraSDK.dll"
        Dest   = Join-Path $releaseDir "SVBCameraSDK.dll"
    }
    # Touptek
    @{
        Source = Join-Path $repoRoot "SDKs/Touptek/win/x64/ogmacam.dll"
        Dest   = Join-Path $releaseDir "ogmacam.dll"
    }
    # SBIG DLAPI
    @{
        Source = Join-Path $repoRoot "SDKs/SBIG_DLAPI/extracted/dlapi-sdk-4.0.2.0-win-x64/lib/dlapi.dll"
        Dest   = Join-Path $releaseDir "dlapi.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/SBIG_DLAPI/extracted/dlapi-sdk-4.0.2.0-win-x64/dependencies/ftd2xx.dll"
        Dest   = Join-Path $releaseDir "sbig_ftd2xx.dll"
    }
    @{
        Source = Join-Path $repoRoot "SDKs/SBIG_DLAPI/extracted/dlapi-sdk-4.0.2.0-win-x64/dependencies/ftd3xx.dll"
        Dest   = Join-Path $releaseDir "sbig_ftd3xx.dll"
    }
)

Invoke-Step "Build Rust bridge (release)" {
    Push-Location $rustDir
    cargo build --release --manifest-path bridge/Cargo.toml
    Pop-Location
}

Invoke-Step "Build Rust updater (release)" {
    Push-Location $rustDir
    cargo build --release --package skotiq_updater
    Pop-Location
}

Invoke-Step "Build Flutter Windows app (release)" {
    Push-Location $desktopDir
    # The app includes the production verification key. Supply an override
    # only when explicitly configured; an empty define would disable trust.
    $updatePublicKey = $env:SKOTIQ_UPDATE_PUBLIC_KEY
    $updateDefines = @()
    if (-not [string]::IsNullOrWhiteSpace($updatePublicKey)) {
        $updateDefines += "--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=$updatePublicKey"
    }
    flutter build windows --release @updateDefines
    Pop-Location
}

Invoke-Step "Copy native DLL and updater next to exe" {
    Copy-File $dllSource $dllDest

    # Verify the native bridge is 64-bit
    Assert-Dll64Bit $dllDest

    # Copy the updater executable
    $updaterSource = Join-Path $rustDir "target/release/updater.exe"
    $updaterDest = Join-Path $releaseDir "updater.exe"
    Copy-File $updaterSource $updaterDest
    Write-Host "Copied updater.exe for OTA updates"

    # Copy vendor SDK DLLs for native camera discovery (fail fast if missing)
    foreach ($item in $vendorDlls) {
        Copy-File $item.Source $item.Dest

        # Verify 64-bit if flagged
        if ($item.Verify64Bit) {
            Assert-Dll64Bit $item.Dest
        }

        # Verify Release build if flagged (Debug builds require VS installed)
        if ($item.VerifyReleaseBuild) {
            Assert-DllReleaseBuild $item.Dest
        }
    }
}

Invoke-Step "Copy web dashboard to release directory" {
    $dashboardSource = Join-Path $desktopDir "web_dashboard"
    $dashboardDest = Join-Path $releaseDir "web_dashboard"
    if (Test-Path $dashboardSource) {
        if (Test-Path $dashboardDest) {
            Remove-Item -Recurse -Force $dashboardDest
        }
        Copy-Item -Recurse $dashboardSource $dashboardDest
        Write-Host "Copied web_dashboard directory"
    } else {
        throw "web_dashboard directory not found at: $dashboardSource"
    }
}

Invoke-Step "Authenticode sign Release binaries (optional)" {
    Invoke-AuthenticodeSign (Get-ChildItem $releaseDir -Recurse -Include *.exe, *.dll |
        Select-Object -ExpandProperty FullName)
}

Invoke-Step "Prepare installer output directory" {
    if (-not (Test-Path $installerOutDir)) {
        New-Item -ItemType Directory -Path $installerOutDir -Force | Out-Null
    }
}

Invoke-Step "Build installer with Inno Setup" {
    iscc "/O$installerOutDir" $installerScript
}

Invoke-Step "Authenticode sign installer (optional)" {
    Invoke-AuthenticodeSign (Get-ChildItem $installerOutDir -Filter *.exe |
        Select-Object -ExpandProperty FullName)
}

Write-Host ""
Write-Host "Done. Installer is under: $installerOutDir" -ForegroundColor Yellow

