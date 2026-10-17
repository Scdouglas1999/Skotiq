<#
.SYNOPSIS
    Push Skotiq updates to instances on the local network.

.DESCRIPTION
    This script wraps the push_update.dart CLI tool to push updates to
    Skotiq instances discovered on the local network.

.PARAMETER Discover
    Discover Skotiq instances on the network without pushing.

.PARAMETER Target
    Push update to a specific IP address.

.PARAMETER All
    Push update to all discovered Skotiq instances.

.PARAMETER Package
    Path to the update package ZIP file. Defaults to auto-detect.

.PARAMETER Manifest
    Path to the manifest.json file. Defaults to auto-detect.

.PARAMETER Secret
    LAN push shared secret. Can also be provided via
    SKOTIQ_UPDATE_PUSH_SECRET.

.EXAMPLE
    .\push_update.ps1 -Discover
    Discover all Skotiq instances on the network.

.EXAMPLE
    .\push_update.ps1 -All
    Push update to all discovered instances.

.EXAMPLE
    .\push_update.ps1 -Target 192.168.1.50
    Push update to a specific machine.
#>

param(
    [switch]$Discover,
    [string]$Target,
    [switch]$All,
    [string]$Package,
    [string]$Manifest,
    [string]$Secret
)

$ErrorActionPreference = "Stop"

# Navigate to repo root
$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (Test-Path "$PSScriptRoot\..\..\melos.yaml") {
    $RepoRoot = Resolve-Path "$PSScriptRoot\..\.."
}
Push-Location $RepoRoot

try {
    # Build arguments
    $args = @()

    if ($Discover) {
        $args += "--discover"
    }
    elseif ($All -or $Target) {
        $args += "--push"

        if ($All) {
            $args += "--all"
        }
        elseif ($Target) {
            $args += "--target"
            $args += $Target
        }

        if ($Package) {
            $args += "--package"
            $args += $Package
        }

        if ($Manifest) {
            $args += "--manifest"
            $args += $Manifest
        }

        if ($Secret) {
            $args += "--secret"
            $args += $Secret
        }
    }
    else {
        Write-Host "Skotiq Update Pusher" -ForegroundColor Cyan
        Write-Host "========================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Usage:"
        Write-Host "  .\push_update.ps1 -Discover              # Find Skotiq instances"
        Write-Host "  .\push_update.ps1 -All                   # Push to all instances"
        Write-Host "  .\push_update.ps1 -Target <ip>           # Push to specific IP"
        Write-Host "  .\push_update.ps1 -All -Secret <secret>  # Push with auth secret"
        Write-Host ""
        Write-Host "First run build_update_package.ps1 to create the update package."
        exit 0
    }

    # Run the Dart CLI tool
    Write-Host "Running: dart run tools/update_pusher/push_update.dart $($args -join ' ')" -ForegroundColor Gray
    dart run tools/update_pusher/push_update.dart @args
}
finally {
    Pop-Location
}
