<#
.SYNOPSIS
    Run all OTA update system tests.

.DESCRIPTION
    This script runs the complete test suite for the Skotiq OTA update system:
    1. Dart unit tests for LAN push protocol
    2. End-to-end LAN push test with mock receiver
    3. Optional: Real network test to imaging laptop

.PARAMETER UnitOnly
    Only run Dart unit tests, skip E2E tests.

.PARAMETER E2EOnly
    Only run E2E tests, skip unit tests.

.PARAMETER RealNetwork
    Include real network discovery test (requires Skotiq running on imaging laptop).

.PARAMETER Target
    Specific IP to test against for real network tests.

.EXAMPLE
    .\test_update_system.ps1
    Run unit tests and E2E mock test.

.EXAMPLE
    .\test_update_system.ps1 -RealNetwork
    Run all tests including real network discovery.

.EXAMPLE
    .\test_update_system.ps1 -UnitOnly
    Only run Dart unit tests.
#>

param(
    [switch]$UnitOnly,
    [switch]$E2EOnly,
    [switch]$RealNetwork,
    [string]$Target
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot

$totalPassed = 0
$totalFailed = 0

try {
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host " Skotiq OTA Update System Tests" -ForegroundColor Magenta
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host ""

    # ===========================================
    # Dart Unit Tests
    # ===========================================
    if (-not $E2EOnly) {
        Write-Host "==> Running Dart Unit Tests" -ForegroundColor Cyan
        Write-Host ""

        Push-Location "packages/skotiq_updater"

        try {
            # Get dependencies
            Write-Host "Getting dependencies..." -ForegroundColor Gray
            dart pub get 2>&1 | Out-Null

            # Run tests
            $testResult = dart test test/lan_push_test.dart 2>&1
            $testResult | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host "[PASS] Dart unit tests passed" -ForegroundColor Green
                $totalPassed++
            } else {
                Write-Host ""
                Write-Host "[FAIL] Dart unit tests failed" -ForegroundColor Red
                $totalFailed++
            }
        } catch {
            Write-Host "[FAIL] Dart unit tests error: $_" -ForegroundColor Red
            $totalFailed++
        }

        Pop-Location
        Write-Host ""
    }

    # ===========================================
    # E2E Mock Receiver Test
    # ===========================================
    if (-not $UnitOnly) {
        Write-Host "==> Running E2E Mock Receiver Test" -ForegroundColor Cyan
        Write-Host ""

        try {
            $e2eResult = & "$PSScriptRoot\test_lan_push.ps1" -MockReceiver -SkipBuild 2>&1
            $e2eResult | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host "[PASS] E2E mock receiver test passed" -ForegroundColor Green
                $totalPassed++
            } else {
                Write-Host ""
                Write-Host "[FAIL] E2E mock receiver test failed" -ForegroundColor Red
                $totalFailed++
            }
        } catch {
            Write-Host "[FAIL] E2E mock receiver test error: $_" -ForegroundColor Red
            $totalFailed++
        }

        Write-Host ""
    }

    # ===========================================
    # Real Network Test (optional)
    # ===========================================
    if ($RealNetwork -or $Target) {
        Write-Host "==> Running Real Network Test" -ForegroundColor Cyan
        Write-Host ""

        try {
            if ($Target) {
                $networkResult = & "$PSScriptRoot\test_lan_push.ps1" -Target $Target -SkipBuild 2>&1
            } else {
                $networkResult = & "$PSScriptRoot\test_lan_push.ps1" -SkipBuild 2>&1
            }
            $networkResult | ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -eq 0) {
                Write-Host ""
                Write-Host "[PASS] Real network test passed" -ForegroundColor Green
                $totalPassed++
            } else {
                Write-Host ""
                Write-Host "[FAIL] Real network test failed" -ForegroundColor Red
                $totalFailed++
            }
        } catch {
            Write-Host "[WARN] Real network test error: $_" -ForegroundColor Yellow
            Write-Host "       (This may be expected if no Skotiq instances are running)" -ForegroundColor Gray
        }

        Write-Host ""
    }

    # ===========================================
    # Summary
    # ===========================================
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host " Test Summary" -ForegroundColor Magenta
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Passed: $totalPassed" -ForegroundColor Green
    Write-Host "  Failed: $totalFailed" -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Gray" })
    Write-Host ""

    if ($totalFailed -eq 0) {
        Write-Host "All tests passed!" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "Some tests failed." -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}
