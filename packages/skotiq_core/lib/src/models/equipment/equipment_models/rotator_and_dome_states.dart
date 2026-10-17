part of '../equipment_models.dart';

/// Rotator state
class RotatorState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final double? position;
  final double? mechanicalPosition;
  final bool isMoving;
  final bool isReversed;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const RotatorState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.position,
    this.mechanicalPosition,
    this.isMoving = false,
    this.isReversed = false,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  RotatorState clearError() => copyWith(clearError: true);

  RotatorState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    double? position,
    double? mechanicalPosition,
    bool? isMoving,
    bool? isReversed,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return RotatorState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      position: position ?? this.position,
      mechanicalPosition: mechanicalPosition ?? this.mechanicalPosition,
      isMoving: isMoving ?? this.isMoving,
      isReversed: isReversed ?? this.isReversed,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    position,
    mechanicalPosition,
    isMoving,
    isReversed,
    lastError,
    autoReconnectEnabled,
  ];
}

/// Dome shutter status
enum ShutterStatus { open, closed, opening, closing, error, unknown }

/// Dome state
class DomeState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final double? azimuth;
  final ShutterStatus shutterStatus;
  final bool isSlewing;
  final bool isParked;
  final bool isAtHome;
  final bool isSlaved;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const DomeState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.azimuth,
    this.shutterStatus = ShutterStatus.unknown,
    this.isSlewing = false,
    this.isParked = false,
    this.isAtHome = false,
    this.isSlaved = false,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  DomeState clearError() => copyWith(clearError: true);

  DomeState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    double? azimuth,
    ShutterStatus? shutterStatus,
    bool? isSlewing,
    bool? isParked,
    bool? isAtHome,
    bool? isSlaved,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return DomeState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      azimuth: azimuth ?? this.azimuth,
      shutterStatus: shutterStatus ?? this.shutterStatus,
      isSlewing: isSlewing ?? this.isSlewing,
      isParked: isParked ?? this.isParked,
      isAtHome: isAtHome ?? this.isAtHome,
      isSlaved: isSlaved ?? this.isSlaved,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    azimuth,
    shutterStatus,
    isSlewing,
    isParked,
    isAtHome,
    isSlaved,
    lastError,
    autoReconnectEnabled,
  ];
}
