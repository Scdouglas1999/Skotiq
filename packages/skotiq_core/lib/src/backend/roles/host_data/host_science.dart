import 'dart:typed_data';

import '../../../database/database.dart';
import '../../../models/science/science_models.dart';
import '../../../services/science/period_analysis_service.dart'
    show PeriodFinding;

/// Science products a linked imaging host derives from its frames:
/// photometry, transforms, reports and their settings.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostScience {
  Future<PhotometricTransformCoefficients?> computePhotometricTransform({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
  });

  Future<Uint8List> exportSessionAavso(
    int sessionId, {
    required String targetStarName,
    String? filterBand,
    String? chartId,
  });

  Future<Uint8List> generateObservationReport(int sessionId);

  /// The Science tab's report of [sessionId] as Markdown, with [period], the
  /// search this client ran on screen.
  Future<String> scienceReport(int sessionId, {PeriodFinding? period});

  /// The session the host's Science tab opens on (`scienceDefaultSessionId`),
  /// or null when no session has light frames.
  Future<int?> scienceDefaultSession();

  Future<Map<String, dynamic>> generateSessionLineRatios(int sessionId);

  Future<({int width, int height})?> getFitsDimensions(String hostPath);

  Future<List<PsfFieldTileRow>> getSessionPsfTiles(int sessionId);

  Future<RemoteScienceBundle> getSessionlessScienceBundle();

  Future<int> savePhotometricTransform(
    PhotometricTransformCoefficients coefficients,
  );
}

/// Every science table the host holds for one session (or for none), read
/// in one request.
class RemoteScienceBundle {
  final List<PhotometryMeasurementRow> photometry;
  final List<FramePhotometricCalibrationRow> calibrations;
  final List<TransparencySampleRow> transparency;
  final List<PsfFieldTileRow> psfTiles;
  final List<ScienceFrameQualityMetricsRow> frameQuality;
  final List<ScienceTileMetricRow> tileMetrics;
  final List<AstrometryResidualVectorRow> residuals;
  final List<MovingObjectCandidateRow> movingObjects;
  final List<LineRatioProductRow> lineRatios;

  const RemoteScienceBundle({
    required this.photometry,
    required this.calibrations,
    required this.transparency,
    required this.psfTiles,
    required this.frameQuality,
    required this.tileMetrics,
    required this.residuals,
    required this.movingObjects,
    required this.lineRatios,
  });
}
