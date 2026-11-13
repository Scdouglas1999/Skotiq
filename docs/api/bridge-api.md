# Bridge API Reference

The Bridge API provides low-level Rust FFI bindings for direct access to native device drivers. This is the foundation layer that the Backend API uses.

## Initialization

### `apiInit`

Initialize the native bridge. **Must be called once at app startup** before any other API calls.

```dart
void apiInit()
```

**Example:**
```dart
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

void main() {
  bridge.apiInit();
  // Now safe to use other bridge functions
}
```

### `apiGetVersion`

Get the version of the native library.

```dart
String apiGetVersion()
```

## Device Discovery

### `apiDiscoverDevices`

Discover available devices of a specific type. Queries Windows-only ASCOM COM
drivers, Alpaca network devices or bridges, reachable INDI servers, Native SDK
paths where the release ships the needed libraries, and simulator paths where
that workflow is enabled.

```dart
Future<List<DeviceInfo>> apiDiscoverDevices({required DeviceType deviceType})
```

**Example:**
```dart
final cameras = await bridge.apiDiscoverDevices(deviceType: bridge.DeviceType.camera);
```

### `apiDiscoverAlpacaAtAddress`

Discover Alpaca devices at a specific server address.

```dart
Future<List<DeviceInfo>> apiDiscoverAlpacaAtAddress({
  required String host,
  required int port,
})
```

### `apiDiscoverIndiAtAddress`

Discover INDI devices at a specific server address.

```dart
Future<List<DeviceInfo>> apiDiscoverIndiAtAddress({
  required String host,
  required int port,
})
```

## Device Connection

### `apiConnectDevice`

Connect to a device.

```dart
Future<void> apiConnectDevice({
  required DeviceType deviceType,
  required String deviceId,
})
```

### `apiDisconnectDevice`

Disconnect from a device.

```dart
Future<void> apiDisconnectDevice({
  required DeviceType deviceType,
  required String deviceId,
})
```

### `apiIsDeviceConnected`

Check if a device is connected.

```dart
Future<bool> apiIsDeviceConnected({
  required DeviceType deviceType,
  required String deviceId,
})
```

### `apiGetConnectedDevices`

Get list of connected devices.

```dart
Future<List<DeviceInfo>> apiGetConnectedDevices()
```

## Camera Control

Gain, offset and binning are set with each exposure rather than by separate calls.

### `apiCameraStartExposure`

Start a camera exposure. Returns progress updates via events, final image available via `apiGetLastImage`.

```dart
Future<void> apiCameraStartExposure({
  required String deviceId,
  required double durationSecs,
  required int gain,
  required int offset,
  required int binX,
  required int binY,
})
```

### `apiCameraCancelExposure`

Cancel current exposure.

```dart
Future<void> apiCameraCancelExposure({required String deviceId})
```

### `apiGetLastImage`

Get the last captured image.

```dart
Future<CapturedImageResult> apiGetLastImage({required String deviceId})
```

## Mount Control

### `apiGetMountStatus`

Get mount status.

```dart
Future<MountStatus> apiGetMountStatus({required String deviceId})
```

### `apiMountSlewToCoordinates`

Slew mount to coordinates.

```dart
Future<void> apiMountSlewToCoordinates({
  required String deviceId,
  required double ra,
  required double dec,
})
```

### `apiMountSyncToCoordinates`

Sync mount to coordinates.

```dart
Future<void> apiMountSyncToCoordinates({
  required String deviceId,
  required double ra,
  required double dec,
})
```

### `apiMountPark`

Park the mount.

```dart
Future<void> apiMountPark({required String deviceId})
```

### `apiMountUnpark`

Unpark the mount.

```dart
Future<void> apiMountUnpark({required String deviceId})
```

### `apiMountSetTracking`

Set mount tracking.

```dart
Future<void> apiMountSetTracking({
  required String deviceId,
  required bool enabled,
})
```

### `apiMountPulseGuide`

Pulse guide the mount.

```dart
Future<void> apiMountPulseGuide({
  required String deviceId,
  required String direction,
  required int durationMs,
})
```

## Focuser Control

### `apiGetFocuserStatus`

Get focuser status.

```dart
Future<FocuserStatus> apiGetFocuserStatus({required String deviceId})
```

### `apiFocuserMoveTo`

Move focuser to position.

```dart
Future<void> apiFocuserMoveTo({
  required String deviceId,
  required int position,
})
```

### `apiFocuserMoveRelative`

Move focuser by relative amount.

