# OTA Update System Testing Guide

This document describes how to test the Skotiq OTA (Over-The-Air) update system, specifically the LAN push functionality for pushing updates from your development machine to your imaging laptop.

## Quick Start

### Local Testing (Mock Receiver)

Test the complete push workflow without needing a real target machine:

```powershell
# From repo root
.\scripts\test_lan_push.ps1 -MockReceiver
```

This will:
1. Build an update package (or use existing)
2. Start a mock receiver on localhost
3. Discover the mock receiver
4. Push the update package
5. Verify the transfer completed

### Real Network Testing

With Skotiq running on your imaging laptop:

```powershell
# Discover Skotiq instances on the network
.\scripts\test_lan_push.ps1 -DiscoveryOnly

# Push to a specific machine
.\scripts\test_lan_push.ps1 -Target 192.168.1.50

# Push to all discovered machines
.\scripts\test_lan_push.ps1
```

## Test Scripts

### `test_lan_push.ps1`

End-to-end test script for LAN push functionality.

**Parameters:**
- `-MockReceiver` - Start a mock receiver for local testing
- `-Target <ip>` - Push to a specific IP address
- `-SkipBuild` - Skip building update package (use existing)
- `-DiscoveryOnly` - Only test discovery, don't push
- `-Verbose` - Show detailed output

**Examples:**

```powershell
# Full local test with mock
.\scripts\test_lan_push.ps1 -MockReceiver

# Test discovery only
.\scripts\test_lan_push.ps1 -DiscoveryOnly

# Push to imaging laptop
.\scripts\test_lan_push.ps1 -Target 192.168.1.50 -SkipBuild

# Verbose output
.\scripts\test_lan_push.ps1 -MockReceiver -Verbose
```

### `test_update_system.ps1`

Comprehensive test runner for the entire update system.

**Parameters:**
- `-UnitOnly` - Only run Dart unit tests
- `-E2EOnly` - Only run end-to-end tests
- `-RealNetwork` - Include real network discovery test
- `-Target <ip>` - Specific IP for network tests

**Examples:**

```powershell
# Run all tests
.\scripts\test_update_system.ps1

# Unit tests only
.\scripts\test_update_system.ps1 -UnitOnly

# Include real network test
.\scripts\test_update_system.ps1 -RealNetwork

# Test against specific machine
.\scripts\test_update_system.ps1 -Target 192.168.1.50
```

## Dart Unit Tests

The `packages/skotiq_updater` package includes unit tests for the LAN push protocol:

```powershell
cd packages/skotiq_updater
dart pub get
dart test test/lan_push_test.dart
```

Tests cover:
- Discovery protocol (UDP broadcast/response)
- Push protocol (TCP manifest + package transfer)
- Large file transfer handling
- Error conditions (connection refused, busy receiver)

## Manual Testing Workflow

### Step 1: Build Update Package

```powershell
# Build the app and create update package
.\scripts\build_update_package.ps1

# Or skip build if you have a recent build
.\scripts\build_update_package.ps1 -SkipBuild
```

This creates:
- `apps/desktop/build/update/skotiq-<version>-windows-x64.zip`
- `apps/desktop/build/update/manifest.json`
- `apps/desktop/build/update/skotiq-update.zip` (generic name for pusher)

### Step 2: Discover Targets

```powershell
.\tools\update_pusher\push_update.ps1 -Discover
```

Expected output:
```
Skotiq Update Pusher
========================

Discovering Skotiq instances...

  Found: Skotiq v2.0.0 (192.168.1.50:45680)

Found 1 instance(s).
```

### Step 3: Push Update

```powershell
# Push to specific target
.\tools\update_pusher\push_update.ps1 -Target 192.168.1.50

# Push to all discovered targets
.\tools\update_pusher\push_update.ps1 -All
```

Expected output:
```
Skotiq Update Pusher
========================

Pushing to 192.168.1.50:45680...
  Version: 2.0.0
  Package size: 37.2 MB
  Connected.
  Manifest sent.
  Uploading: 100%
  Success! Update staged on 192.168.1.50
```

### Step 4: Verify on Target

