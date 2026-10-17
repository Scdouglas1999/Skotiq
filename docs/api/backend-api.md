# Backend API Reference

The `SkotiqBackend` interface provides a high-level abstraction for controlling astronomical equipment. It supports multiple implementations:

- **FfiBackend** - Direct FFI calls to native Rust code
- **NetworkBackend** - REST API client for headless server mode
- **DisconnectedBackend** - Stub implementation for disconnected state

## Overview

```dart
abstract class SkotiqBackend {
  Stream<SkotiqEvent> get eventStream;
  
  // Device Discovery & Connection
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType);
  Future<void> connectDevice(DeviceType deviceType, String deviceId);
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId);
  Future<List<DeviceInfo>> getConnectedDevices();
  
  // Camera, Mount, Focuser, Filter Wheel, Rotator, PHD2, Plate Solving, Sequencer...
}
```

## Device Discovery & Connection

### `discoverDevices`

Discover available devices of a specific type.

```dart
Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType)
```

**Parameters:**
- `deviceType` - The type of device to discover (camera, mount, focuser, etc.)

**Returns:** List of discovered devices

**Example:**
```dart
final cameras = await backend.discoverDevices(DeviceType.camera);
for (final camera in cameras) {
  print('Found camera: ${camera.name} (${camera.id})');
}
```

### `connectDevice`

Connect to a device.

```dart
Future<void> connectDevice(DeviceType deviceType, String deviceId)
```

**Parameters:**
- `deviceType` - The type of device
- `deviceId` - Unique identifier for the device (e.g., "ascom:ASCOM.Simulator.Telescope", "alpaca:192.168.1.100:11111:0")

**Throws:** `SkotiqError` if connection fails

### `disconnectDevice`

Disconnect from a device.

```dart
Future<void> disconnectDevice(DeviceType deviceType, String deviceId)
```

### `getConnectedDevices`

Get list of currently connected devices.

```dart
Future<List<DeviceInfo>> getConnectedDevices()
```

## Camera Control

### `cameraStartExposure`

Start a camera exposure.

```dart
Future<void> cameraStartExposure({
  required String deviceId,
  required double exposureTime,
  required FrameType frameType,
  int binX = 1,
  int binY = 1,
  int? x,
  int? y,
  int? width,
  int? height,
})
```

**Parameters:**
- `deviceId` - Camera device identifier
- `exposureTime` - Exposure duration in seconds
- `frameType` - Type of frame (light, dark, flat, bias, etc.)
- `binX`, `binY` - Binning factors (default: 1)
- `x`, `y`, `width`, `height` - Optional subframe coordinates

**Example:**
```dart
await backend.cameraStartExposure(
  deviceId: 'camera-1',
  exposureTime: 60.0,
  frameType: FrameType.light,
  binX: 2,
  binY: 2,
);
```

### `cameraAbortExposure`

Abort the current camera exposure.

```dart
Future<void> cameraAbortExposure(String deviceId)
```

### `cameraGetLastImage`

Get the last captured image.

```dart
Future<CapturedImageResult?> cameraGetLastImage(String deviceId)
```

**Returns:** Image data with display-ready RGB/grayscale data, histogram, and statistics

### `cameraSetCooling`

Set camera cooling target.

```dart
Future<void> cameraSetCooling({
  required String deviceId,
  required bool enabled,
  double? targetTemp,
})
```

### `cameraSetGain`

Set camera gain.

```dart
Future<void> cameraSetGain(String deviceId, int gain)
```

### `cameraSetOffset`

Set camera offset.

```dart
Future<void> cameraSetOffset(String deviceId, int offset)
```

## Mount Control

### `mountSlewToCoordinates`

Slew mount to specified coordinates.

```dart
Future<void> mountSlewToCoordinates(String deviceId, double ra, double dec)
```

**Parameters:**
- `deviceId` - Mount device identifier
- `ra` - Right Ascension in hours
- `dec` - Declination in degrees

### `mountSync`

Sync mount to specified coordinates.

```dart
Future<void> mountSync(String deviceId, double ra, double dec)
```

### `mountPark`

Park the mount.

```dart
Future<void> mountPark(String deviceId)
```

### `mountUnpark`

Unpark the mount.

