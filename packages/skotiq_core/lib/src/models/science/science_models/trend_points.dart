part of '../science_models.dart';

class LightCurvePoint {
  final DateTime timestamp;
  final double flux;
  final double differentialMagnitude;
  final double snr;
  final double uncertainty;

  const LightCurvePoint({
    required this.timestamp,
    required this.flux,
    required this.differentialMagnitude,
    required this.snr,
    required this.uncertainty,
  });
}

class TransparencyTrendPoint {
  final DateTime timestamp;
  final double transparencyPercent;
  final double extinctionCoefficient;

  const TransparencyTrendPoint({
    required this.timestamp,
    required this.transparencyPercent,
    required this.extinctionCoefficient,
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
