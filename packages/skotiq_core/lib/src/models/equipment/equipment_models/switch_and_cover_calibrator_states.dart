part of '../equipment_models.dart';

/// Switch device state.
///
/// Mirrors [SafetyMonitorState] in shape ( / Audit C1). A switch
/// device exposes a fixed list of channels; each channel can be boolean
/// (relay) or numeric (PWM, dimmer, voltage rail). The Rust bridge exposes
/// these per-channel via `switch_get_state/value/name/description` calls —
/// we hold a snapshot here so the UI can render channel counts and labels
/// without re-fetching on every rebuild.
///
/// Boolean relays and numeric/PWM channels share this snapshot. The legacy
/// name/state lists remain convenient for compact telemetry, while the
/// capability lists let the Equipment screen render a slider for analog
/// channels and keep read-only channels visibly non-interactive.
class SwitchState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;

  /// Total number of channels reported by the driver (0 when unknown).
  ///
  /// Backed by Rust's `api_switch_get_max`. Cached on connect; channel
  /// counts on real ASCOM/INDI switches never change at runtime.
  final int channelCount;

  /// Per-channel display labels (driver-reported, name or description).
  /// Length matches [channelCount] when populated; may be empty if the
  /// driver returns nothing yet.
  final List<String> channelNames;

  /// Per-channel boolean state. Length matches [channelCount] when
  /// populated. Numeric channels collapse to `true` when above the midpoint
  /// of their advertised range, for compact on/off telemetry only.
  final List<bool> channelStates;

  /// Driver descriptions, channel kinds, current numeric values, ranges,
  /// increments, and writeability. Each populated list matches
  /// [channelCount]. Older snapshots may leave these empty; consumers must
  /// retain the boolean defaults in that case.
  final List<String> channelDescriptions;
  final List<bool> channelIsBoolean;
  final List<double> channelValues;
  final List<double> channelMinValues;
  final List<double> channelMaxValues;
  final List<double> channelSteps;
  final List<bool> channelCanWrite;

  /// Wall-clock time of the last successful channel snapshot refresh,
  /// or null when no refresh has completed yet. The UI uses this to
  /// dim/age the channel labels when polling is stale.
  final DateTime? lastChannelRefresh;

  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const SwitchState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.channelCount = 0,
    this.channelNames = const [],
    this.channelStates = const [],
    this.channelDescriptions = const [],
    this.channelIsBoolean = const [],
    this.channelValues = const [],
    this.channelMinValues = const [],
    this.channelMaxValues = const [],
    this.channelSteps = const [],
    this.channelCanWrite = const [],
    this.lastChannelRefresh,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  SwitchState clearError() => copyWith(clearError: true);

  SwitchState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    int? channelCount,
    List<String>? channelNames,
    List<bool>? channelStates,
    List<String>? channelDescriptions,
    List<bool>? channelIsBoolean,
    List<double>? channelValues,
    List<double>? channelMinValues,
    List<double>? channelMaxValues,
    List<double>? channelSteps,
    List<bool>? channelCanWrite,
    DateTime? lastChannelRefresh,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return SwitchState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      channelCount: channelCount ?? this.channelCount,
      channelNames: channelNames ?? this.channelNames,
      channelStates: channelStates ?? this.channelStates,
      channelDescriptions: channelDescriptions ?? this.channelDescriptions,
      channelIsBoolean: channelIsBoolean ?? this.channelIsBoolean,
      channelValues: channelValues ?? this.channelValues,
      channelMinValues: channelMinValues ?? this.channelMinValues,
      channelMaxValues: channelMaxValues ?? this.channelMaxValues,
      channelSteps: channelSteps ?? this.channelSteps,
      channelCanWrite: channelCanWrite ?? this.channelCanWrite,
      lastChannelRefresh: lastChannelRefresh ?? this.lastChannelRefresh,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    channelCount,
    channelNames,
    channelStates,
    channelDescriptions,
    channelIsBoolean,
    channelValues,
    channelMinValues,
    channelMaxValues,
    channelSteps,
    channelCanWrite,
    lastChannelRefresh,
    lastError,
    autoReconnectEnabled,
  ];
}

// Cover calibrator state

/// Cover position status
enum CoverStatus { notPresent, closed, moving, open, unknown, error }

/// Calibrator (flat light) status
enum CalibratorStatus { notPresent, off, notReady, ready, unknown, error }

class CoverCalibratorState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final CoverStatus coverStatus;
  final CalibratorStatus calibratorStatus;
  final int brightness;
  final int maxBrightness;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const CoverCalibratorState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.coverStatus = CoverStatus.unknown,
    this.calibratorStatus = CalibratorStatus.unknown,
    this.brightness = 0,
    this.maxBrightness = 100,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  bool get hasCover => coverStatus != CoverStatus.notPresent;
  bool get hasCalibrator => calibratorStatus != CalibratorStatus.notPresent;
  bool get isCoverOpen => coverStatus == CoverStatus.open;
  bool get isCoverClosed => coverStatus == CoverStatus.closed;
  bool get isCoverMoving => coverStatus == CoverStatus.moving;
  bool get isCalibratorOn => calibratorStatus == CalibratorStatus.ready;

  CoverCalibratorState clearError() => copyWith(clearError: true);

  CoverCalibratorState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    CoverStatus? coverStatus,
    CalibratorStatus? calibratorStatus,
    int? brightness,
    int? maxBrightness,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return CoverCalibratorState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      coverStatus: coverStatus ?? this.coverStatus,
      calibratorStatus: calibratorStatus ?? this.calibratorStatus,
      brightness: brightness ?? this.brightness,
      maxBrightness: maxBrightness ?? this.maxBrightness,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    coverStatus,
    calibratorStatus,
    brightness,
    maxBrightness,
    lastError,
    autoReconnectEnabled,
  ];
}
