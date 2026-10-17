import 'package:freezed_annotation/freezed_annotation.dart';
import 'weather_alert.dart';
import 'cloud_motion.dart';
import 'radar_frame.dart';

part 'weather_status.freezed.dart';
part 'weather_status.g.dart';

/// Combined weather status for UI display
@freezed
abstract class WeatherStatus with _$WeatherStatus {
  const factory WeatherStatus({
    /// Current alert level
    @Default(AlertLevel.clear) AlertLevel currentLevel,

    /// Active alert (null if no alert)
    WeatherAlert? activeAlert,

    /// Cloud motion analysis
    CloudMotion? motion,

    /// Radar frames for animation
    @Default([]) List<RadarFrame> radarFrames,

    /// Current frame index in animation
    @Default(0) int currentFrameIndex,

    /// When the radar data behind this status was last fetched.
    ///
    /// NULL until the first successful fetch lands. It is deliberately nullable
    /// rather than defaulting to a sentinel: an epoch-zero placeholder here is
    /// indistinguishable from a real timestamp downstream, and the card
    /// rendered it as "Updated 20667 days ago" on every pre-fetch paint (and
    /// for the whole session when the fetch never succeeds).
    DateTime? lastUpdate,

    /// Whether data is currently loading
    @Default(false) bool isLoading,

    /// Error message if update failed
    String? errorMessage,
  }) = _WeatherStatus;

  factory WeatherStatus.fromJson(Map<String, dynamic> json) =>
      _$WeatherStatusFromJson(json);
}
