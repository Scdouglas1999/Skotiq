// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cloud_motion.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_CloudMotion _$CloudMotionFromJson(Map<String, dynamic> json) => _CloudMotion(
  speedKmh: (json['speedKmh'] as num).toDouble(),
  directionDegrees: (json['directionDegrees'] as num).toDouble(),
  etaToLocation: json['etaToLocation'] == null
      ? null
      : Duration(microseconds: (json['etaToLocation'] as num).toInt()),
  distanceKm: (json['distanceKm'] as num).toDouble(),
  calculatedAt: DateTime.parse(json['calculatedAt'] as String),
);

Map<String, dynamic> _$CloudMotionToJson(_CloudMotion instance) =>
    <String, dynamic>{
      'speedKmh': instance.speedKmh,
      'directionDegrees': instance.directionDegrees,
      'etaToLocation': instance.etaToLocation?.inMicroseconds,
      'distanceKm': instance.distanceKm,
      'calculatedAt': instance.calculatedAt.toIso8601String(),
    };
