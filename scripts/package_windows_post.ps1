# Post-build packaging: skips the cargo/flutter rebuild steps that the
# full package_windows.ps1 does, since both builds are already complete.
# Picks up where the build left off: copy updater.exe, copy vendor DLLs,
# copy web dashboard, then run Inno Setup.
#
# Why this exists: PowerShell 5.1's $ErrorActionPreference='Stop' interacts
# badly with cargo's stderr lines (treated as ErrorRecord). This script
# uses 'Continue' and gates on $LASTEXITCODE.

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

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

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$rustDir = Join-Path $repoRoot "native/skotiq_native"
$desktopDir = Join-Path $repoRoot "apps/desktop"
$releaseDir = Join-Path $desktopDir "build/windows/x64/runner/Release"
$installerScript = Join-Path $desktopDir "installer/installer.iss"
$installerOutDir = Join-Path $desktopDir "build/installer"

Write-Host "==> Copy updater.exe" -ForegroundColor Cyan
$updaterSource = Join-Path $rustDir "target/release/updater.exe"
$updaterDest = Join-Path $releaseDir "updater.exe"
if (Test-Path $updaterSource) {
    Copy-File $updaterSource $updaterDest
    Write-Host "  copied updater.exe"
} else {
    Write-Host "  updater.exe not built; building now"
    Push-Location $rustDir
    cargo build --release --package skotiq_updater
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -ne 0) { throw "cargo build updater failed (exit $rc)" }
    Copy-File $updaterSource $updaterDest
    Write-Host "  built + copied updater.exe"
}

Write-Host "==> Copy vendor DLLs" -ForegroundColor Cyan
$vendorDlls = @(
    @{ Source = "$env:SystemRoot\System32\vcruntime140.dll";   Dest = Join-Path $releaseDir "vcruntime140.dll" },
    @{ Source = "$env:SystemRoot\System32\vcruntime140_1.dll"; Dest = Join-Path $releaseDir "vcruntime140_1.dll" },
    @{ Source = "$env:SystemRoot\System32\msvcp140.dll";       Dest = Join-Path $releaseDir "msvcp140.dll" },
    @{ Source = "$env:SystemRoot\System32\msvcp120.dll";       Dest = Join-Path $releaseDir "msvcp120.dll" },
    @{ Source = "$env:SystemRoot\System32\msvcr120.dll";       Dest = Join-Path $releaseDir "msvcr120.dll" },
    @{ Source = "$env:SystemRoot\System32\msvcp100.dll";       Dest = Join-Path $releaseDir "msvcp100.dll" },
    @{ Source = "$env:SystemRoot\System32\msvcr100.dll";       Dest = Join-Path $releaseDir "msvcr100.dll" },
    @{ Source = Join-Path $repoRoot "apps/desktop/windows/runner/Release/libraw.dll"; Dest = Join-Path $releaseDir "libraw.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/ZWO/ASI_Camera_SDK/ASI_Windows_SDK_V1.40/ASI SDK/lib/x64/ASICamera2.dll"; Dest = Join-Path $releaseDir "ASICamera2.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/ZWO/EAF_SDK/EAF_Windows_SDK_V1.6/EAF SDK/lib/Win64/EAF_focuser.dll";       Dest = Join-Path $releaseDir "EAF_focuser.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/ZWO/EFW_SDK/EFW_Windows_SDK_V1.7/EFW SDK/lib/Win64/EFW_filter.dll";       Dest = Join-Path $releaseDir "EFW_filter.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/qhyccd.dll"; Dest = Join-Path $releaseDir "qhyccd.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/tbb.dll";    Dest = Join-Path $releaseDir "tbb.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/ftd2xx.dll"; Dest = Join-Path $releaseDir "ftd2xx.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/winusb.dll"; Dest = Join-Path $releaseDir "winusb.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/msvcp90.dll"; Dest = Join-Path $releaseDir "msvcp90.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/QHY/sdk_WinMix_25.09.29/pkg_win/x64/msvcr90.dll"; Dest = Join-Path $releaseDir "msvcr90.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Atik/extracted/lib/Windows/64/AtikCameras.dll"; Dest = Join-Path $releaseDir "AtikCameras.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Atik/extracted/lib/Windows/64/Atik.Core.dll";   Dest = Join-Path $releaseDir "Atik.Core.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/PlayerOne/PlayerOne_Camera_SDK_Windows_V3.7.1/lib/x64/PlayerOneCamera.dll"; Dest = Join-Path $releaseDir "PlayerOneCamera.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/cXusb.dll";   Dest = Join-Path $releaseDir "cXusb.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/gXeth.dll";   Dest = Join-Path $releaseDir "gXeth.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/gXusb.dll";   Dest = Join-Path $releaseDir "gXusb.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/sfw.dll";     Dest = Join-Path $releaseDir "sfw.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Moravian/extracted/x64/sfweth.dll";  Dest = Join-Path $releaseDir "sfweth.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/SVBony/SVBONY/lib/x64/SVBCameraSDK.dll"; Dest = Join-Path $releaseDir "SVBCameraSDK.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/Touptek/win/x64/ogmacam.dll";        Dest = Join-Path $releaseDir "ogmacam.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/SBIG_DLAPI/extracted/dlapi-sdk-4.0.2.0-win-x64/lib/dlapi.dll";              Dest = Join-Path $releaseDir "dlapi.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/SBIG_DLAPI/extracted/dlapi-sdk-4.0.2.0-win-x64/dependencies/ftd2xx.dll";    Dest = Join-Path $releaseDir "sbig_ftd2xx.dll" },
    @{ Source = Join-Path $repoRoot "SDKs/SBIG_DLAPI/extracted/dlapi-sdk-4.0.2.0-win-x64/dependencies/ftd3xx.dll";    Dest = Join-Path $releaseDir "sbig_ftd3xx.dll" }
)
foreach ($item in $vendorDlls) {
    Copy-File $item.Source $item.Dest
}
Write-Host "  copied $($vendorDlls.Count) vendor DLLs"

Write-Host "==> Copy web dashboard" -ForegroundColor Cyan
$dashboardSource = Join-Path $desktopDir "web_dashboard"
$dashboardDest = Join-Path $releaseDir "web_dashboard"
if (Test-Path $dashboardSource) {
    if (Test-Path $dashboardDest) {
        Remove-Item -Recurse -Force $dashboardDest
    }
    Copy-Item -Recurse $dashboardSource $dashboardDest
    Write-Host "  copied web_dashboard"
} else {
    throw "web_dashboard directory not found at: $dashboardSource"
}

Write-Host "==> Prepare installer output directory" -ForegroundColor Cyan
if (-not (Test-Path $installerOutDir)) {
    New-Item -ItemType Directory -Path $installerOutDir -Force | Out-Null
}

Write-Host "==> Build installer with Inno Setup" -ForegroundColor Cyan
iscc "/O$installerOutDir" $installerScript
$rc = $LASTEXITCODE
if ($rc -ne 0) { throw "iscc failed with exit code $rc" }

Write-Host ""
Write-Host "Done. Installer is under: $installerOutDir" -ForegroundColor Yellow
Get-ChildItem $installerOutDir | ForEach-Object { Write-Host "  $($_.Name)  ($([math]::Round($_.Length / 1MB, 1)) MB)" }
