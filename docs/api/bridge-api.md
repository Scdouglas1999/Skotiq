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

### `getState`

Get or initialize the global application state.

```dart
Future<void> getState()
```

### `getDeviceManager`

Get or initialize the global device manager.

```dart
Future<void> getDeviceManager()
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

### `apiDiscoverAlpacaDevices`

Discover available Alpaca devices on the network.

```dart
Future<List<DeviceInfo>> apiDiscoverAlpacaDevices()
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
Future<CapturedImageResult> apiGetLastImage()
```

### `apiGetCameraStatus`

Get camera status.

```dart
Future<CameraStatus> apiGetCameraStatus({required String deviceId})
```

### `apiSetCameraCooler`

Set camera cooling target.

```dart
Future<void> apiSetCameraCooler({
  required String deviceId,
  required bool enabled,
  double? targetTemp,
})
```

### `apiSetCameraGain`

Set camera gain.

```dart
Future<void> apiSetCameraGain({required String deviceId, required int gain})
```

### `apiSetCameraOffset`

Set camera offset.

```dart
Future<void> apiSetCameraOffset({required String deviceId, required int offset})
```

### `apiSetCameraBinning`

Set camera binning.

```dart
Future<void> apiSetCameraBinning({
  required String deviceId,
  required int binX,
  required int binY,
})
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

### `apiFilterwheelSetByName`

Set filter by name.

