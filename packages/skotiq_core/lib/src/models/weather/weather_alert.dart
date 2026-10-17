import 'package:freezed_annotation/freezed_annotation.dart';

part 'weather_alert.freezed.dart';
part 'weather_alert.g.dart';

/// Alert severity level
enum AlertLevel {
  /// No threats detected, conditions are clear
  clear,

  /// Clouds detected but not immediately threatening
  watch,

  /// Clouds approaching, intervention may be needed soon
  warning,

  /// Immediate threat, protective action required
  critical,
}

/// Weather alert for astrophotography safety
@freezed
abstract class WeatherAlert with _$WeatherAlert {
  const factory WeatherAlert({
    /// Alert severity level
    required AlertLevel level,

    /// Human-readable alert text
    required String message,

    /// When clouds expected (null if clear/watch)
    DateTime? eta,

    /// Cloud density percentage (0-100)
    required double cloudDensityPercent,

    /// Distance to threatening clouds in kilometers
    required double distanceKm,

    /// When this alert was generated
    required DateTime generatedAt,
  }) = _WeatherAlert;

  factory WeatherAlert.fromJson(Map<String, dynamic> json) =>
      _$WeatherAlertFromJson(json);
}
