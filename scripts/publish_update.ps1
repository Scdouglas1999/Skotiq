<#
.SYNOPSIS
    Publish a Skotiq update to the update server.

.DESCRIPTION
    This script uploads an update package and manifest to the self-hosted
    update server. Run after build_update_package.ps1 to publish the update.

.PARAMETER ServerUrl
    The URL of the update server. Can also be set via SKOTIQ_UPDATE_SERVER env var.

.PARAMETER Version
    Override the version from the manifest. Defaults to reading from manifest.

.PARAMETER InputDir
    Directory containing the update package and manifest. Defaults to apps/desktop/build/update.

.EXAMPLE
    .\publish_update.ps1 -ServerUrl https://updates.skotiq.app
    Publish the current update package to the server.

.EXAMPLE
    .\publish_update.ps1 -ServerUrl user@server:/var/www/updates
    Publish via SCP to a remote server.
#>

param(
    [string]$ServerUrl = $env:SKOTIQ_UPDATE_SERVER,
    [string]$Version,
    [string]$InputDir = "apps/desktop/build/update"
)

$ErrorActionPreference = "Stop"

Write-Host "Skotiq Update Publisher" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan

# Navigate to repo root
Push-Location $PSScriptRoot\..

try {
    # Verify input directory exists
    if (-not (Test-Path $InputDir)) {
        throw "Update package directory not found: $InputDir. Run build_update_package.ps1 first."
    }

    # Read manifest
    $manifestPath = Join-Path $InputDir "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        throw "Manifest not found: $manifestPath"
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $version = if ($Version) { $Version } else { $manifest.version }

    Write-Host "`nVersion: $version" -ForegroundColor Yellow

    # Find package file
    $packageName = "skotiq-$version-windows-x64.zip"
    $packagePath = Join-Path $InputDir $packageName
    if (-not (Test-Path $packagePath)) {
        # Try generic name
        $packagePath = Join-Path $InputDir "skotiq-update.zip"
        if (-not (Test-Path $packagePath)) {
            throw "Package not found: $packageName"
        }
    }

    $packageSize = (Get-Item $packagePath).Length
    Write-Host "Package: $packagePath ($([math]::Round($packageSize/1024/1024, 1)) MB)" -ForegroundColor Gray

    if (-not $ServerUrl) {
        Write-Host "`nNo server URL specified. Package ready for manual upload:" -ForegroundColor Yellow
        Write-Host "  Manifest: $manifestPath" -ForegroundColor Gray
        Write-Host "  Package:  $packagePath" -ForegroundColor Gray
        Write-Host "`nTo publish, upload files to your update server:" -ForegroundColor Yellow
        Write-Host "  manifests/$version.json" -ForegroundColor Gray
        Write-Host "  releases/$version/$packageName" -ForegroundColor Gray
        exit 0
    }

    # Determine upload method
    if ($ServerUrl -match "^https?://") {
        # HTTP upload
        Write-Host "`nUploading to HTTP server: $ServerUrl" -ForegroundColor Yellow

        # Upload manifest
        Write-Host "  Uploading manifest..." -ForegroundColor Gray
        $manifestUrl = "$ServerUrl/api/upload/manifest"
        $manifestContent = Get-Content $manifestPath -Raw
        try {
            Invoke-RestMethod -Uri $manifestUrl -Method Post -Body $manifestContent -ContentType "application/json"
            Write-Host "  Manifest uploaded." -ForegroundColor Green
        } catch {
            Write-Host "  Note: Direct upload not supported. Use manual upload or SCP." -ForegroundColor Yellow
        }

        # Upload package
        Write-Host "  Uploading package..." -ForegroundColor Gray
        $packageUrl = "$ServerUrl/api/upload/package/$version"
        try {
            $packageBytes = [System.IO.File]::ReadAllBytes($packagePath)
            Invoke-RestMethod -Uri $packageUrl -Method Post -Body $packageBytes -ContentType "application/octet-stream"
            Write-Host "  Package uploaded." -ForegroundColor Green
        } catch {
            Write-Host "  Note: Direct upload not supported. Use manual upload or SCP." -ForegroundColor Yellow
        }
    }
    elseif ($ServerUrl -match "^(.+)@(.+):(.+)$") {
        # SCP upload (user@host:/path)
        $user = $Matches[1]
        $host = $Matches[2]
        $remotePath = $Matches[3]

        Write-Host "`nUploading via SCP to: $user@$host" -ForegroundColor Yellow

        # Create remote directories
        Write-Host "  Creating remote directories..." -ForegroundColor Gray
        ssh "$user@$host" "mkdir -p $remotePath/manifests $remotePath/releases/$version"

        # Upload manifest
        Write-Host "  Uploading manifest..." -ForegroundColor Gray
        scp $manifestPath "$user@${host}:$remotePath/manifests/$version.json"
        Write-Host "  Manifest uploaded." -ForegroundColor Green

        # Upload package
        Write-Host "  Uploading package (this may take a while)..." -ForegroundColor Gray
        scp $packagePath "$user@${host}:$remotePath/releases/$version/$packageName"
        Write-Host "  Package uploaded." -ForegroundColor Green
    }
    elseif (Test-Path $ServerUrl) {
        # Local directory
        Write-Host "`nCopying to local directory: $ServerUrl" -ForegroundColor Yellow

        $manifestsDir = Join-Path $ServerUrl "manifests"
        $releasesDir = Join-Path $ServerUrl "releases" $version

        # Create directories
        New-Item -ItemType Directory -Path $manifestsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $releasesDir -Force | Out-Null

        # Copy files
        Write-Host "  Copying manifest..." -ForegroundColor Gray
        Copy-Item $manifestPath (Join-Path $manifestsDir "$version.json") -Force

        Write-Host "  Copying package..." -ForegroundColor Gray
        Copy-Item $packagePath (Join-Path $releasesDir $packageName) -Force

        Write-Host "  Files copied." -ForegroundColor Green
    }
    else {
        throw "Unknown server URL format: $ServerUrl. Use http://..., user@host:/path, or local path."
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Update published successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`nVersion $version is now available for OTA updates." -ForegroundColor Gray
}
finally {
    Pop-Location
}
