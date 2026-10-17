part of '../equipment_models.dart';

/// Weather state
class WeatherState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final double? temperature;
  final double? humidity;
  final double? pressure;
  final double? cloudCover;
  final double? dewPoint;

  /// Wind speed as reported by the native device layer, in metres/second.
  ///
  /// Use [windSpeedKph] anywhere the value is compared with Skotiq's
  /// operator-facing weather thresholds, which are stored in km/h.
  final double? windSpeed;
  final double? windDirection;
  final double? skyQuality;
  final double? skyTemperature;
  final double? rainRate;
  final DateTime? lastUpdated;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const WeatherState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
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
    this.lastUpdated,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  double? get windSpeedKph => windSpeed == null ? null : windSpeed! * 3.6;
  WeatherState clearError() => copyWith(clearError: true);

  WeatherState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    double? temperature,
    double? humidity,
    double? pressure,
    double? cloudCover,
    double? dewPoint,
    double? windSpeed,
    double? windDirection,
    double? skyQuality,
    double? skyTemperature,
    double? rainRate,
    DateTime? lastUpdated,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return WeatherState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      temperature: temperature ?? this.temperature,
      humidity: humidity ?? this.humidity,
      pressure: pressure ?? this.pressure,
      cloudCover: cloudCover ?? this.cloudCover,
      dewPoint: dewPoint ?? this.dewPoint,
      windSpeed: windSpeed ?? this.windSpeed,
      windDirection: windDirection ?? this.windDirection,
      skyQuality: skyQuality ?? this.skyQuality,
      skyTemperature: skyTemperature ?? this.skyTemperature,
      rainRate: rainRate ?? this.rainRate,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    temperature,
    humidity,
    pressure,
    cloudCover,
    dewPoint,
    windSpeed,
    windDirection,
    skyQuality,
    skyTemperature,
    rainRate,
    lastUpdated,
    lastError,
    autoReconnectEnabled,
  ];
}

/// Safety monitor state
class SafetyMonitorState extends Equatable {
  final DeviceConnectionState connectionState;
  final String? deviceId;
  final String? deviceName;
  final bool isSafe;
  final DateTime? lastChecked;
  final DeviceError? lastError;

  /// Whether auto-reconnection is enabled for this device.
  final bool autoReconnectEnabled;

  const SafetyMonitorState({
    this.connectionState = DeviceConnectionState.disconnected,
    this.deviceId,
    this.deviceName,
    this.isSafe = true,
    this.lastChecked,
    this.lastError,
    this.autoReconnectEnabled = true,
  });

  bool get hasError => lastError != null;
  SafetyMonitorState clearError() => copyWith(clearError: true);

  SafetyMonitorState copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    bool? isSafe,
    DateTime? lastChecked,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError = false,
  }) {
    return SafetyMonitorState(
      connectionState: connectionState ?? this.connectionState,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      isSafe: isSafe ?? this.isSafe,
      lastChecked: lastChecked ?? this.lastChecked,
      lastError: clearError ? null : (lastError ?? this.lastError),
      autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    );
  }

  @override
  List<Object?> get props => [
    connectionState,
    deviceId,
    deviceName,
    isSafe,
    lastChecked,
    lastError,
    autoReconnectEnabled,
  ];
}
