import 'package:freezed_annotation/freezed_annotation.dart';

part 'weather_settings.freezed.dart';
part 'weather_settings.g.dart';

/// Radar/satellite data provider type
enum RadarProviderType {
  /// Automatically select best available provider
  auto,

  /// GOES satellite infrared imagery (US/Americas - shows all clouds)
  goesSatellite,

  /// NOAA NEXRAD precipitation radar (US only - shows rain/snow)
  noaa,

  /// RainViewer global precipitation radar
  rainviewer,

  /// Open-Meteo weather API
  openmeteo,

  /// MET Norway Locationforecast (global cloud forecast, fallback)
  metno,
}

/// Weather monitoring and safety settings
@freezed
abstract class WeatherSettings with _$WeatherSettings {
  const factory WeatherSettings({
    /// Distance threshold for alerts in kilometers
    @Default(30.0) double triggerDistanceKm,

    /// Cloud density threshold for warnings (0-100 percent)
    @Default(60.0) double cloudDensityThreshold,

    /// Lead time for alerts in minutes
    @Default(15) int leadTimeMinutes,

    /// Enable weather safety monitoring.
    ///
    /// Defaults OFF: with no weather source or hardware safety monitor
    /// configured (the out-of-box state), an enabled monitor fails closed and
    /// aborts every automated sequence within seconds — the flagship use case
    /// broken on night one for the majority of rigs. Weather gating is now
    /// opt-in; a user connects a weather source / safety monitor and turns
    /// this on. Existing installs keep their persisted value.
    @Default(false) bool weatherSafetyEnabled,

    /// Maximum safe humidity before weather safety pauses imaging
    @Default(90.0) double maxHumidityPercent,

    /// Maximum safe wind speed before weather safety pauses imaging
    @Default(30.0) double maxWindSpeedKph,

    /// Maximum safe cloud cover before weather safety pauses imaging
    @Default(80.0) double maxCloudCoverPercent,

    /// Automatically park mount when weather threatens
    @Default(true) bool autoParkEnabled,

    /// Automatically resume imaging when weather clears
    @Default(false) bool autoResumeEnabled,

    /// Preferred radar data provider
    @Default(RadarProviderType.auto) RadarProviderType preferredProvider,

    /// How often to refresh radar data in seconds
    @Default(300) int refreshIntervalSeconds,
  }) = _WeatherSettings;

  factory WeatherSettings.fromJson(Map<String, dynamic> json) =>
      _$WeatherSettingsFromJson(json);

  /// Default weather settings instance
  static WeatherSettings get defaultSettings => const WeatherSettings();
}
