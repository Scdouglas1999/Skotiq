<#
.SYNOPSIS
    Test the LAN push update functionality.

.DESCRIPTION
    This script tests the complete LAN push update workflow:
    1. Builds a test update package
    2. Starts a mock receiver (optional)
    3. Tests network discovery
    4. Pushes update to discovered targets or mock receiver
    5. Verifies the transfer completed successfully

.PARAMETER MockReceiver
    Start a mock receiver on this machine for local testing.

.PARAMETER Target
    Push to a specific IP address instead of discovering.

.PARAMETER SkipBuild
    Skip building the update package (use existing package).

.PARAMETER DiscoveryOnly
    Only test network discovery, don't push updates.

.PARAMETER Verbose
    Show detailed output during testing.

.EXAMPLE
    .\test_lan_push.ps1 -MockReceiver
    Start a mock receiver and push to it (full local test).

.EXAMPLE
    .\test_lan_push.ps1 -DiscoveryOnly
    Only test if Skotiq instances can be discovered on the network.

.EXAMPLE
    .\test_lan_push.ps1 -Target 192.168.1.50
    Push to a specific imaging laptop IP address.

.EXAMPLE
    .\test_lan_push.ps1 -SkipBuild -Target 192.168.1.50
    Push existing package to a specific machine.
#>

