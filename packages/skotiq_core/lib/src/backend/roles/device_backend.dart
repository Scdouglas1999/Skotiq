import 'dart:async';
import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        CameraRecommendedSettings,
        MountSite,
        MountSiteCapabilities,
        MountTimeInfo;

import '../../models/backend/backend_types.dart';
import '../../models/imaging/imaging_models.dart' show FrameType;

/// Typed environmental telemetry shared by local FFI and remote HTTP
/// backends. Null fields mean the driver does not expose that sensor.
class HardwareWeatherConditions {
  final double? temperature;
  final double? humidity;
  final double? pressure;
  final double? cloudCover;
  final double? dewPoint;
  final double? windSpeed;
  final double? windDirection;
  final double? skyQuality;
  final double? skyTemperature;
  final double? rainRate;

  const HardwareWeatherConditions({
    this.temperature,
    this.humidity,
    this.pressure,
    this.cloudCover,
    this.dewPoint,
    this.windSpeed,
    this.windDirection,
    this.skyQuality,
    this.skyTemperature,
    this.rainRate,
  });
}

/// Optional capability implemented by backends that can read live weather
/// and safety-monitor state. It is deliberately separate from [DeviceBackend]
/// so lightweight test backends are not forced to fake safety telemetry.
abstract interface class EnvironmentalStatusBackend {
  Future<HardwareWeatherConditions> getHardwareWeatherConditions(
    String deviceId,
  );

  Future<bool> getHardwareSafetyStatus(String deviceId);
}

/// Live dome telemetry read back from the driver.
///
/// Mirrors the fields the native `api_get_dome_status` / headless
/// `GET /api/dome/status` already return. `shutterStatus` is the raw ASCOM
/// shutter code so both backends can map into it without importing the UI's
/// `ShutterStatus` enum:
/// 0 = open, 1 = closed, 2 = opening, 3 = closing, 4 = error. Anything else
/// (including a driver that does not implement the property) is reported as
/// `null` — "unknown" — never silently coerced to `closed`.
class HardwareDomeStatus {
  final double? azimuth;
  final double? altitude;
  final int? shutterStatus;
  final bool isSlewing;
  final bool isAtHome;
  final bool isParked;
  final bool isSlaved;

  const HardwareDomeStatus({
    this.azimuth,
    this.altitude,
    this.shutterStatus,
    this.isSlewing = false,
    this.isAtHome = false,
    this.isParked = false,
    this.isSlaved = false,
  });
}

/// Optional capability implemented by backends that can read live dome state.
///
/// Separate from [DeviceBackend] for the same reason as
/// [EnvironmentalStatusBackend]: lightweight test backends must not be forced
/// to fake dome telemetry.
///
/// Backs the dome card's azimuth / shutter readouts and the Open/Close Shutter
/// label, which read hardware state rather than the last command sent.
abstract interface class DomeStatusBackend {
  Future<HardwareDomeStatus> getHardwareDomeStatus(String deviceId);
}

/// Role interface covering driver-bound device operations.
///
/// What this role owns:
///   * Device discovery (native, INDI, Alpaca, ASCOM).
///   * Connect / disconnect of any device the suite supports.
///   * Per-device-class control: camera, mount, focuser + autofocus, filter
///     wheel, rotator.
///   * Per-device capability + status queries.
///   * Device health / heartbeat monitoring.
///
/// What this role deliberately does NOT own:
///   * The event stream — see [DiagnosticsBackend].
///   * Image processing / plate solving — see [ImagingBackend]. Camera
///     capture lives here (it is a device command); turning pixel buffers
///     into stats, stretches, debayers, or solved coordinates lives in
///     [ImagingBackend].
///   * Guiding control (PHD2 + generic guider) — see [GuidingBackend].
///   * Sequencer / recovery / checkpoint — see [SequencerBackend].
///
/// Note: autofocus is included here despite straddling focuser + camera —
/// it is initiated against a focuser device id, the autofocus loop is
/// owned by the focuser/camera drivers in Rust, and the orchestration is
/// stateless from the Dart side.
abstract class DeviceBackend {
  // Device Discovery & Connection

