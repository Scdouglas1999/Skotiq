part of '../science_models.dart';

class LightCurvePoint {
  final DateTime timestamp;
  final double flux;
  final double differentialMagnitude;
  final double snr;
  final double uncertainty;

  /// The frame's filter. Differential magnitudes of different filters differ
  /// by the target's color against the comparisons and are not one curve.
  final String? filter;

  const LightCurvePoint({
    required this.timestamp,
    required this.flux,
    required this.differentialMagnitude,
    required this.snr,
    required this.uncertainty,
    this.filter,
  });
}

/// The points of [points] taken in [filter], or, with no [filter], in the
/// newest point's filter. A light curve is one filter: differential
/// magnitudes in different filters differ by the target's color.
List<LightCurvePoint> lightCurveInFilter(
  List<LightCurvePoint> points, {
  String? filter,
}) {
  if (points.isEmpty) return points;
  final newest = points.reduce(
    (a, b) => a.timestamp.isAfter(b.timestamp) ? a : b,
  );
  final wanted = filter ?? newest.filter;
  return points.where((p) => p.filter == wanted).toList(growable: false);
}

class TransparencyTrendPoint {
  final DateTime timestamp;
  final double transparencyPercent;
  final double extinctionCoefficient;

  /// Whether [extinctionCoefficient] is a measured extinction.
  final bool extinctionMeasured;
  final String? filter;

  const TransparencyTrendPoint({
    required this.timestamp,
    required this.transparencyPercent,
    required this.extinctionCoefficient,
    this.extinctionMeasured = false,
    this.filter,
  });
}

class MovingObjectCandidate {
  final DateTime timestamp;
  final String candidateId;
  final double confidence;
  final double motionArcsecPerMinute;
  final String? objectName;

  const MovingObjectCandidate({
    required this.timestamp,
    required this.candidateId,
    required this.confidence,
    required this.motionArcsecPerMinute,
    this.objectName,
  });
}
