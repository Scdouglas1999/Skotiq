// The seven science export dataset descriptors.
part of '../science_export_hub.dart';

/// A science dataset's CSV projection: its published header, where its rows
/// come from (standalone and per session), and how one row becomes one line.
///
/// Header and row builder live together so they cannot drift.
class _ExportDataset<T> {
  const _ExportDataset({
    required this.header,
    required this.standaloneExport,
    required this.perSession,
    required this.timestampOf,
    required this.toCsvRow,
  });

  /// Column names, in output order. These are a published file format — other
  /// people's pipelines parse them — so they are pinned by a parity test.
  final List<String> header;
  final ProviderListenable<Future<List<T>>> standaloneExport;
  final ProviderListenable<Future<List<T>>> Function(int sessionId) perSession;
  final DateTime Function(T row) timestampOf;
  final List<dynamic> Function(T row) toCsvRow;
}

final _photometryDataset = _ExportDataset<PhotometryMeasurementRow>(
  header: [
    'Session ID',
    'Image ID',
    'Object ID',
    'Role',
    'X',
    'Y',
    'Flux',
    'Differential Magnitude',
    'SNR',
    'Uncertainty',
    'Is Outlier',
    'Timestamp (UTC)',
    'JD',
  ],
  standaloneExport: sessionlessPhotometryExportProvider.future,
  perSession: (sessionId) => sessionPhotometryProvider(sessionId).future,
  timestampOf: (m) => m.timestamp,
  toCsvRow: (m) => [
    m.sessionId ?? '',
    m.capturedImageId ?? '',
    m.objectId,
    m.role,
    m.x,
    m.y,
    m.flux,
    m.differentialMagnitude ?? '',
    m.snr ?? '',
    m.uncertainty ?? '',
    m.isOutlier,
    _utcStamp(m.timestamp),
    _julianDate(m.timestamp),
  ],
);

final _frameQualityDataset = _ExportDataset<ScienceFrameQualityMetricsRow>(
  header: [
    'Session ID',
    'Image ID',
    'Timestamp (UTC)',
    'Median',
    'Mean',
    'StdDev',
    'MAD',
    'Background',
    'Noise',
    'SNR',
    'Dynamic Range (P1-P99)',
    'Low Clip %',
    'High Clip %',
    'Uniformity CV',
    'Gradient X',
    'Gradient Y',
    'Processing Tier',
    'Processing Ms',
  ],
  standaloneExport: sessionlessFrameQualityMetricsExportProvider.future,
  perSession: (sessionId) =>
      sessionFrameQualityMetricsProvider(sessionId).future,
  timestampOf: (m) => m.timestamp,
  toCsvRow: (m) => [
    m.sessionId ?? '',
    m.capturedImageId ?? '',
    _utcStamp(m.timestamp),
    m.median,
    m.mean,
    m.stdDev,
    m.mad,
    m.background,
    m.noise,
    m.snr,
    m.dynamicRangeP1P99,
    m.lowClipPercent,
    m.highClipPercent,
    m.uniformityCv,
    m.gradientX,
    m.gradientY,
    m.processingTier,
    m.processingMs,
  ],
);

final _transparencyDataset = _ExportDataset<TransparencySampleRow>(
  header: [
    'Session ID',
    'Image ID',
    'Transparency %',
    'Extinction Coefficient',
    'Quality Bucket',
    'Confidence',
    'Timestamp (UTC)',
  ],
  standaloneExport: sessionlessTransparencySamplesExportProvider.future,
  perSession: (sessionId) =>
      sessionTransparencySamplesProvider(sessionId).future,
  timestampOf: (s) => s.timestamp,
  toCsvRow: (s) => [
    s.sessionId ?? '',
    s.capturedImageId ?? '',
    s.transparencyPercent,
    s.extinctionCoefficient,
    s.qualityBucket,
    s.confidence,
    _utcStamp(s.timestamp),
  ],
);

final _psfTileDataset = _ExportDataset<PsfFieldTileRow>(
  header: [
    'Session ID',
    'Image ID',
    'Tile Row',
    'Tile Col',
    'Star Count',
    'Median FWHM',
    'Median HFR',
    'Median Eccentricity',
    'Roundness',
    'Timestamp (UTC)',
  ],
  standaloneExport: sessionlessPsfTilesExportProvider.future,
  perSession: (sessionId) => sessionPsfTilesProvider(sessionId).future,
  timestampOf: (t) => t.timestamp,
  toCsvRow: (t) => [
    t.sessionId ?? '',
    t.capturedImageId ?? '',
    t.tileRow,
    t.tileCol,
    t.starCount,
    t.medianFwhm,
    t.medianHfr,
    t.medianEccentricity,
    t.roundness,
    _utcStamp(t.timestamp),
  ],
);

final _residualDataset = _ExportDataset<AstrometryResidualVectorRow>(
  header: [
    'Session ID',
    'Image ID',
    'X',
    'Y',
    'dX (arcsec)',
    'dY (arcsec)',
    'Magnitude (arcsec)',
    'Recommendation',
    'Timestamp (UTC)',
  ],
  standaloneExport: sessionlessResidualVectorsExportProvider.future,
  perSession: (sessionId) => sessionResidualVectorsProvider(sessionId).future,
  timestampOf: (r) => r.timestamp,
  toCsvRow: (r) => [
    r.sessionId ?? '',
    r.capturedImageId ?? '',
    r.x,
    r.y,
    r.dxArcsec,
    r.dyArcsec,
    r.magnitudeArcsec,
    r.recommendationCode ?? '',
    _utcStamp(r.timestamp),
  ],
);

final _calibrationDataset = _ExportDataset<FramePhotometricCalibrationRow>(
  header: [
    'Session ID',
    'Image ID',
    'Is Calibrated',
    'Zero Point',
    'Lim Mag 3-sigma',
    'Lim Mag 5-sigma',
    'Matched Stars',
    'Calibration RMS',
    'Catalog Source',
    'Solver ID',
    'Timestamp (UTC)',
  ],
  standaloneExport: sessionlessCalibrationsExportProvider.future,
  perSession: (sessionId) => sessionFrameCalibrationsProvider(sessionId).future,
  timestampOf: (c) => c.timestamp,
  toCsvRow: (c) => [
    c.sessionId ?? '',
    c.capturedImageId ?? '',
    c.isCalibrated,
    c.zeroPoint ?? '',
    c.limitingMag3Sigma ?? '',
    c.limitingMag5Sigma ?? '',
    c.matchedStarCount,
    c.calibrationRms,
    c.catalogSource,
    c.solverId,
    _utcStamp(c.timestamp),
  ],
);

final _movingObjectDataset = _ExportDataset<MovingObjectCandidateRow>(
  header: [
    'Session ID',
    'Image ID',
    'Candidate ID',
    'RA (deg)',
    'Dec (deg)',
    'Motion (arcsec/min)',
    'Position Angle (deg)',
    'Confidence',
    'Is Known Object',
    'Object Name',
    'Source',
    'Timestamp (UTC)',
  ],
  standaloneExport: sessionlessMovingObjectCandidatesExportProvider.future,
  perSession: (sessionId) =>
      sessionMovingObjectCandidatesProvider(sessionId).future,
  timestampOf: (m) => m.timestamp,
  toCsvRow: (m) => [
    m.sessionId ?? '',
    m.capturedImageId ?? '',
    m.candidateId,
    m.raDegrees,
    m.decDegrees,
    m.motionArcsecPerMinute,
    m.positionAngleDegrees,
    m.confidence,
    m.isKnownObject,
    m.objectName ?? '',
    m.source,
    _utcStamp(m.timestamp),
  ],
);