  /// Discover available devices of a specific type
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType);

  /// Discover INDI devices at a specific server address
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port);

  /// Discover Alpaca devices at a specific server address
  Future<List<DeviceInfo>> discoverAlpacaAtAddress(String host, int port);

  /// Connect to a device
  Future<void> connectDevice(DeviceType deviceType, String deviceId);

  /// Disconnect from a device
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId);

  /// Get list of currently connected devices
  Future<List<DeviceInfo>> getConnectedDevices();

  /// Force an immediate hot-plug re-enumeration on the *active backend's host*.
  ///
  /// This is the backend-routed cousin of [discoverDevices]: where discovery
  /// returns a snapshot list, rescan re-walks the native vendor SDKs and (on
  /// Windows) the ASCOM registry on the host, invalidates the host-side
  /// discovery cache, and emits `device_discovered` / `device_lost` events for
  /// any deltas. Wired to the equipment-screen "Rescan equipment" button.
  ///
  /// This is a backend op and not a direct `bridge_api` FFI call because on a
  /// remote client (phone) a direct FFI call rescans the *phone's* empty local
  /// backend and falsely reports success. Routing through the active backend
  /// makes rescan reach the HOST that actually owns the hardware buses.
  ///
  /// Completes when the host-side diff pass finishes. The UI awaits this for
  /// its spinner and only reports success on genuine completion. Throws if the
  /// routed call fails (e.g. transport error on a remote client), so the
  /// failure reaches the operator instead of a success toast.
  Future<void> rescanDevices();

  // Camera control

  /// Start a camera exposure
  ///
  /// [gain] and [offset] are optional - if null, the camera's current/default
  /// settings will be used. This supports cameras that don't have adjustable gain/offset.
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  });

  /// Abort current camera exposure
  Future<void> cameraAbortExposure(String deviceId);

  /// Get the last captured image for a specific device
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId);

  /// Capture a live-view preview JPEG from the camera when the driver supports it.
  ///
  /// Throws [SkotiqError] when the driver rejects the operation. Remote
  /// clients should treat HTTP 503 from the headless host as "preview unavailable".
  Future<Uint8List> cameraLiveViewFrame(String deviceId);

  /// Get the last captured raw image data (u16 pixels) for a specific device
  Future<List<int>> getLastRawImageData(String deviceId);

  /// Clear stored image data for a specific device
  /// This frees memory when a camera is disconnected or when explicitly requested
  Future<void> clearDeviceImage(String deviceId);

  /// Set camera cooling
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  });

  /// Set camera readout mode by index
  /// modeIndex: 0 = default/high quality, 1 = fast readout, etc.
  Future<void> cameraSetReadoutMode(String deviceId, int modeIndex);

  /// Set camera gain
  Future<void> cameraSetGain(String deviceId, int gain);

  /// Set camera offset
  Future<void> cameraSetOffset(String deviceId, int offset);

  /// Query the camera SDK for manufacturer-recommended gain/offset values.
  ///
  /// Returns a [CameraRecommendedSettings] with whatever the vendor SDK
  /// reports. All fields are `null` on cameras whose SDK does not expose
  /// per-camera recommendations (Touptek, Player One, Atik, FLI, Moravian,
  /// ASCOM, Alpaca, INDI, gphoto2/Fujifilm). Callers MUST treat `null` as
  /// "no recommendation available" and never fabricate values.
  Future<CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  );

  // Mount control

  /// Slew mount to coordinates
  Future<void> mountSlewToCoordinates(String deviceId, double ra, double dec);

  /// Sync mount to coordinates
  Future<void> mountSync(String deviceId, double ra, double dec);

  /// Park the mount
  Future<void> mountPark(String deviceId);

  /// Unpark the mount
  Future<void> mountUnpark(String deviceId);

  /// Set mount tracking
  Future<void> mountSetTracking(String deviceId, bool enabled);

  /// Pulse guide (for corrections)
  Future<void> mountPulseGuide({
    required String deviceId,
    required String direction,
    required int durationMs,
  });

  /// Abort mount slew
  Future<void> mountAbort(String deviceId);

  /// Get mount status
  Future<dynamic> mountGetStatus(String deviceId);

  /// Set mount tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
  Future<void> mountSetTrackingRate(String deviceId, int rate);

  /// Move mount axis at specified rate (degrees/second)
  /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
  /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
  Future<void> mountMoveAxis(String deviceId, int axis, double rate);

  /// Slew mount to alt/az coordinates (altitude in degrees, azimuth in degrees)
  Future<void> mountSlewAltAz(String deviceId, double altitude, double azimuth);

  /// Find mount home position
  Future<void> mountFindHome(String deviceId);

  /// Which site/time directions this mount's driver can actually honour.
  Future<MountSiteCapabilities> mountSiteCapabilities(String deviceId);

  /// The site the mount itself is configured for. Longitude is EAST-positive.
  Future<MountSite> mountGetSite(String deviceId);

  /// Write a site into the mount. Longitude is EAST-positive.
  Future<void> mountSetSite(
    String deviceId,
    double latitudeDeg,
    double longitudeDeg,
    double? elevationM,
  );

  /// The mount's own clock.
  Future<MountTimeInfo> mountGetTime(String deviceId);

  /// Write a clock into the mount. [utcOffsetHours] is east of UTC in the
  /// ordinary sense: US Eastern Standard is -5.0.
  Future<void> mountSetTime(
    String deviceId,
    int utcUnixSeconds,
    double utcOffsetHours,
  );

  // Focuser control

  /// Move focuser to absolute position
  Future<void> focuserMoveTo(String deviceId, int position);

  /// Move focuser by relative amount
  Future<void> focuserMoveRelative(String deviceId, int delta);

  /// Halt focuser movement
  Future<void> focuserHalt(String deviceId);

  /// Run autofocus
  /// Returns the full autofocus result including focus curve data
  Future<AutofocusResult> autofocusStart({
    required String deviceId,
    required String cameraId,
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    int? gain,
    int? offset,
    String curveFitting = 'Hyperbolic',
    int numberOfAttempts = 1,
    int exposuresPerPoint = 1,
    double rSquaredThreshold = 0.7,
    double outerCropRatio = 1.0,
    double innerCropRatio = 0.0,
    int useBrightestNStars = 10,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,

    /// Backlash this app measured on [deviceId], from its stored calibration,
    /// or null when it has never been calibrated. Never overrides
    /// [backlashIn]: a figure the operator typed outranks a measured one.
    int? measuredBacklashIn,
  });

  /// Cancel autofocus
  Future<void> autofocusCancel();

  /// Measure the focuser's backlash by scanning focus twice, approaching
  /// every point from below on one pass and from above on the other.
  ///
  /// Returns the outcome JSON native produced, unaltered — the evidence, the
  /// confidence with its grounds, or a tagged refusal with the remedy already
  /// worded for the operator. It travels as JSON rather than as a parsed model
  /// so the remote hop and the headless route relay exactly what the routine
  /// concluded, and [FocuserBacklashResult.tryParse] stays the single place
  /// that reads it.
  ///
  /// A refusal comes back here, not as an exception: the run happened and
  /// reached a conclusion, which is that no figure is warranted. An exception
  /// means the run could not happen.
  Future<String> focuserBacklashCalibrationStart({
    required String deviceId,
    required String cameraId,
    required String configJson,
  });

  /// Ask a running backlash calibration to stop. The routine returns the
  /// focuser to where the operator left it before reporting the cancellation.
  Future<void> focuserBacklashCalibrationCancel();

  /// What a backlash calibration would cost, without running it, as the plan
  /// JSON native produced.
  Future<String> focuserBacklashCalibrationPlan({
    required String configJson,
    required int centerPosition,
  });

  // Filter wheel control

  /// Set filter wheel position
  Future<void> filterWheelSetPosition(String deviceId, int position);

  /// Get filter names
  Future<List<String>> filterWheelGetNames(String deviceId);

  /// Set filter names
  Future<void> filterWheelSetNames(String deviceId, List<String> names);

  /// Set filter by name
  Future<void> filterWheelSetByName(String deviceId, String name);

  // Rotator control

  /// Move rotator to absolute angle
  Future<void> rotatorMoveTo(String deviceId, double angle);

  /// Move rotator by relative angle
  Future<void> rotatorMoveRelative(String deviceId, double delta);

  /// Get rotator angle
  Future<double> rotatorGetAngle(String deviceId);

  /// Halt rotator
  Future<void> rotatorHalt(String deviceId);

  /// Set the rotator's reverse-direction flag (IRotatorV3 `Reverse`,
  /// Alpaca `reverse`, INDI `ROTATOR_REVERSE`). Only valid when the driver
  /// reports `canReverse`.
  Future<void> rotatorSetReverse(String deviceId, bool reverse);

  /// Sync the rotator's reported sky position-angle (degrees) to [pa] without
  /// moving the hardware. Why a separate method from [rotatorMoveTo]: ASCOM
  /// IRotatorV3 distinguishes Sync (offset-only) from MoveAbsolute (motion);
  /// the "Sync to image PA" plate-solve workflow needs the Sync semantic.
  Future<void> rotatorSyncToPa(String deviceId, double pa);

  // Dome control

  /// Open the dome shutter
  Future<void> domeOpenShutter(String deviceId);

  /// Close the dome shutter
  Future<void> domeCloseShutter(String deviceId);

  /// Slew the dome to an azimuth (degrees)
  Future<void> domeSlewToAzimuth(String deviceId, double azimuth);

  /// Enable/disable dome-mount slaving (slewing the dome with the mount)
  Future<void> domeSetSlaved(String deviceId, bool slaved);

  /// Park the dome
  Future<void> domePark(String deviceId);

  /// Move the dome to its home position. ASCOM domes have no explicit unpark
  /// verb; finding home releases the parked state (standard ASCOM behaviour).
  Future<void> domeFindHome(String deviceId);

  /// Abort dome slew/movement
  Future<void> domeAbortSlew(String deviceId);

  // Cover calibrator control

  /// Open the cover
  Future<void> coverOpen(String deviceId);

  /// Close the cover
  Future<void> coverClose(String deviceId);

  /// Turn the calibrator light on at [brightness]
  Future<void> calibratorOn(String deviceId, int brightness);

  /// Turn the calibrator light off
  Future<void> calibratorOff(String deviceId);

  // Equipment status

  /// Get camera status
  /// Returns typed CameraStatus with all sensor and cooling information
  Future<CameraStatus> getCameraStatus(String deviceId);

  /// Get mount status
  /// Returns typed MountStatus with position, tracking, and capability flags
  Future<MountStatus> getMountStatus(String deviceId);

  /// Get focuser status
  /// Returns typed FocuserStatus with position, movement, and temperature info
  Future<FocuserStatus> getFocuserStatus(String deviceId);

  /// Get filter wheel status
  /// Returns typed FilterWheelStatus with position and filter names
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId);

  /// Get rotator status
  /// Returns typed RotatorStatus with position and movement info
  Future<RotatorStatus> getRotatorStatus(String deviceId);

  // Device capabilities

  /// Get camera capabilities
  /// Returns null if the device is not connected or capabilities unavailable
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId);

  /// Get mount capabilities
  /// Returns null if the device is not connected or capabilities unavailable
  Future<MountCapabilities?> getMountCapabilities(String deviceId);

  /// Get focuser capabilities
  /// Returns null if the device is not connected or capabilities unavailable
  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId);

  /// Get filter wheel capabilities
  /// Returns null if the device is not connected or capabilities unavailable
  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(String deviceId);

  /// Get rotator capabilities
  /// Returns null if the device is not connected or capabilities unavailable
  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId);

  // Device health monitoring

  /// Start heartbeat monitoring for a device
  ///
  /// Periodically checks if the device is responding and emits disconnect
  /// events if communication fails.
  ///
  /// # Arguments
  /// * `deviceType` - Type of device to monitor
  /// * `deviceId` - Unique identifier for the device
  /// * `intervalMs` - Heartbeat interval in milliseconds (recommended: 10000)
  Future<void> startDeviceHeartbeat({
    required DeviceType deviceType,
    required String deviceId,
    required int intervalMs,
  });

  /// Stop heartbeat monitoring for a device
  ///
  /// # Arguments
  /// * `deviceId` - The unique identifier for the device
  Future<void> stopDeviceHeartbeat(String deviceId);

  /// Check device health status
  ///
  /// Returns the last successful communication timestamp and whether
  /// the device is currently responding to heartbeat checks.
  ///
  /// # Arguments
  /// * `deviceId` - The unique identifier for the device
  ///
  /// # Returns
  /// A tuple of (last_successful_timestamp_ms, is_healthy)
  Future<(int, bool)> getDeviceHealth(String deviceId);
}