On the imaging laptop:
1. Skotiq should show an "Update Ready" banner
2. Check `%APPDATA%\Skotiq\updates\staging\ready.json` exists
3. The extracted files should be in `%APPDATA%\Skotiq\updates\staging\extracted\`

## Troubleshooting

### No targets discovered

1. **Firewall**: Ensure UDP port 45679 and TCP port 45680 are allowed
2. **Same network**: Both machines must be on the same local network
3. **Skotiq running**: The target must have Skotiq running with LAN push enabled

```powershell
# Check if ports are listening on target machine
netstat -an | Select-String "45679|45680"
```

### Push fails to connect

1. **Firewall on target**: Allow incoming TCP on port 45680
2. **Busy receiver**: Check if another push is in progress
3. **Wrong IP**: Verify the target IP is correct

### Package verification fails

1. **Incomplete transfer**: Check network stability
2. **Size mismatch**: Rebuild the update package
3. **Corrupt package**: Delete and rebuild: `.\scripts\build_update_package.ps1`

### Mock receiver doesn't start

1. **Port in use**: Check if port 45680 is already used
2. **Dart not found**: Ensure Dart SDK is in PATH
3. **Permissions**: Run PowerShell as Administrator

## OTA signing keys (owner provisioning step)

**OTA auto-update is fail-closed. New builds trust the production public key by default.** Both the HTTPS
pull path (`UpdateService.downloadAndStage`) and the LAN push receiver
(`LanPushReceiver.startServer`) refuse to stage an update unless it carries an
Ed25519 signature that verifies against a trusted public key compiled into the
running build. A correct SHA-256 against an attacker-supplied manifest is **not**
sufficient — that is the SEC-001 supply-chain hole this guard closes. Update
sources must also use `https://`; plaintext `http://` is rejected unless the
build explicitly opts in via `allowInsecureUpdateSource` (intended only for
trusted loopback testing).

The production Ed25519 pair was provisioned on 2026-10-08 in the repository's
`SKOTIQ_UPDATE_PUBLIC_KEY` and `SKOTIQ_UPDATE_PRIVATE_KEY` Actions secrets.
The matching public key is also the default in `UpdateVerifier`, so local builds
trust production releases without an environment override. The private seed is
never stored in the repository. Existing installed builds without a trusted key
need a manual installation of a new build before they can authenticate updates.

The steps below describe provisioning a replacement pair; keep the existing
private key for normal releases.

### 1. Generate an Ed25519 key pair (one time)

```dart
// dart run with package:cryptography on PATH
import 'dart:convert';
import 'package:cryptography/cryptography.dart';

Future<void> main() async {
  final algo = Ed25519();
  final kp = await algo.newKeyPair();
  final priv = await kp.extractPrivateKeyBytes(); // 32-byte seed
  final pub = (await kp.extractPublicKey()).bytes;
  print('PRIVATE (keep secret):  ${base64Encode(priv)}');
  print('PUBLIC  (ship in app):  ${base64Encode(pub)}');
}
```

Store the **private** key in a secret manager. Never commit it.

### 2. Embed the PUBLIC key in the shipped app build

For a testing or rotation key, set the env var before the release build to
override the built-in production public key via `--dart-define`:

```powershell
$env:SKOTIQ_UPDATE_PUBLIC_KEY = "<base64 vendor public key>"
.\scripts\package_windows.ps1
```

`package_windows.ps1` passes
`--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=$env:SKOTIQ_UPDATE_PUBLIC_KEY`
to `flutter build windows --release` only when the variable is nonempty.
Without it, the app uses its built-in production key. An explicitly empty
`--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY=` disables trust for testing.
CI passes its public-key secret explicitly; keep it paired with the signing seed.

### 3. Sign each manifest with the PRIVATE key

Set the env var before building the update package so the manifest is signed:

```powershell
$env:SKOTIQ_UPDATE_PRIVATE_KEY = "<base64 32-byte private seed>"
.\scripts\build_update_package.ps1
```

`build_update_package.ps1` packages and signs through
`packages/skotiq_updater/tool/build_update_manifest.dart` (so `dart` and a
resolved `packages/skotiq_updater` are needed) when
`SKOTIQ_UPDATE_PRIVATE_KEY` is present. A manifest signed with a private key
whose public half is **not** embedded in the target build cannot be applied.