```dart
Future<void> apiFilterwheelSetByName({
  required String deviceId,
  required String name,
})
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

### `apiReadXisfFile`

Read an XISF file.

```dart
Future<XisfReadResult> apiReadXisfFile({required String filePath})
```

### `apiSaveFitsFile`

Save image data to FITS file.

```dart
Future<void> apiSaveFitsFile({
  required String filePath,
  required int width,
  required int height,
  required List<int> data,
  required FitsWriteHeader headerData,
})
```

### `apiSaveXisfFile`

Save image as XISF.

```dart
Future<void> apiSaveXisfFile({
  required String filePath,
  required int width,
  required int height,
  required List<int> data,
  required List<(String, String)> properties,
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

### `apiCalculateHfr`

Calculate HFR for a FITS file.

```dart
Future<double?> apiCalculateHfr({required String filePath})
```

### `apiCalculateHistogram`

Calculate histogram for a FITS file.

```dart
Future<Float32List> apiCalculateHistogram({
  required String filePath,
  required int bins,
  required bool logarithmic,
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

### `apiDebayerFitsFile`

Debayer a raw FITS file and return RGB display data.

```dart
Future<Uint8List> apiDebayerFitsFile({
  required String filePath,
  required BayerPatternApi pattern,
  required DebayerAlgorithmApi algorithm,
})
```

### `apiGetImageStats`

Calculate image statistics.

```dart
Future<ImageStats> apiGetImageStats({
  required int width,
  required int height,
  required List<int> data,
})
```

### `apiAutoStretchImage`

Auto-stretch image for display.

```dart
Future<Uint8List> apiAutoStretchImage({
  required int width,
  required int height,
  required List<int> data,
})
```

### `apiDebayerImage`

Debayer image.

```dart
Future<Uint8List> apiDebayerImage({
  required int width,
  required int height,
  required List<int> data,
  required String patternStr,
  required String algoStr,
})
```

## Plate Solving

### `apiIsPlateSolverAvailable`

Check if a plate solver is available.

```dart
bool apiIsPlateSolverAvailable()
```

### `apiGetPlateSolverPath`

Get the path to the installed plate solver.

```dart
String? apiGetPlateSolverPath()
```

### `apiPlateSolveBlind`

Plate solve an image file (blind solve).

```dart
Future<PlateSolveResult> apiPlateSolveBlind({required String filePath})
```

### `apiPlateSolveNear`

Plate solve an image with hint coordinates.

```dart
Future<PlateSolveResult> apiPlateSolveNear({
  required String filePath,
  required double hintRa,
  required double hintDec,
  required double searchRadius,
})
```

## PHD2 Guiding

### `apiIsPhd2Running`

Check if PHD2 is running.

```dart
bool apiIsPhd2Running()
```

### `getPhd2Storage`

Get PHD2 storage.

```dart
Future<void> getPhd2Storage()
```

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

### `apiPhd2StartGuiding`

Start guiding in PHD2.

```dart
Future<void> apiPhd2StartGuiding({
  required double settlePixels,
  required double settleTime,
  required double settleTimeout,
})
```

### `apiPhd2StopGuiding`

Stop guiding in PHD2.

```dart
Future<void> apiPhd2StopGuiding()
```

### `apiPhd2Dither`

Dither in PHD2.

```dart
Future<void> apiPhd2Dither({
  required double amount,
  required bool raOnly,
  required double settlePixels,
  required double settleTime,
  required double settleTimeout,
})
```

### `apiPhd2GetStatus`

Get PHD2 status.

```dart
Future<Phd2Status> apiPhd2GetStatus()
```

## Sequencer Control

### `apiSequencerLoadJson`

Load a sequence from JSON.

```dart
Future<void> apiSequencerLoadJson({required String json})
```

### `apiSequencerLoad`

Load a sequence from a definition struct.

```dart
Future<void> apiSequencerLoad({required SequenceDefinitionApi definition})
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
Future<void> apiSequencerStop()
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

## Sequence Node Creation

The Bridge API provides helper functions to create sequence node configurations:

- `apiCreateExposureNode` - Create exposure node
- `apiCreateSlewNode` - Create slew node
- `apiCreateCenterNode` - Create center node
- `apiCreateAutofocusNode` - Create autofocus node
- `apiCreateFilterNode` - Create filter change node
- `apiCreateTargetGroupNode` - Create target group node
- `apiCreateLoopNode` - Create loop node
- `apiCreateDelayNode` - Create delay node
- `apiCreateParkNode` - Create park node
- `apiCreateUnparkNode` - Create unpark node
- `apiCreateCoolCameraNode` - Create cool camera node
- `apiCreateWarmCameraNode` - Create warm camera node
- `apiCreateDitherNode` - Create dither node
- `apiCreateWaitTimeNode` - Create wait time node
- `apiCreateNotificationNode` - Create notification node
- `apiCreateScriptNode` - Create script node
- `apiCreateRotatorNode` - Create rotator node

### `apiBuildSequence`

Build a complete sequence definition from nodes.

```dart
String apiBuildSequence({
  required String id,
  required String name,
  String? description,
  required List<String> nodeJsons,
  String? rootNodeId,
})
```

## Session Management

### `apiGetSessionState`

Get current session state.

```dart
Future<SessionState> apiGetSessionState()
```

### `apiStartSession`

Start a new imaging session.

```dart
Future<void> apiStartSession({
  String? targetName,
  double? ra,
  double? dec,
})
```

### `apiEndSession`

End the current session.

```dart
Future<void> apiEndSession()
```

## File Naming

### `apiGenerateFilename`

Generate a filename from pattern and context.

```dart
Future<String> apiGenerateFilename({
  required String pattern,
  required String baseDir,
  String? target,
  String? filter,
  required double exposureTime,
  required FrameTypeApi frameType,
  required int frameNumber,
  int? gain,
  int? offset,
  double? temperature,
  required int binningX,
  required int binningY,
  String? camera,
  String? telescope,
  required String extension_,
})
```

### `apiGetNextFrameNumber`

Get the next frame number for a directory.

```dart
Future<int> apiGetNextFrameNumber({
  required String baseDir,
  required String pattern,
  String? target,
  String? filter,
  required FrameTypeApi frameType,
})
```

## Profile Management

### `apiInitProfileStorage`

Initialize profile storage.

```dart
Future<void> apiInitProfileStorage({required String storagePath})
```

### `apiGetProfiles`

Get all equipment profiles.

```dart
Future<List<EquipmentProfile>> apiGetProfiles()
```

### `apiSaveProfile`

Save an equipment profile.

```dart
Future<void> apiSaveProfile({required EquipmentProfile profile})
```

### `apiDeleteProfile`

Delete an equipment profile.

```dart
Future<void> apiDeleteProfile({required String profileId})
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
Future<void> apiInitSettingsStorage({required String storagePath})
```

### `apiGetSettings`

Get application settings.

```dart
Future<AppSettings> apiGetSettings()
```

### `apiUpdateSettings`

Update application settings.

```dart
Future<void> apiUpdateSettings({required AppSettings settings})
```

### `apiGetLocation`

Get observer location.

```dart
Future<ObserverLocation?> apiGetLocation()
```

### `apiSetLocation`

Set observer location.

```dart
Future<void> apiSetLocation({ObserverLocation? location})
```

## Error Handling

All Bridge API functions may throw `SkotiqError` exceptions. See [Error Handling](./error-handling.md) for details.