param(
    [switch]$MockReceiver,
    [string]$Target,
    [switch]$SkipBuild,
    [switch]$DiscoveryOnly,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Step($message) {
    Write-Host "`n==> $message" -ForegroundColor Cyan
}

function Write-Success($message) {
    Write-Host "[PASS] $message" -ForegroundColor Green
}

function Write-Failure($message) {
    Write-Host "[FAIL] $message" -ForegroundColor Red
}

function Write-Info($message) {
    Write-Host "     $message" -ForegroundColor Gray
}

function Write-Warning($message) {
    Write-Host "[WARN] $message" -ForegroundColor Yellow
}

# Test results tracking
$script:testsPassed = 0
$script:testsFailed = 0
$script:testsSkipped = 0

function Test-Assertion($name, [scriptblock]$test) {
    try {
        $result = & $test
        if ($result) {
            Write-Success $name
            $script:testsPassed++
            return $true
        } else {
            Write-Failure $name
            $script:testsFailed++
            return $false
        }
    } catch {
        Write-Failure "$name - Exception: $_"
        $script:testsFailed++
        return $false
    }
}

# Navigate to repo root
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot

try {
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host " Skotiq LAN Push Update Test" -ForegroundColor Magenta
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Test Configuration:" -ForegroundColor White
    Write-Host "  MockReceiver: $MockReceiver" -ForegroundColor Gray
    Write-Host "  Target: $(if ($Target) { $Target } else { 'auto-discover' })" -ForegroundColor Gray
    Write-Host "  SkipBuild: $SkipBuild" -ForegroundColor Gray
    Write-Host "  DiscoveryOnly: $DiscoveryOnly" -ForegroundColor Gray

    # ===========================================
    # PHASE 1: Prerequisites Check
    # ===========================================
    Write-Step "Phase 1: Checking Prerequisites"

    Test-Assertion "Dart SDK installed" {
        $dartVersion = dart --version 2>&1
        $dartVersion -match "Dart SDK"
    }

    Test-Assertion "version.yaml exists" {
        Test-Path "version.yaml"
    }

    Test-Assertion "Update pusher tool exists" {
        Test-Path "tools/update_pusher/push_update.dart"
    }

    Test-Assertion "LAN push receiver exists" {
        Test-Path "packages/skotiq_updater/lib/src/services/lan_push_receiver.dart"
    }

    # ===========================================
    # PHASE 2: Build Update Package
    # ===========================================
    Write-Step "Phase 2: Update Package"

    $packageDir = "apps/desktop/build/update"
    $manifestPath = "$packageDir/manifest.json"
    $packagePath = "$packageDir/skotiq-update.zip"

    if ($SkipBuild) {
        Write-Info "Skipping build, checking for existing package..."

        Test-Assertion "Update package exists" {
            Test-Path $packagePath
        }

        Test-Assertion "Manifest exists" {
            Test-Path $manifestPath
        }
    } else {
        Write-Info "Building update package..."

        # Check if release build exists, if not we need to build
        $releaseDir = "apps/desktop/build/windows/x64/runner/Release"
        if (-not (Test-Path $releaseDir)) {
            Write-Warning "No release build found. Running dev:norun first..."
            Write-Info "This may take a few minutes..."

            try {
                dart pub global run melos run dev:norun 2>&1 | Out-Null
            } catch {
                Write-Warning "melos dev:norun failed, trying manual build..."
                Push-Location "apps/desktop"
                flutter build windows --release 2>&1 | Out-Null
                Pop-Location
            }
        }

        Test-Assertion "Release build exists" {
            Test-Path $releaseDir
        }

        # Build package using the script
        Write-Info "Creating update package..."
        try {
            & "$PSScriptRoot\build_update_package.ps1" -SkipBuild 2>&1 | ForEach-Object {
                if ($Verbose) { Write-Host "  $_" -ForegroundColor DarkGray }
            }
        } catch {
            Write-Warning "build_update_package.ps1 failed: $_"
        }

        Test-Assertion "Update package created" {
            Test-Path $packagePath
        }

        Test-Assertion "Manifest created" {
            Test-Path $manifestPath
        }
    }

    # Validate manifest format
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

        Test-Assertion "Manifest has version" {
            $null -ne $manifest.version -and $manifest.version.Length -gt 0
        }

        Test-Assertion "Manifest has compressedSize" {
            $manifest.compressedSize -gt 0
        }

        Test-Assertion "Manifest has files list" {
            $null -ne $manifest.files
        }

        Write-Info "Package version: $($manifest.version)"
        Write-Info "Package size: $([math]::Round($manifest.compressedSize/1024/1024, 2)) MB"
        Write-Info "Total files: $($manifest.files.PSObject.Properties.Count)"
    }

    # ===========================================
    # PHASE 3: Mock Receiver (if requested)
    # ===========================================
    $mockProcess = $null

    if ($MockReceiver) {
        Write-Step "Phase 3: Starting Mock Receiver"

        # Create a simple mock receiver script
        $mockReceiverScript = @'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int pushPort = 45680;
const int discoveryPort = 45679;
const String updatePushMessage = 'SKOTIQ_UPDATE_PUSH';
const String updateResponsePrefix = 'SKOTIQ_UPDATE_TARGET:';

void main() async {
  print('[MockReceiver] Starting mock update receiver...');

  // Start discovery responder
  final discoverySocket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    discoveryPort,
    reuseAddress: true,
  );

  discoverySocket.listen((event) {
    if (event == RawSocketEvent.read) {
      final datagram = discoverySocket.receive();
      if (datagram != null) {
        final message = utf8.decode(datagram.data);
        if (message == updatePushMessage) {
          print('[MockReceiver] Discovery request from ${datagram.address.address}');
          final response = updateResponsePrefix + jsonEncode({
            'name': 'MockReceiver',
            'version': '1.0.0',
            'buildNumber': 1,
            'pushPort': pushPort,
            'isReceiving': false,
          });
          discoverySocket.send(
            utf8.encode(response),
            datagram.address,
            datagram.port,
          );
          print('[MockReceiver] Sent discovery response');
        }
      }
    }
  });
  print('[MockReceiver] Discovery responder listening on port $discoveryPort');

  // Start push receiver
  final server = await ServerSocket.bind(InternetAddress.anyIPv4, pushPort);
  print('[MockReceiver] Push receiver listening on port $pushPort');
  print('[MockReceiver] Ready to receive updates...');
  print('');

  await for (final socket in server) {
    print('[MockReceiver] Connection from ${socket.remoteAddress.address}');
    await handleConnection(socket);
  }
}

Future<void> handleConnection(Socket socket) async {
  final buffer = BytesBuilder();
  int? manifestLength;
  Map<String, dynamic>? manifest;
  int receivedBytes = 0;
  int? expectedSize;

  await for (final chunk in socket) {
    buffer.add(chunk);

    // Read manifest length (4 bytes)
    if (manifestLength == null && buffer.length >= 4) {
      final bytes = buffer.takeBytes();
      manifestLength = ByteData.view(
        Uint8List.fromList(bytes.sublist(0, 4)).buffer
      ).getInt32(0, Endian.big);
      buffer.add(bytes.sublist(4));
      print('[MockReceiver] Manifest length: $manifestLength bytes');
    }

    // Read manifest
    if (manifest == null && manifestLength != null && buffer.length >= manifestLength) {
      final bytes = buffer.takeBytes();
      final manifestJson = utf8.decode(bytes.sublist(0, manifestLength));
      manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
      expectedSize = manifest['compressedSize'] as int;

      print('[MockReceiver] Receiving version: ${manifest['version']}');
      print('[MockReceiver] Expected size: ${(expectedSize! / 1024 / 1024).toStringAsFixed(2)} MB');

      // Count remaining bytes
      receivedBytes = bytes.length - manifestLength;
      buffer.add(bytes.sublist(manifestLength));

      // Send ack
      socket.write(jsonEncode({'status': 'receiving'}));
    }

    // Count package bytes
    if (manifest != null) {
      receivedBytes += chunk.length;
      final percent = (receivedBytes * 100 / expectedSize!).round();
      stdout.write('\r[MockReceiver] Receiving: $percent% (${(receivedBytes/1024/1024).toStringAsFixed(1)} MB)');
    }
  }

  print('');

  if (manifest != null && expectedSize != null) {
    if (receivedBytes >= expectedSize * 0.99) {  // Allow 1% tolerance
      print('[MockReceiver] Transfer complete!');
      print('[MockReceiver] Received: ${(receivedBytes/1024/1024).toStringAsFixed(2)} MB');
      socket.write(jsonEncode({
        'status': 'complete',
        'version': manifest['version'],
        'receivedBytes': receivedBytes,
      }));
    } else {
      print('[MockReceiver] Transfer incomplete: expected $expectedSize, got $receivedBytes');
      socket.write(jsonEncode({
        'status': 'error',
        'error': 'Incomplete transfer',
      }));
    }
  }

  await socket.close();
  print('[MockReceiver] Connection closed');
  print('[MockReceiver] Waiting for next connection...');
  print('');
}
'@

        # Write mock receiver to temp file
        $mockReceiverPath = Join-Path $env:TEMP "skotiq_mock_receiver.dart"
        $mockReceiverScript | Set-Content $mockReceiverPath -Encoding UTF8

        Write-Info "Starting mock receiver on ports 45679 (discovery) and 45680 (push)..."

        # Start mock receiver in background
        $mockProcess = Start-Process -FilePath "dart" -ArgumentList "run", $mockReceiverPath -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\mock_receiver_out.txt" -RedirectStandardError "$env:TEMP\mock_receiver_err.txt"

        # Wait for it to start
        Start-Sleep -Seconds 2

        Test-Assertion "Mock receiver started" {
            -not $mockProcess.HasExited
        }

        # Set target to localhost
        $Target = "127.0.0.1"
        Write-Info "Mock receiver running, will push to localhost"
    }

    # ===========================================
    # PHASE 4: Network Discovery Test
    # ===========================================
    Write-Step "Phase 4: Network Discovery Test"

    Write-Info "Sending discovery broadcast on port 45679..."

    # Run discovery
    $discoveryOutput = @()
    try {
        $discoveryOutput = dart run tools/update_pusher/push_update.dart --discover 2>&1
        $discoveryOutput | ForEach-Object {
            if ($Verbose -or $_ -match "Found:") {
                Write-Info $_
            }
        }
    } catch {
        Write-Warning "Discovery command failed: $_"
    }

    $foundTargets = $discoveryOutput | Where-Object { $_ -match "Found:" }
    $targetCount = if ($foundTargets) { @($foundTargets).Count } else { 0 }

    if ($MockReceiver) {
        Test-Assertion "Mock receiver discovered" {
            $targetCount -ge 1
        }
    } else {
        if ($targetCount -gt 0) {
            Write-Success "Discovered $targetCount Skotiq instance(s)"
            $foundTargets | ForEach-Object { Write-Info $_ }
        } else {
            Write-Warning "No Skotiq instances discovered on network"
            Write-Info "Make sure Skotiq is running on your imaging laptop"
            Write-Info "and both machines are on the same network."
            $script:testsSkipped++
        }
    }

    # ===========================================
    # PHASE 5: Push Update Test
    # ===========================================
    if (-not $DiscoveryOnly) {
        Write-Step "Phase 5: Push Update Test"

        if ($Target) {
            Write-Info "Pushing update to $Target..."

            $pushOutput = @()
            try {
                $pushOutput = dart run tools/update_pusher/push_update.dart --push --target $Target 2>&1
                $pushOutput | ForEach-Object {
                    if ($Verbose -or $_ -match "(Success|Error|Failed|complete)") {
                        Write-Info $_
                    }
                }
            } catch {
                Write-Warning "Push command failed: $_"
            }

            $success = $pushOutput | Where-Object { $_ -match "Success|complete" }

            Test-Assertion "Update pushed successfully" {
                $null -ne $success
            }

            if ($success) {
                Write-Info "Update successfully pushed to $Target!"
            }
        } elseif ($targetCount -gt 0) {
            Write-Info "Pushing update to all discovered targets..."

            $pushOutput = @()
            try {
                $pushOutput = dart run tools/update_pusher/push_update.dart --push --all 2>&1
                $pushOutput | ForEach-Object {
                    if ($Verbose) { Write-Info $_ }
                }
            } catch {
                Write-Warning "Push command failed: $_"
            }

            $successCount = @($pushOutput | Where-Object { $_ -match "Success" }).Count

            Test-Assertion "Updates pushed to targets" {
                $successCount -gt 0
            }
        } else {
            Write-Warning "No targets available for push test"
            Write-Info "Run with -MockReceiver for local testing"
            Write-Info "Or ensure Skotiq is running on imaging laptop"
            $script:testsSkipped++
        }
    } else {
        Write-Info "Skipping push test (DiscoveryOnly mode)"
        $script:testsSkipped++
    }

    # ===========================================
    # PHASE 6: Cleanup
    # ===========================================
    Write-Step "Phase 6: Cleanup"

    if ($mockProcess -and -not $mockProcess.HasExited) {
        Write-Info "Stopping mock receiver..."
        $mockProcess.Kill()
        $mockProcess.WaitForExit(5000)
        Write-Info "Mock receiver stopped"
    }

    # ===========================================
    # Test Summary
    # ===========================================
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host " Test Summary" -ForegroundColor Magenta
    Write-Host "======================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Passed:  $script:testsPassed" -ForegroundColor Green
    Write-Host "  Failed:  $script:testsFailed" -ForegroundColor $(if ($script:testsFailed -gt 0) { "Red" } else { "Gray" })
    Write-Host "  Skipped: $script:testsSkipped" -ForegroundColor $(if ($script:testsSkipped -gt 0) { "Yellow" } else { "Gray" })
    Write-Host ""

    if ($script:testsFailed -eq 0) {
        Write-Host "All tests passed!" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "Some tests failed. See above for details." -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host ""
    Write-Failure "Test script error: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed

    # Cleanup on error
    if ($mockProcess -and -not $mockProcess.HasExited) {
        $mockProcess.Kill()
    }

    exit 1
}
finally {
    Pop-Location
}
