import 'package:freezed_annotation/freezed_annotation.dart';

part 'cloud_motion.freezed.dart';
part 'cloud_motion.g.dart';

/// Cloud movement analysis and prediction
@freezed
abstract class CloudMotion with _$CloudMotion {
  const factory CloudMotion({
    /// Cloud movement speed in km/h
    required double speedKmh,

    /// Direction clouds are moving TOWARD (0-360, 0=N, 90=E, 180=S, 270=W)
    required double directionDegrees,

    /// Time until clouds reach user location (null if moving away)
    Duration? etaToLocation,

    /// Current distance of nearest significant clouds in kilometers
    required double distanceKm,

    /// When this analysis was performed
    required DateTime calculatedAt,
  }) = _CloudMotion;

  factory CloudMotion.fromJson(Map<String, dynamic> json) =>
      _$CloudMotionFromJson(json);
}
