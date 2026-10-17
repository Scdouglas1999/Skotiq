part of '../equipment_models.dart';

/// Camera state snapshot
class CameraStateSnapshot extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final double? temperature;
  final double? coolerPower;

  /// User-set target temperature for cooling
  final double targetTemp;
  final int? gain;
  final int? offset;
  final String? binning;
  final bool isCooling;
  final bool isWarming;
  final bool isExposing;
  final double? exposureProgress;
  final DeviceError? lastError;

  /// Last successful communication timestamp
  final DateTime? lastSuccessfulCommunication;

  /// Whether auto-reconnection is enabled for this device
  final bool autoReconnectEnabled;

  const CameraStateSnapshot({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.temperature,
    this.coolerPower,
    this.targetTemp = -10.0,
    this.gain,
    this.offset,
    this.binning,
    this.isCooling = false,
    this.isWarming = false,
    this.isExposing = false,
    this.exposureProgress,
    this.lastError,
    this.lastSuccessfulCommunication,
    this.autoReconnectEnabled = true,
  });

  /// Whether the camera has an error
  bool get hasError => lastError != null;

  /// Whether the device is healthy (communicated within last 30 seconds)
  bool get isHealthy {
    if (connectionState != DeviceConnectionState.connected) return false;
    if (lastSuccessfulCommunication == null) {
      return true; // Optimistic for new connections
    }
    return DateTime.now().difference(lastSuccessfulCommunication!).inSeconds <
        30;
  }

  /// Clear error and return a new state
  CameraStateSnapshot clearError() => copyWith(clearError: true);

  CameraStateSnapshot copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    double? temperature,
    double? coolerPower,
    bool clearCoolerPower = false,
    double? targetTemp,
    int? gain,
    int? offset,
    String? binning,
    bool? isCooling,
    bool? isWarming,
    bool? isExposing,
    double? exposureProgress,
    DeviceError? lastError,
    DateTime? lastSuccessfulCommunication,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return CameraStateSnapshot(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      temperature: temperature ?? this.temperature,
      coolerPower: clearCoolerPower ? null : (coolerPower ?? this.coolerPower),
      targetTemp: targetTemp ?? this.targetTemp,
      gain: gain ?? this.gain,
      offset: offset ?? this.offset,
      binning: binning ?? this.binning,
      isCooling: isCooling ?? this.isCooling,
      isWarming: isWarming ?? this.isWarming,
      isExposing: isExposing ?? this.isExposing,
      exposureProgress: exposureProgress ?? this.exposureProgress,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastSuccessfulCommunication:
          lastSuccessfulCommunication ?? this.lastSuccessfulCommunication,
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    temperature,
    coolerPower,
    targetTemp,
    gain,
    offset,
    binning,
    isCooling,
    isWarming,
    isExposing,
    exposureProgress,
    lastError,
    lastSuccessfulCommunication,
    autoReconnectEnabled,
  ];
}

/// Mount state
class MountState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final double? ra;
  final double? dec;
  final double? altitude;
  final double? azimuth;
  final bool isTracking;
  final bool isSlewing;
  final bool isParked;
  final String? sideOfPier;
  final TrackingRate trackingRate;
  final bool canSetTrackingRate;
  final bool canPark;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device. Defaults to `true`
  /// so an unattended rig recovers a dropped link without an operator.
  final bool autoReconnectEnabled;

  const MountState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.ra,
    this.dec,
    this.altitude,
    this.azimuth,
    this.isTracking = false,
    this.isSlewing = false,
    this.isParked = true,
    this.sideOfPier,
    this.trackingRate = TrackingRate.sidereal,
    this.canSetTrackingRate = false,
    this.canPark = true,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  MountState clearError() => copyWith(clearError: true);

  MountState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    double? ra,
    double? dec,
    double? altitude,
    double? azimuth,
    bool? isTracking,
    bool? isSlewing,
    bool? isParked,
    String? sideOfPier,
    TrackingRate? trackingRate,
    bool? canSetTrackingRate,
    bool? canPark,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
    bool clearHorizonFrame = false,
  }) {
    return MountState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      ra: ra ?? this.ra,
      dec: dec ?? this.dec,
      // A null [altitude]/[azimuth] argument means "leave unchanged" like every
      // other field here, so a poll that reports the horizon frame as UNKNOWN
      // needs [clearHorizonFrame] to say so — otherwise the last computed pair
      // outlives the site it was computed for and keeps being drawn as live.
      altitude: clearHorizonFrame ? null : (altitude ?? this.altitude),
      azimuth: clearHorizonFrame ? null : (azimuth ?? this.azimuth),
      isTracking: isTracking ?? this.isTracking,
      isSlewing: isSlewing ?? this.isSlewing,
      isParked: isParked ?? this.isParked,
      sideOfPier: sideOfPier ?? this.sideOfPier,
      trackingRate: trackingRate ?? this.trackingRate,
      canSetTrackingRate: canSetTrackingRate ?? this.canSetTrackingRate,
      canPark: canPark ?? this.canPark,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    ra,
    dec,
    altitude,
    azimuth,
    isTracking,
    isSlewing,
    isParked,
    sideOfPier,
    trackingRate,
    canSetTrackingRate,
    canPark,
    lastError,
    autoReconnectEnabled,
  ];
}
