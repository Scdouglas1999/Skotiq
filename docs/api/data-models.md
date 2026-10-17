# Data Models Reference

Complete reference for all data types, enums, and models used in the Skotiq API.

## Enums

### DeviceType

Device types supported by Skotiq.

```dart
enum DeviceType {
  camera,
  mount,
  focuser,
  filterWheel,
  guider,
  dome,
  rotator,
  weather,
  safetyMonitor,
}
```

### DriverType

Driver backend types.

```dart
enum DriverType {
  ascom,      // Windows-only ASCOM COM drivers
  alpaca,     // ASCOM Alpaca network devices or bridges
  indi,       // Reachable INDI servers and drivers
  native,     // Direct SDK access where the release ships the needed library
  simulator,  // Simulated devices where that workflow is enabled
}
```

### ConnectionState

Device connection states.

```dart
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}
```

### CameraState

Camera operational states.

```dart
enum CameraState {
  idle,
  waiting,
  exposing,
  reading,
  download,
  error,
}
```

### FrameType

Frame types for calibration and imaging.

```dart
enum FrameType {
  light,     // Light frame
  dark,      // Dark frame
  flat,      // Flat frame
  bias,      // Bias frame
  darkFlat,  // Dark flat frame
  snapshot,  // Snapshot
}
```

### PierSide

Side of pier for German Equatorial mounts.

```dart
enum PierSide {
  east,
  west,
  unknown,
}
```

### TrackingRate

Mount tracking rates.

```dart
enum TrackingRate {
  sidereal,  // Sidereal rate
  lunar,     // Lunar rate
  solar,     // Solar rate
  king,      // King rate
  custom,    // Custom rate
}
```

### EventSeverity

Event severity levels.

```dart
enum EventSeverity {
  info,
  warning,
  error,
  critical,
}
```

### EventCategory

Event categories.

```dart
enum EventCategory {
  equipment,
  imaging,
  guiding,
  sequencer,
  safety,
  system,
  polarAlignment,
}
```

### BayerPatternApi

Bayer pattern types for debayering.

```dart
enum BayerPatternApi {
  rggb,  // Red-Green-Green-Blue
  bggr,  // Blue-Green-Green-Red
  grbg,  // Green-Red-Blue-Green
  gbrg,  // Green-Blue-Red-Green
}
```

### DebayerAlgorithmApi

Debayering algorithms.

```dart
enum DebayerAlgorithmApi {
  bilinear,   // Bilinear interpolation
  vng,        // Variable Number of Gradients
  superPixel, // Super pixel
}
```

## Classes

### DeviceInfo

Information about a discovered device.

```dart
class DeviceInfo {
  final String id;
  final String name;
  final DeviceType deviceType;
  final DriverType driverType;
  final String description;
  final String driverVersion;
}
```

### SkotiqEvent

Event emitted by the backend.

```dart
class SkotiqEvent {
  final int timestamp;
  final EventSeverity severity;
  final EventCategory category;
  final String eventType;
  final Map<String, dynamic> data;
}
```

### CapturedImageResult

Result from capturing an image.

```dart
class CapturedImageResult {
  final int width;
  final int height;
  final List<int> displayData;  // RGB or grayscale
  final List<int> histogram;
  final ImageStatsResult stats;
  final double exposureTime;
  final String timestamp;
  final bool isColor;
}
```

### ImageStatsResult

Image statistics.

```dart
class ImageStatsResult {
  final double min;
  final double max;
  final double mean;
  final double median;
  final double stdDev;
  final double? hfr;        // Half-Flux Radius
  final int starCount;
}
```

### MountStatus

Mount status information.

```dart
class MountStatus {
  final double ra;           // Right Ascension (hours)
  final double dec;          // Declination (degrees)
  final double altitude;     // Altitude (degrees)
  final double azimuth;     // Azimuth (degrees)
  final bool tracking;       // Tracking enabled
  final bool slewing;        // Currently slewing
  final bool parked;         // Parked state
  final PierSide? pierSide;  // Side of pier
  final TrackingRate? trackingRate;
}
```

### CameraStatus

Camera status information.

```dart
class CameraStatus {
  final CameraState state;
  final double? temperature;
  final double? targetTemperature;
  final bool coolerEnabled;
  final int gain;
  final int offset;
  final int binX;
  final int binY;
  final int? exposureProgress;  // 0-100
  final double? exposureRemaining;
}
```

### FocuserStatus

Focuser status information.

```dart
class FocuserStatus {
  final int position;
  final int? maxPosition;
  final bool moving;
  final double? temperature;
}
```

### FilterWheelStatus

Filter wheel status information.

```dart
class FilterWheelStatus {
  final int position;
  final int filterCount;
  final List<String> filterNames;
  final bool moving;
}
```

### RotatorStatus

Rotator status information.

```dart
class RotatorStatus {
  final double angle;
  final bool moving;
}
```

### Phd2Status

PHD2 guiding status.

```dart
class Phd2Status {
  final String state;        // "stopped", "selected", "calibrating", "guiding", etc.
  final bool connected;
  final double rmsRa;        // RMS error in RA (arcsec)
  final double rmsDec;       // RMS error in Dec (arcsec)
  final double rmsTotal;     // Total RMS error (arcsec)
  final double snr;          // Signal-to-noise ratio
  final double starMass;     // Star mass
  final double avgDistance;  // Average distance (pixels)
}
```

