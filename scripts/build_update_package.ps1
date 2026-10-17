<#
.SYNOPSIS
    Build a Skotiq update package for OTA distribution.

.DESCRIPTION
    Creates the ZIP update package and its (signed, when
    SKOTIQ_UPDATE_PRIVATE_KEY is set) manifest from the built Flutter
    desktop release, through packages/skotiq_updater/tool/
    build_update_manifest.dart: the same packager and signer the Linux and
    Android release jobs use. Run after 'melos run dev:norun' or a release
    build.

.PARAMETER SkipBuild
    Skip the Flutter build step (use existing build output).

.PARAMETER SkipUpdaterBuild
    Skip building/copying updater.exe; require it to be staged in the release
    directory already. Used by CI, which builds + Authenticode-signs updater.exe
    in a prior step so the signed binary ends up inside the canonical archive.

.PARAMETER OutputDir
    Output directory for the update package. Defaults to apps/desktop/build/update.

.PARAMETER DownloadUrl
    URL baked into (and signed into) the manifest's downloadUrl. Must equal the
    real published asset URL, since it is part of the signed payload. Defaults to
    the legacy updates.skotiq.app path for local pushes.

.PARAMETER NoPusherCopy
    Skip writing the generic skotiq-update.zip copy used by the LAN pusher.
    Used by CI so the publish job's asset sweep does not pick up a stray zip.

.EXAMPLE
    .\build_update_package.ps1
    Build Flutter app and create update package.

.EXAMPLE
    .\build_update_package.ps1 -SkipBuild
    Create update package from existing build output.
#>

param(
    [switch]$SkipBuild,
    [switch]$SkipUpdaterBuild,
    [string]$OutputDir = "apps/desktop/build/update",
    [string]$DownloadUrl = "",
    [switch]$NoPusherCopy
)

$ErrorActionPreference = "Stop"

Write-Host "Skotiq Update Package Builder" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan

# Navigate to repo root
Push-Location $PSScriptRoot\..

try {
    # Read version info
    Write-Host "`nReading version.yaml..." -ForegroundColor Yellow
    $versionYaml = Get-Content "version.yaml" -Raw
    $version = [regex]::Match($versionYaml, 'version:\s*"?([^"\s]+)"?').Groups[1].Value
    $buildNumber = [int][regex]::Match($versionYaml, 'build_number:\s*(\d+)').Groups[1].Value
    $channel = [regex]::Match($versionYaml, 'channel:\s*"?([^"\s]+)"?').Groups[1].Value

    Write-Host "  Version: $version" -ForegroundColor Gray
    Write-Host "  Build: $buildNumber" -ForegroundColor Gray
    Write-Host "  Channel: $channel" -ForegroundColor Gray

    # OTA is fail-closed: manifests must be signed by the key trusted by the
    # installed app. New builds embed the production public key by default;
    # SKOTIQ_UPDATE_PUBLIC_KEY can override it for testing or rotation.
    # SKOTIQ_UPDATE_PRIVATE_KEY supplies the matching signing seed below.

    # Build if not skipping
    if (-not $SkipBuild) {
        Write-Host "`nBuilding Skotiq..." -ForegroundColor Yellow
        melos run dev:norun
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed"
        }
    }

    # Verify release build exists
    $releaseDir = "apps/desktop/build/windows/x64/runner/Release"
    if (-not (Test-Path $releaseDir)) {
        throw "Release build not found at $releaseDir. Run 'melos run dev:norun' first."
    }

    # Build the updater executable (required for OTA updates to work). CI builds
    # and Authenticode-signs it in an earlier step, then passes -SkipUpdaterBuild
    # so the signed binary stays in the archive; here we only assert its presence.
    $rustDir = "native/skotiq_native"
    $updaterDest = Join-Path $releaseDir "updater.exe"
    if ($SkipUpdaterBuild) {
        if (-not (Test-Path $updaterDest)) {
            throw "-SkipUpdaterBuild set but updater.exe is not staged at $updaterDest"
        }
        Write-Host "`nReusing pre-staged updater.exe" -ForegroundColor Yellow
    } else {
        Write-Host "`nBuilding updater.exe..." -ForegroundColor Yellow
        Push-Location $rustDir
        cargo build --release --package skotiq_updater
        if ($LASTEXITCODE -ne 0) {
            Pop-Location
            throw "Updater build failed"
        }
        Pop-Location

        # Copy updater.exe to the release directory
        $updaterSource = Join-Path $rustDir "target/release/updater.exe"
        if (-not (Test-Path $updaterSource)) {
            throw "Updater not found at $updaterSource"
        }
        Copy-Item $updaterSource $updaterDest -Force
        Write-Host "  Copied updater.exe to release directory" -ForegroundColor Gray
    }

    # Create output directory
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Package, hash and sign with the same Dart tool the Linux and Android
    # release jobs use. This script used to zip with Compress-Archive, hash in
    # PowerShell and sign a hand-copied version of the verifier's canonical
    # payload; any drift in that copy (field order, date formatting, a key
    # saved with a trailing newline) would produce a manifest every Windows
    # install refuses. The tool builds the payload with
    # UpdateVerifier.canonicalManifestPayload itself and trims the key.
    $packageName = "skotiq-$version-windows-x64.zip"
    $resolvedUrl = if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        "https://updates.skotiq.app/releases/$version/$packageName"
    } else {
        $DownloadUrl
    }
    $packagePath = Join-Path $OutputDir $packageName
    if (Test-Path $packagePath) {
        Remove-Item $packagePath -Force
    }
    $absRelease = (Resolve-Path $releaseDir).Path
    $absOutput = (Resolve-Path $OutputDir).Path

    Write-Host "`nPackaging and signing with tool/build_update_manifest.dart..." -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($env:SKOTIQ_UPDATE_PRIVATE_KEY)) {
        Write-Host "  OTA manifest unsigned (no SKOTIQ_UPDATE_PRIVATE_KEY); update is fail-closed-disabled" -ForegroundColor DarkYellow
    }
    Push-Location "packages/skotiq_updater"
    try {
        dart run tool/build_update_manifest.dart `
            --payload $absRelease `
            --out-dir $absOutput `
            --version $version `
            --build-number $buildNumber `
            --platform windows `
            --arch x64 `
            --package-name $packageName `
            --download-url $resolvedUrl
        if ($LASTEXITCODE -ne 0) {
            throw "Packaging/signing failed"
        }
    }
    finally {
        Pop-Location
    }

    # The release workflow and the LAN pusher read manifest.json.
    $manifestPath = Join-Path $OutputDir "manifest.json"
    Move-Item (Join-Path $OutputDir "manifest-windows-x64.json") $manifestPath -Force

    # Also create a generic name for the pusher tool (skipped in CI so the
    # publish job's asset sweep does not pick up a stray zip).
    if (-not $NoPusherCopy) {
        Copy-Item $packagePath (Join-Path $OutputDir "skotiq-update.zip") -Force
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Update package created successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`nPackage: $packagePath" -ForegroundColor Gray
    Write-Host "Manifest: $manifestPath" -ForegroundColor Gray
    Write-Host "`nTo push to imaging laptop:" -ForegroundColor Yellow
    Write-Host "  .\tools\update_pusher\push_update.ps1 -Discover" -ForegroundColor White
    Write-Host "  .\tools\update_pusher\push_update.ps1 -All" -ForegroundColor White
}
finally {
    Pop-Location
}
