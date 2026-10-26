part of '../science_models.dart';

class TransparencyOptions {
  /// Calibrations of the current frame's filter needed before a sample.
  final int minimumSampleCount;

  /// Airmass range the filter's calibrations must cover before an
  /// extinction coefficient is fitted and reported.
  final double minAirmassSpan;

  /// Range of fitted extinction (mag/airmass) accepted as atmospheric
  /// extinction. A slope outside it means the sky changed during the night.
  final double minPlausibleExtinction;
  final double maxPlausibleExtinction;

  const TransparencyOptions({
    this.minimumSampleCount = 4,
    this.minAirmassSpan = 0.3,
    this.minPlausibleExtinction = 0.02,
    this.maxPlausibleExtinction = 0.8,
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

  /// True only when [extinctionCoefficient] is a measured extinction: a
  /// zero point against airmass fit for one filter over enough airmass range,
  /// with a plausible slope. Otherwise [extinctionCoefficient] is 0 and must
  /// not be shown or stamped as an extinction.
  final bool extinctionFromAirmassFit;

  /// The filter whose zero points this sample compares.
  final String? filter;

  /// Plain sentence on how the sample was made, for the stage note and UI:
  /// whether extinction was measured and, if not, why.
  final String? note;

  const TransparencySample({
    required this.capturedImageId,
    required this.sessionId,
    required this.timestamp,
    required this.transparencyPercent,
    required this.extinctionCoefficient,
    required this.qualityBucket,
    required this.confidence,
    this.extinctionFromAirmassFit = false,
    this.filter,
    this.note,
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