```dart
Future<void> mountUnpark(String deviceId)
```

### `mountSetTracking`

Enable or disable mount tracking.

```dart
Future<void> mountSetTracking(String deviceId, bool enabled)
```

### `mountPulseGuide`

Pulse guide the mount for corrections.

```dart
Future<void> mountPulseGuide({
  required String deviceId,
  required String direction,
  required int durationMs,
})
```

**Parameters:**
- `direction` - Guide direction: "north", "south", "east", "west"
- `durationMs` - Pulse duration in milliseconds

### `mountAbort`

Abort mount slew operation.

```dart
Future<void> mountAbort(String deviceId)
```

**Note:** Currently throws `UnimplementedError` - not yet exposed in bridge API.

### `mountGetStatus`

Get current mount status.

```dart
Future<dynamic> mountGetStatus(String deviceId)
```

**Returns:** `MountStatus` object with RA, Dec, tracking state, slewing state, etc.

## Focuser Control

### `focuserMoveTo`

Move focuser to absolute position.

```dart
Future<void> focuserMoveTo(String deviceId, int position)
```

### `focuserMoveRelative`

Move focuser by relative amount.

```dart
Future<void> focuserMoveRelative(String deviceId, int delta)
```

### `focuserHalt`

Halt focuser movement.

```dart
Future<void> focuserHalt(String deviceId)
```

### `autofocusStart`

Run autofocus routine.

```dart
Future<double> autofocusStart({
  required String deviceId,
  required String cameraId,
  required double exposureTime,
  required int stepSize,
  required int stepsOut,
  String method = 'VCurve',
  int binning = 1,
})
```

**Returns:** HFR (Half-Flux Radius) of the best focus position

### `autofocusCancel`

Cancel autofocus operation.

```dart
Future<void> autofocusCancel()
```

## Filter Wheel Control

### `filterWheelSetPosition`

Set filter wheel to specific position.

```dart
Future<void> filterWheelSetPosition(String deviceId, int position)
```

### `filterWheelGetNames`

Get list of filter names.

```dart
Future<List<String>> filterWheelGetNames(String deviceId)
```

### `filterWheelSetByName`

Set filter by name.

```dart
Future<void> filterWheelSetByName(String deviceId, String name)
```

## Rotator Control

### `rotatorMoveTo`

Move rotator to absolute angle.

```dart
Future<void> rotatorMoveTo(String deviceId, double angle)
```

### `rotatorMoveRelative`

Move rotator by relative angle.

```dart
Future<void> rotatorMoveRelative(String deviceId, double delta)
```

### `rotatorGetAngle`

Get current rotator angle.

```dart
Future<double> rotatorGetAngle(String deviceId)
```

### `rotatorHalt`

Halt rotator movement.

```dart
Future<void> rotatorHalt(String deviceId)
```

## PHD2 Guiding

### `phd2Connect`

Connect to PHD2 guiding software.

```dart
Future<void> phd2Connect({String host = 'localhost', int port = 4400})
```

### `phd2Disconnect`

Disconnect from PHD2.

```dart
Future<void> phd2Disconnect()
```

### `phd2StartGuiding`

Start guiding in PHD2.

```dart
Future<void> phd2StartGuiding({
  double settlePixels = 1.0,
  double settleTime = 10.0,
  double settleTimeout = 60.0,
})
```

### `phd2StopGuiding`

Stop guiding in PHD2.

```dart
Future<void> phd2StopGuiding()
```

### `phd2Dither`

Trigger dither in PHD2.

```dart
Future<void> phd2Dither({
  double amount = 5.0,
  bool raOnly = false,
  double settlePixels = 1.0,
  double settleTime = 10.0,
  double settleTimeout = 60.0,
})
```

### `phd2GetStatus`

Get PHD2 guiding status.

```dart
Future<Phd2Status> phd2GetStatus()
```

**Returns:** `Phd2Status` with connection state, RMS values, SNR, star mass, etc.

## Plate Solving

### `plateSolve`

Solve an image file to determine its coordinates.

```dart
Future<PlateSolveResult> plateSolve({
  required String imagePath,
  double? ra,
  double? dec,
  double? fovDegrees,
})
```

