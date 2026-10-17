part of '../equipment_models.dart';

/// Focuser state
class FocuserState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final int? position;
  final int? maxPosition;
  final double? stepSize;
  final bool isAbsolute;
  final bool hasTemperature;
  final double? temperature;
  final bool isMoving;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const FocuserState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.position,
    this.maxPosition,
    this.stepSize,
    this.isAbsolute = false,
    this.hasTemperature = false,
    this.temperature,
    this.isMoving = false,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  FocuserState clearError() => copyWith(clearError: true);

  FocuserState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    int? position,
    int? maxPosition,
    double? stepSize,
    bool? isAbsolute,
    bool? hasTemperature,
    double? temperature,
    bool? isMoving,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return FocuserState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      position: position ?? this.position,
      maxPosition: maxPosition ?? this.maxPosition,
      stepSize: stepSize ?? this.stepSize,
      isAbsolute: isAbsolute ?? this.isAbsolute,
      hasTemperature: hasTemperature ?? this.hasTemperature,
      temperature: temperature ?? this.temperature,
      isMoving: isMoving ?? this.isMoving,
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
    maxPosition,
    stepSize,
    isAbsolute,
    hasTemperature,
    temperature,
    isMoving,
    lastError,
    autoReconnectEnabled,
  ];
}

/// Filter wheel state
class FilterWheelState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final int? currentPosition;
  final List<String> filterNames;
  final bool isMoving;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const FilterWheelState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.currentPosition,
    this.filterNames = const [],
    this.isMoving = false,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  String? get currentFilterName {
    if (currentPosition != null &&
        currentPosition! >= 0 &&
        currentPosition! < filterNames.length) {
      return filterNames[currentPosition!];
    }
    return null;
  }

  bool get hasError => lastError != null;
  FilterWheelState clearError() => copyWith(clearError: true);

  FilterWheelState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    int? currentPosition,
    List<String>? filterNames,
    bool? isMoving,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return FilterWheelState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      currentPosition: currentPosition ?? this.currentPosition,
      filterNames: filterNames ?? this.filterNames,
      isMoving: isMoving ?? this.isMoving,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    currentPosition,
    filterNames,
    isMoving,
    lastError,
    autoReconnectEnabled,
  ];
}

/// Guider state
class GuiderState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final bool isGuiding;
  final bool isCalibrating;
  final double? rmsRa;
  final double? rmsDec;
  final double? rmsTotal;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const GuiderState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.isGuiding = false,
    this.isCalibrating = false,
    this.rmsRa,
    this.rmsDec,
    this.rmsTotal,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  GuiderState clearError() => copyWith(clearError: true);

  GuiderState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    bool? isGuiding,
    bool? isCalibrating,
    double? rmsRa,
    double? rmsDec,
    double? rmsTotal,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return GuiderState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      isGuiding: isGuiding ?? this.isGuiding,
      isCalibrating: isCalibrating ?? this.isCalibrating,
      rmsRa: rmsRa ?? this.rmsRa,
      rmsDec: rmsDec ?? this.rmsDec,
      rmsTotal: rmsTotal ?? this.rmsTotal,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    isGuiding,
    isCalibrating,
    rmsRa,
    rmsDec,
    rmsTotal,
    lastError,
    autoReconnectEnabled,
  ];
}