### PlateSolveResult

Result from plate solving.

```dart
class PlateSolveResult {
  final bool success;
  final double ra;              // Solved RA (hours)
  final double dec;             // Solved Dec (degrees)
  final double pixelScale;      // Arcseconds per pixel
  final double rotation;        // Rotation angle (degrees)
  final double fieldWidth;      // Field width (degrees)
  final double fieldHeight;     // Field height (degrees)
  final double solveTimeSecs;   // Time taken to solve
  final String? error;          // Error message if failed
}
```

### SequencerStatus

Sequencer status.

```dart
class SequencerStatus {
  final String state;           // "idle", "running", "paused", "error"
  final String? currentNodeId;
  final String? currentNodeName;
  final double progress;        // 0.0 to 1.0
  final String? message;
}
```

### SequencerState

Detailed sequencer state.

```dart
class SequencerState {
  final String state;
  final String? currentNodeId;
  final String? currentNodeName;
  final int totalExposures;
  final int completedExposures;
  final double totalIntegrationSecs;
  final double elapsedSecs;
  final double? estimatedRemainingSecs;
  final String? currentTarget;
  final String? currentFilter;
  final String? message;
}
```

### FitsReadResult

Result from reading a FITS file.

```dart
class FitsReadResult {
  final int width;
  final int height;
  final int bitpix;
  final Uint8List displayData;
  final Uint32List histogram;
  final ImageStatsResult stats;
  final String? objectName;
  final double? exposureTime;
  final String? filter;
  final double? ra;
  final double? dec;
  final String? dateObs;
}
```

### FitsWriteHeader

Header data for writing FITS files.

```dart
class FitsWriteHeader {
  final String? objectName;
  final double exposureTime;
  final String? filter;
  final int? gain;
  final int? offset;
  final double? ccdTemp;
  final double? ra;
  final double? dec;
  final String? telescope;
  final String? instrument;
  final String? observer;
  final int binX;
  final int binY;
}
```

### DetectedStarInfo

Information about a detected star.

```dart
class DetectedStarInfo {
  final double x;           // X position (pixels)
  final double y;           // Y position (pixels)
  final double flux;        // Flux value
  final double hfr;         // Half-Flux Radius
  final double fwhm;        // Full Width Half Maximum
  final double peak;        // Peak value
  final double background;  // Background level
  final double snr;         // Signal-to-noise ratio
}
```

### NodeDefinitionApi

Sequence node definition.

```dart
class NodeDefinitionApi {
  final String id;
  final String name;
  final String nodeType;      // "exposure", "slew", "center", etc.
  final bool enabled;
  final List<String> children;
  final String configJson;   // JSON configuration
}
```

### SequenceDefinitionApi

Complete sequence definition.

```dart
class SequenceDefinitionApi {
  final String id;
  final String name;
  final String? description;
  final List<NodeDefinitionApi> nodes;
  final String? rootNodeId;
}
```

### EquipmentProfile

Equipment profile configuration.

```dart
class EquipmentProfile {
  final String id;
  final String name;
  final String? description;
  final String? cameraId;
  final String? mountId;
  final String? focuserId;
  final String? filterWheelId;
  final String? rotatorId;
  final Map<String, dynamic>? settings;
}
```

### AppSettings

Application settings.

```dart
class AppSettings {
  // Settings structure defined in settings models
  // Includes imaging defaults, file paths, etc.
}
```

### ObserverLocation

Observer location information.

```dart
class ObserverLocation {
  final double latitude;   // Degrees
  final double longitude; // Degrees
  final double elevation; // Meters
  final String? name;     // Location name
}
```

## Error Types

### SkotiqError

Main error type for the Skotiq API.

```dart
sealed class SkotiqError {
  const factory SkotiqError.deviceNotFound(String message);
  const factory SkotiqError.connectionFailed(String message);
  const factory SkotiqError.alreadyConnected(String message);
  const factory SkotiqError.notConnected(String message);
  const factory SkotiqError.timeout(String message);
  const factory SkotiqError.invalidParameter(String message);
  const factory SkotiqError.invalidInput(String message);
  const factory SkotiqError.invalidDeviceId(String message);
  const factory SkotiqError.operationFailed(String message);
  const factory SkotiqError.imageError(String message);
  const factory SkotiqError.ioError(String message);
  const factory SkotiqError.plateSolveError(String message);
  const factory SkotiqError.sequenceError(String message);
  const factory SkotiqError.noImageAvailable();
  const factory SkotiqError.exposureCancelled();
  const factory SkotiqError.cancelled();
  const factory SkotiqError.cameraError(String message);
  const factory SkotiqError.internal(String message);
}
```

## Type Aliases

### LocationSettings

Location settings type (alias for `ObserverLocation` or similar).

## Notes

- All timestamps are in milliseconds since epoch (Unix timestamp)
- Coordinates use standard astronomical conventions:
  - RA: Hours (0-24)
  - Dec: Degrees (-90 to +90)
  - Altitude/Azimuth: Degrees
- Image data formats:
  - Grayscale: Single channel (width × height)
  - Color: RGB interleaved (width × height × 3)
- All angles are in degrees unless specified otherwise