**Parameters:**
- `imagePath` - Path to image file (FITS, XISF, etc.)
- `ra`, `dec` - Optional hint coordinates (for faster solving)
- `fovDegrees` - Optional field of view hint

**Returns:** `PlateSolveResult` with solved coordinates, pixel scale, rotation, etc.

## Sequencer Control

### `sequencerStart`

Start the sequencer.

```dart
Future<void> sequencerStart()
```

### `sequencerStop`

Stop the sequencer.

```dart
Future<void> sequencerStop()
```

### `sequencerPause`

Pause the sequencer.

```dart
Future<void> sequencerPause()
```

### `sequencerResume`

Resume the sequencer.

```dart
Future<void> sequencerResume()
```

### `sequencerLoadJson`

Load a sequence definition from JSON.

```dart
Future<void> sequencerLoadJson(String json)
```

### `sequencerGetStatus`

Get current sequencer status.

```dart
Future<SequencerStatus> sequencerGetStatus()
```

**Returns:** `SequencerStatus` with state, current node, progress, etc.

### `sequencerSetSimulationMode`

Enable/disable simulation mode (use mock devices).

```dart
Future<void> sequencerSetSimulationMode(bool enabled)
```

## Equipment Status

### `getCameraStatus`

Get camera status.

```dart
Future<dynamic> getCameraStatus(String deviceId)
```

### `getMountStatus`

Get mount status.

```dart
Future<dynamic> getMountStatus(String deviceId)
```

### `getFocuserStatus`

Get focuser status.

```dart
Future<dynamic> getFocuserStatus(String deviceId)
```

### `getFilterWheelStatus`

Get filter wheel status.

```dart
Future<dynamic> getFilterWheelStatus(String deviceId)
```

## Equipment Profiles

### `getProfiles`

Get all equipment profiles.

```dart
Future<List<EquipmentProfile>> getProfiles()
```

### `saveProfile`

Save an equipment profile.

```dart
Future<void> saveProfile(EquipmentProfile profile)
```

### `deleteProfile`

Delete an equipment profile.

```dart
Future<void> deleteProfile(String profileId)
```

### `loadProfile`

Load a profile and set as active.

```dart
Future<void> loadProfile(String profileId)
```

### `getActiveProfile`

Get the currently active profile.

```dart
Future<EquipmentProfile?> getActiveProfile()
```

## Settings & Location

### `getSettings`

Get application settings.

```dart
Future<AppSettings> getSettings()
```

### `updateSettings`

Update application settings.

```dart
Future<void> updateSettings(AppSettings settings)
```

### `getLocation`

Get observer location.

```dart
Future<ObserverLocation?> getLocation()
```

### `setLocation`

Set observer location.

```dart
Future<void> setLocation(ObserverLocation? location)
```

### `getLocationFromInternet`

Get location from internet (IP-based geolocation).

```dart
Future<LocationSettings> getLocationFromInternet()
```

## Image Processing

### `getImageStats`

Calculate image statistics.

```dart
Future<ImageStats> getImageStats(int width, int height, Uint16List data)
```

### `autoStretchImage`

Auto-stretch image for display.

```dart
Future<Uint8List> autoStretchImage(int width, int height, Uint16List data)
```

### `debayerImage`

Debayer a raw image.

```dart
Future<Uint8List> debayerImage(
  int width,
  int height,
  Uint16List data,
  String pattern,
  String algorithm,
)
```

## Event Stream

### `eventStream`

Stream of backend events.

```dart
Stream<SkotiqEvent> get eventStream
```

**Example:**
```dart
backend.eventStream.listen((event) {
  print('Event: ${event.eventType} - ${event.category}');
  if (event.severity == EventSeverity.error) {
    // Handle error
  }
});
```

## Error Handling

All methods may throw `SkotiqError` exceptions. Common error types:

- `SkotiqError.deviceNotFound` - Device not found
- `SkotiqError.connectionFailed` - Connection failed
- `SkotiqError.notConnected` - Device not connected
- `SkotiqError.timeout` - Operation timed out
- `SkotiqError.operationFailed` - Operation failed

**Example:**
```dart
try {
  await backend.connectDevice(DeviceType.camera, 'camera-1');
} on SkotiqError catch (e) {
  print('Error: ${e.toString()}');
}
```