```dart
Future<void> apiFocuserMoveRelative({
  required String deviceId,
  required int delta,
})
```

## Filter Wheel Control

### `apiGetFilterwheelStatus`

Get filter wheel status.

```dart
Future<FilterWheelStatus> apiGetFilterwheelStatus({required String deviceId})
```

### `apiFilterwheelSetPosition`

Set filter wheel position.

```dart
Future<void> apiFilterwheelSetPosition({
  required String deviceId,
  required int position,
})
```

### `apiFilterwheelGetNames`

Get filter names.

```dart
Future<List<String>> apiFilterwheelGetNames({required String deviceId})
```

## Rotator Control

### `apiGetRotatorStatus`

Get rotator status.

```dart
Future<RotatorStatus> apiGetRotatorStatus({required String deviceId})
```

### `apiRotatorMoveTo`

Move rotator to angle.

```dart
Future<void> apiRotatorMoveTo({
  required String deviceId,
  required double angle,
})
```

### `apiRotatorMoveRelative`

Move rotator relative.

```dart
Future<void> apiRotatorMoveRelative({
  required String deviceId,
  required double delta,
})
```

### `apiRotatorHalt`

Halt rotator.

```dart
Future<void> apiRotatorHalt({required String deviceId})
```

## Image Processing

### `apiReadFitsFile`

Read a FITS file from disk.

```dart
Future<FitsReadResult> apiReadFitsFile({required String filePath})
```

### `apiSaveFitsFromLastCapture`

Save the camera's last frame as FITS. The pixels stay on the Rust side. The
header is the one a sequence's frame gets, without the cards that tie a frame
to a run: `headerData` carries what was commanded, the observer, site and
optics, and the ids of the rig's devices, and the devices are read when the
file is written.

```dart
Future<String> apiSaveFitsFromLastCapture({
  required String deviceId,
  required String filePath,
  required FitsWriteHeader headerData,
  required bool keepCameraFile,
})
```

### `apiDetectStarsInFile`

Detect stars in a FITS file.

```dart
Future<StarDetectionResultApi> apiDetectStarsInFile({
  required String filePath,
  StarDetectionConfigApi? config,
})
```

### `apiCalculateAutoStretch`

Auto-calculate stretch parameters for an image.

```dart
Future<StretchParamsApi> apiCalculateAutoStretch({required String filePath})
```

### `apiApplyStretch`

Apply stretch to a FITS file and return display data.

```dart
Future<Uint8List> apiApplyStretch({
  required String filePath,
  required StretchParamsApi params,
})
```

### `apiAutoStretchImage`

Auto-stretch image for display.

```dart
Uint8List apiAutoStretchImage({
  required int width,
  required int height,
  required List<int> data,
})
```

## Calibration and Live Stacking

### `apiCalibrateImageFile`