### Result

- Public key embedded **and** manifest signed by the matching private key →
  OTA updates apply.
- Public key missing, or manifest unsigned, or signature mismatch, or non-https
  source → update is refused (fail-closed, no hash-only acceptance).

## Network Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 45679 | UDP | Discovery broadcast/response |
| 45680 | TCP | Update push file transfer |

## Protocol Details

### Discovery Protocol

1. Pusher broadcasts `SKOTIQ_UPDATE_PUSH` to UDP port 45679
2. Running Skotiq instances respond with JSON:
   ```json
   SKOTIQ_UPDATE_TARGET:{
     "name": "Skotiq",
     "version": "2.0.0",
     "buildNumber": 42,
     "pushPort": 45680,
     "isReceiving": false
   }
   ```

### Push Protocol

1. Pusher connects to TCP port 45680
2. Sends 4-byte manifest length (big-endian)
3. Sends manifest JSON
4. Streams ZIP package data
5. Receiver responds with status JSON:
   ```json
   {"status": "complete", "version": "2.0.0"}
   ```

## CI Integration

### Signed manifest publishing (release pipeline)

`.github/workflows/release.yml` produces and publishes a signed OTA manifest as
part of every tagged release. The Windows job:

1. Bakes `SKOTIQ_UPDATE_PUBLIC_KEY` into the binary via `--dart-define` on
   `flutter build windows --release`.
2. Builds + stages `updater.exe`, Authenticode-signs the Release binaries, then
   runs `scripts/build_update_package.ps1 -SkipBuild -SkipUpdaterBuild
   -NoPusherCopy -DownloadUrl <per-tag asset URL>` in the
   **"Package + sign OTA manifest"** step. With `SKOTIQ_UPDATE_PRIVATE_KEY`
   present, `manifest.json` is signed against the canonical payload the runtime
   verifier checks; absent, the manifest is emitted unsigned (OTA stays
   fail-closed-disabled).
3. Publishes `manifest-windows-x64.json` alongside
   `skotiq-<version>-windows-x64.zip`.

The Linux and Android jobs bake the same public key into `flutter build linux`
and `flutter build apk`, and sign their manifests through
`packages/skotiq_updater/tool/build_update_manifest.dart`, the same tool
`build_update_package.ps1` calls for Windows. `build_update_manifest_tool_test.dart`
hands its output to the real verifier, and the release workflow checks every
published manifest against the public key before publishing.

Secret names, generation one-liners, the GitHub-Releases hosting layout, and
the fail-closed contract are documented in
[`release-signing.md`](release-signing.md).

## How a shipped build finds an update

There is no update server to run. On startup the app asks the GitHub Releases
API for the newest release on its channel, picks the manifest asset matching
its own platform and architecture, and hands that manifest to the same
verification the LAN-push path uses. Setting `SKOTIQ_UPDATE_SERVER`
overrides this with the older `/api/version` + manifest-URL source, which is
how an appliance is pointed at a private build host and how the tests drive a
loopback mock.

Checks run at most every 12 hours, and the prompt is held back while a
sequence is running, the camera is exposing or the mount is slewing. The
update is still found either way and waits in Settings > About, and the offer
arrives on its own once the rig goes idle, so a release found at the start of
a night is not sat on until the next scheduled check. "Not now" silences that
version for three days; "Skip this version" silences it for good; a newer
release asks again either way.

A release that carries no manifest this host can install — an older release
built before per-target manifests, which published a single `manifest.json`
for whichever platform built it — reads as "no update for you here" rather
than as a failed check. A manifest *named* for this host that describes a
different one is a packaging fault and stays a loud error.

Android cannot swap its own files, so there the manifest describes the APK
itself: the app verifies the signature and the hash, then hands the file to
Android's package installer, which applies its own signature check. Desktop
continues to stage a tree and swap it with the `updater` helper binary.

### Update-system self-tests

Add to your CI pipeline:

```yaml
- name: Test OTA Update System
  run: |
    .\scripts\test_update_system.ps1 -UnitOnly
```

For full E2E testing (requires mock receiver):

```yaml
- name: Test OTA Update System E2E
  run: |
    .\scripts\test_update_system.ps1
```
