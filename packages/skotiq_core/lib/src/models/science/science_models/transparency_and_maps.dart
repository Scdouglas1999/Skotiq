part of '../science_models.dart';

class TransparencyOptions {
  final int rollingWindowSize;
  final int minimumSampleCount;
  final double minAirmassSpan;

  const TransparencyOptions({
    this.rollingWindowSize = 12,
    this.minimumSampleCount = 4,
    this.minAirmassSpan = 0.25,
  });
}

class TransparencySample {
  final int? capturedImageId;
  final int? sessionId;
  final DateTime timestamp;
  final double transparencyPercent;
  final double extinctionCoefficient;
  final String qualityBucket;
  final double confidence;

  /// True when [extinctionCoefficient] came from a real zero-point vs
  /// airmass regression (units: mag/airmass). False for the warm-up
  /// fallback path, where the value is a zero-point depression relative to
  /// the session baseline (units: mag) — informative for trends but NOT a
  /// physical extinction coefficient. Consumers that stamp the value with
  /// physical units (the EXTINCT FITS keyword) must check this flag.
  final bool extinctionFromAirmassFit;

  const TransparencySample({
    required this.capturedImageId,
    required this.sessionId,
    required this.timestamp,
    required this.transparencyPercent,
    required this.extinctionCoefficient,
    required this.qualityBucket,
    required this.confidence,
    this.extinctionFromAirmassFit = false,
  });
}

class PsfMapOptions {
  final int gridRows;
  final int gridCols;

  const PsfMapOptions({this.gridRows = 4, this.gridCols = 6});
}

class PsfTileMetric {
  final int row;
  final int col;
  final int starCount;
  final double medianFwhm;
  final double medianHfr;
  final double medianEccentricity;
  final double roundness;

  const PsfTileMetric({
    required this.row,
    required this.col,
    required this.starCount,
    required this.medianFwhm,
    required this.medianHfr,
    required this.medianEccentricity,
    required this.roundness,
  });
}

class PsfFieldMap {
  final int gridRows;
  final int gridCols;
  final List<PsfTileMetric> tiles;

  const PsfFieldMap({
    required this.gridRows,
    required this.gridCols,
    required this.tiles,
  });
}

class AstrometryOptions {
  final int sampleCount;

  const AstrometryOptions({this.sampleCount = 250});
}

class ResidualVectorSample {
  final double x;
  final double y;
  final double dxArcsec;
  final double dyArcsec;
  final double magnitudeArcsec;

  const ResidualVectorSample({
    required this.x,
    required this.y,
    required this.dxArcsec,
    required this.dyArcsec,
    required this.magnitudeArcsec,
  });
}

class AstrometricResidualMap {
  final List<ResidualVectorSample> vectors;
  final double rmsArcsec;
  final String? suggestionCode;

  const AstrometricResidualMap({
    required this.vectors,
    required this.rmsArcsec,
    this.suggestionCode,
  });
}
