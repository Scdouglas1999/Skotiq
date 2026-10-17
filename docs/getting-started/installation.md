# Installation Guide

This guide matches the official Skotiq 5.0.0 artifacts. Read the
[5.0.0 release notes](../release/v5.0.0.md),
[supported-hardware matrix](../supported-hardware-by-platform.md), and
[known limitations](../known-limitations.md) before connecting equipment.

Release engineering validates this guide against
`docs/release-notes-template.md`,
`docs/supported-hardware-by-platform.md`, `docs/known-limitations.md`,
`docs/production-readiness/linux-release-ci-recipe.md`, and
`docs/production-readiness/linux-release-package-metadata.json`. A Linux
artifact is not promoted without passing its recorded `runtimeSmokeChecks`.

## Downloads

Open the [Skotiq releases
page](https://github.com/Scdouglas1999/Skotiq/releases) and download the
artifact for your platform:

| Platform | 5.0.0 artifact | Distribution status |
| --- | --- | --- |
| Windows x64 | `skotiq-5.0.0-windows-x64.zip` | Unsigned portable beta |
| Linux x64 | `skotiq-5.0.0-linux-x64.tar.gz` | Portable tar bundle; early testing |
| Android | `skotiq-5.0.0-android-universal.apk` | Debug-signed sideload companion beta |
| macOS | None | Build from source for development |
| iOS | None | Build from source with your Apple signing identity |

Each application artifact has a matching `.sha256` file. Desktop archives
include `SKOTIQ-LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, and the applicable
third-party license text. `SOURCE-COMMIT.txt` records the exact source commit
used to build each desktop archive.

## System requirements

### Windows

- Windows 10 or 11, 64-bit
- 8 GB RAM minimum; 16 GB recommended
- DirectX 11-capable GPU with 2 GB VRAM
- Approximately 500 MB for the app, plus image/catalog storage
- ASCOM Platform and device drivers when using local ASCOM COM devices

### Linux

- x86-64 Linux with glibc 2.35 or newer (Ubuntu 22.04 / Debian Bookworm or
  equivalent)
- 8 GB RAM minimum; 16 GB recommended
- OpenGL 3.3-capable GPU
- GTK 3, libsecret, libusb, libudev, and OpenSSL runtime libraries
- A reachable INDI server for INDI equipment control

Linux is an early-testing path. Vendor-native USB devices may also require
vendor udev rules, libraries, and group membership.

## Windows installation

1. Download `skotiq-5.0.0-windows-x64.zip` and its checksum.
2. Optionally verify it in PowerShell:

   ```powershell
   Get-FileHash .\skotiq-5.0.0-windows-x64.zip -Algorithm SHA256
   ```

   Compare the result with the first value in the `.sha256` file.
3. Extract the entire archive to a writable folder. Do not run the executable
   from inside the ZIP.
4. Run `skotiq_desktop.exe`.
5. Windows SmartScreen may show “Windows protected your PC” because the beta is
   not code-signed. Confirm the file hash and GitHub release source before using
   “More info” → “Run anyway.”
6. Install ASCOM Platform and the matching device drivers before configuring
   ASCOM hardware.

The official archive includes the Skotiq bridge, LibRaw, and required MSVC
runtime DLLs. It does **not** redistribute vendor camera/mount SDK DLLs. Install
a compatible vendor library yourself or use ASCOM/Alpaca.

## Linux installation

1. Download `skotiq-5.0.0-linux-x64.tar.gz` and its checksum.
2. Verify and extract it:

   ```bash
   sha256sum -c skotiq-5.0.0-linux-x64.tar.gz.sha256
   tar -xzf skotiq-5.0.0-linux-x64.tar.gz
   cd skotiq-5.0.0-linux-x64
   ./skotiq
   ```

Use the `./skotiq` launcher, not `skotiq_desktop` directly; the launcher
loads the archive's ABI-matched LibRaw first (and the hermetic `libsqlite3.so`
native asset from `package:sqlite3`).

For INDI, install and start the server/drivers through your distribution. For
example, Ubuntu users can install the appropriate INDI packages and then point
Skotiq at that server. The official archive does not bundle INDI or vendor
device SDKs.

## Android companion installation

1. Download `skotiq-5.0.0-android-universal.apk` to the Android device.
2. Verify the SHA-256 if your download tool supports it.
3. Allow “Install unknown apps” for the browser/file manager you used, then
   open the APK.
4. Android will warn because this is a debug-signed sideload build, not a Play
   Store / production-signed package.
5. Pair it with a running Skotiq desktop/headless host over the LAN.

The mobile app is a companion for monitoring and light control; the desktop is
the full equipment-control surface.

## First launch

Skotiq was previously released under another name. On first launch it moves an
existing install's data across automatically, so settings, profiles and history
carry over without manual copying.

1. Open Tonight and confirm the UI loads without an error banner.
2. Create an equipment profile under Equipment.
3. Open the Planetarium (Ctrl+K, then type its name) and confirm the sky
   view renders.
4. Connect one device at a time and verify telemetry before issuing motion or
   exposure commands.
5. Run at least one complete supervised session on your exact rig before using
   unattended automation.

Skotiq data is stored under:

- Windows: `%APPDATA%\Skotiq\`
- Linux: `~/.local/share/skotiq_desktop/`
- macOS development builds: `~/Library/Application Support/Skotiq/`

## Updating

Official 5.0.0 artifacts are manual-update-only: no updater executable, trusted
update public key, or update server is shipped.

1. Create a backup from Settings → Backup & Restore.
2. Read the target release notes and known limitations.
3. Download and verify the new artifact from GitHub.
4. Keep the old portable folder until the new build opens your profile and you
   have verified the migration.
5. Replace/extract the new bundle, launch it, and confirm your equipment profile
   before connecting hardware.

The 5.0 release gate verifies schema v51 (created by tagged v4.3.0 code) through
v55 on a copied database. Your own backup remains the rollback path.

## Troubleshooting

- Windows SmartScreen: verify the SHA-256 and release source, then use “More
  info” → “Run anyway.”
- Missing Windows device: install ASCOM/vendor drivers; official artifacts do
  not include vendor SDK DLLs.
- Linux startup/library error: run `ldd ./skotiq_desktop` from the extracted
  directory and install the missing system library. Start via `./skotiq`.
- Pairing failure: keep both devices on the same LAN, allow Skotiq through
  the host firewall, and retry QR/manual pairing.

Continue with [Connecting Your First Device](first-connection.md) and
[Capturing Your First Image](first-image.md). For help, use the
[troubleshooting guide](../troubleshooting/common-issues.md) or
[GitHub Issues](https://github.com/Scdouglas1999/Skotiq/issues).