Calibrate a light frame file with the masters at the given paths and write the result to `outputPath`. A master flat is used as it is; a raw flat has the bias taken out first (PixInsight's defaults). An absent or empty path skips that correction.

```dart
Future<void> apiCalibrateImageFile({
  required String lightPath,
  String? darkPath,
  String? flatPath,
  String? biasPath,
  required String outputPath,
})
```

### `apiCalibrateImageData`

Calibrate a single-plane u16 light in memory by the same rule as `apiCalibrateImageFile`.

```dart
Future<Uint16List> apiCalibrateImageData({
  required int width,
  required int height,
  required List<int> lightData,
  String? darkPath,
  String? flatPath,
  String? biasPath,
})
```

### `apiStackingStart` / `apiStackingStartFromData`

Start the process-wide live stack from a reference frame file or a u16 frame in memory. `ApiLiveStackingConfig` carries the alignment, rejection and color settings; `apiStackingAddFrame`, `apiStackingAddFrameFromData`, `apiStackingGetResult`, `apiStackingGetStats`, `apiStackingSaveMasterFits`, `apiStackingReset` and `apiStackingStop` work on the running stack.

```dart
Future<ApiLiveStackingStats> apiStackingStart({
  required String referenceImagePath,
  required ApiLiveStackingConfig config,
})
```

### `apiDefectMapBuild` / `apiDefectMapSetCorrection` / `apiDefectMapClear`

Build a defect map from dark frames, turn correction of a camera's lights during capture on or off, and delete a map. Each change applies to a running sequence from its next exposure; `apiDefectMapGetStatus` reports the stored map and whether correction is on.

```dart
Future<void> apiDefectMapSetCorrection({
  required String cameraId,
  required int width,
  required int height,
  required double sensorTemperatureCelsius,
  required bool enabled,
  required String method,
  required int kernelDiameter,
  required bool saveOriginal,
})
```

## Plate Solving

### `apiGetPlateSolverPath`

Get the path to the installed plate solver.

```dart
String? apiGetPlateSolverPath()
```

### `apiPlateSolveBlind`

Plate solve an image file (blind solve).

```dart
Future<PlateSolveResult> apiPlateSolveBlind({
  required String filePath,
  int? timeoutSecs,
})
```

### `apiPlateSolveNear`

Plate solve an image with hint coordinates.

```dart
Future<PlateSolveResult> apiPlateSolveNear({
  required String filePath,
  required double hintRa,
  required double hintDec,
  required double searchRadius,
  int? timeoutSecs,
})
```

## Guiding

### `apiPhd2Connect`

Connect to PHD2.

```dart
Future<void> apiPhd2Connect({String? host, int? port})
```

### `apiPhd2Disconnect`

Disconnect from PHD2.

```dart
Future<void> apiPhd2Disconnect()
```

### `apiGuiderStartGuiding`

Start guiding with the active guider (PHD2 or the built-in guider) and wait for it to settle.

```dart
Future<void> apiGuiderStartGuiding({
  required double settlePixels,
  required double settleTime,
  required double settleTimeout,
})
```

### `apiGuiderStop`

Stop guiding.

```dart
Future<void> apiGuiderStop()
```

### `apiGuiderDither`

Dither and wait for the guider to settle.

```dart
Future<void> apiGuiderDither({
  required double amount,
  required bool raOnly,
  required double settlePixels,
  required double settleTime,
  required double settleTimeout,
})
```

### `apiGuiderGetStatus`

The active guider's status.

```dart
Future<GuiderStatus> apiGuiderGetStatus()
```

## Sequencer Control

### `apiSequencerLoadJson`

Load a sequence from JSON.

```dart
Future<void> apiSequencerLoadJson({required String json})
```

### `apiSequencerStart`

Start the sequence executor.

```dart
Future<void> apiSequencerStart()
```

### `apiSequencerPause`

Pause the sequence executor.

```dart
Future<void> apiSequencerPause()
```

### `apiSequencerResume`

Resume the sequence executor.

```dart
Future<void> apiSequencerResume()
```

### `apiSequencerStop`

Stop the sequence executor.

```dart
Future<void> apiSequencerStop({String? origin})
```

### `apiSequencerSkip`

Skip to the next instruction.

```dart
Future<void> apiSequencerSkip()
```

### `apiSequencerReset`

Reset the sequence executor.

```dart
Future<void> apiSequencerReset()
```

### `apiSequencerGetState`

Get the current sequencer state.

```dart
Future<SequencerState> apiSequencerGetState()
```

### `apiSequencerSubscribeEvents`

Subscribe to sequencer events and forward them to the main event stream.

```dart
Future<void> apiSequencerSubscribeEvents()
```

## Profile Management

### `apiInitProfileStorage`

Initialize profile storage.

```dart
void apiInitProfileStorage({required String storagePath})
```

### `apiGetProfiles`

Get all equipment profiles.

```dart
List<EquipmentProfile> apiGetProfiles()
```

### `apiSaveProfile`

Save an equipment profile.

```dart
void apiSaveProfile({required EquipmentProfile profile})
```

### `apiDeleteProfile`

Delete an equipment profile.

```dart
void apiDeleteProfile({required String profileId})
```

### `apiLoadProfile`

Load a profile and set as active.

```dart
Future<void> apiLoadProfile({required String profileId})
```

### `apiGetActiveProfile`

Get the currently active profile.

```dart
Future<EquipmentProfile?> apiGetActiveProfile()
```

## Settings Management

### `apiInitSettingsStorage`

Initialize settings storage.

```dart
void apiInitSettingsStorage({required String storagePath})
```

### `apiGetSettings`

Get application settings.

```dart
AppSettings apiGetSettings()
```

### `apiUpdateSettings`

Update application settings.

```dart
void apiUpdateSettings({required AppSettings settings})
```

### `apiGetLocation`

Get observer location.

```dart
ObserverLocation? apiGetLocation()
```

### `apiSetLocation`

Set observer location.

```dart
void apiSetLocation({ObserverLocation? location})
```

## Error Handling

All Bridge API functions may throw `SkotiqError` exceptions. See [Error Handling](./error-handling.md) for details.

