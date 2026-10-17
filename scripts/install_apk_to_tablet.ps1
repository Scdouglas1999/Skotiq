# Install Skotiq mobile APK to a tablet over wireless ADB.
# Usage:
#   .\scripts\install_apk_to_tablet.ps1 -TabletIp 192.168.1.45
#   .\scripts\install_apk_to_tablet.ps1 -TabletIp 192.168.1.45 -AdbPort 41234 -PairPort 37123 -PairCode 123456
param(
    [string]$TabletIp = "192.168.1.45",
    [int]$AdbPort = 5555,
    [int]$PairPort = 0,
    [string]$PairCode = "",
    [string]$ApkPath = "$PSScriptRoot\..\apps\mobile\build\app\outputs\flutter-apk\app-release.apk"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $ApkPath)) {
    Write-Error "APK not found: $ApkPath. Run: cd apps\mobile; flutter build apk --release"
}

if ($PairPort -gt 0 -and $PairCode) {
    Write-Host "Pairing with $TabletIp`:$PairPort ..."
    adb pair "${TabletIp}:${PairPort}" $PairCode
}

Write-Host "Connecting adb to ${TabletIp}:${AdbPort} ..."
adb connect "${TabletIp}:${AdbPort}"
Start-Sleep -Seconds 2
$devices = adb devices
Write-Host $devices
if ($devices -notmatch "${TabletIp}:${AdbPort}\s+device") {
    Write-Host @"

Wireless ADB is not reachable. On the tablet:
  Settings → Developer options → Wireless debugging → ON
  Tap 'Pair device with pairing code' OR note 'IP address & port' for debugging

Then re-run with the ports shown on the tablet, e.g.:
  .\scripts\install_apk_to_tablet.ps1 -TabletIp $TabletIp -PairPort 37123 -PairCode 123456 -AdbPort 41234

Or download from your PC browser server (if running):
  http://192.168.1.20:8765/skotiq-mobile-2.6.0.apk
"@
    exit 1
}

Write-Host "Installing $ApkPath ..."
adb -s "${TabletIp}:${AdbPort}" install -r $ApkPath
Write-Host "Done."
