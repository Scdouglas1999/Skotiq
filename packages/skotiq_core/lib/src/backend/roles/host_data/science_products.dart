import '../../../database/database.dart'
    show
        AstrometryResidualVectorRow,
        FramePhotometricCalibrationRow,
        LineRatioProductRow,
        MovingObjectCandidateRow,
        PhotometryMeasurementRow,
        PsfFieldTileRow,
        ScienceFrameQualityMetricsRow,
        ScienceTileMetricRow,
        TransparencySampleRow;
import '../../../models/science/science_models.dart' show ScienceSessionConfig;

/// The per-frame science measurements kept in the imaging host's database:
/// photometry, photometric calibrations, transparency, PSF tiles, frame and
/// tile quality, astrometric residuals, moving-object candidates and line
/// ratios, for one session or for captures taken outside any session.
///
/// The "recent" reads are preview windows. A linked host serves only that
/// window, so there the `getAllSessionless…` reads return the same rows;
/// locally they return every row.
abstract interface class ScienceProducts {
  Stream<ScienceSessionConfig?> watchSessionScienceConfig(int sessionId);

  /// Saves the science switches of the session named by `config.sessionId`.
  Future<void> upsertSessionConfig(ScienceSessionConfig config);

  Stream<List<PhotometryMeasurementRow>> watchPhotometryForSession(
    int sessionId,
  );

  /// One object's photometry across every session of a target. A linked host
  /// has no such read and yields an empty list.
  Stream<List<PhotometryMeasurementRow>> watchPhotometryForTarget({
    required int targetId,
    required String objectId,
  });

  Stream<List<FramePhotometricCalibrationRow>> watchCalibrationsForSession(
    int sessionId,
  );

  Stream<List<TransparencySampleRow>> watchTransparencyForSession(
    int sessionId,
  );

  Stream<List<PsfFieldTileRow>> watchPsfTilesForSession(int sessionId);

  Stream<List<ScienceFrameQualityMetricsRow>>
  watchFrameQualityMetricsForSession(int sessionId);

  /// The tile metrics of one frame of a session, chosen by
  /// `selectFrameScienceRows`: [capturedImageId]'s, else the frame measured
  /// last. Every view shows one frame, and a session holds thousands of tile
  /// rows per frame.
  Stream<List<ScienceTileMetricRow>> watchFrameTileMetrics(
    int sessionId, {
    int? capturedImageId,
  });

  Stream<List<AstrometryResidualVectorRow>> watchResidualsForSession(
    int sessionId,
  );

  Stream<List<MovingObjectCandidateRow>> watchMovingObjectsForSession(
    int sessionId,
  );

  Stream<List<LineRatioProductRow>> watchLineRatiosForSession(int sessionId);

  Stream<List<FramePhotometricCalibrationRow>>
  watchSessionlessCalibrationsRecent();

  Stream<List<TransparencySampleRow>> watchSessionlessTransparencyRecent();

  Stream<List<PsfFieldTileRow>> watchSessionlessPsfTilesRecent();

  Stream<List<ScienceFrameQualityMetricsRow>>
  watchSessionlessFrameQualityMetricsRecent();

  Stream<List<ScienceTileMetricRow>> watchSessionlessTileMetricsRecent();

  Stream<List<AstrometryResidualVectorRow>> watchSessionlessResidualsRecent();

  Stream<List<MovingObjectCandidateRow>> watchSessionlessMovingObjectsRecent();

  Stream<List<PhotometryMeasurementRow>> watchSessionlessPhotometryRecent();

  Stream<List<LineRatioProductRow>> watchSessionlessLineRatiosRecent();

  Future<List<PhotometryMeasurementRow>> getAllSessionlessPhotometry();

  Future<List<ScienceFrameQualityMetricsRow>>
  getAllSessionlessFrameQualityMetrics();

  Future<List<TransparencySampleRow>> getAllSessionlessTransparency();

  Future<List<PsfFieldTileRow>> getAllSessionlessPsfTiles();

  Future<List<AstrometryResidualVectorRow>> getAllSessionlessResiduals();

  Future<List<FramePhotometricCalibrationRow>> getAllSessionlessCalibrations();

  Future<List<MovingObjectCandidateRow>> getAllSessionlessMovingObjects();
}

/// A set of key/value setting rows on the imaging host, read and written as a
/// whole map.
///
/// Locally this is the settings table. On a linked host each feature that has
/// its own settings endpoint (science) is one of these over that endpoint,
/// and returns only that feature's keys.
abstract interface class SettingRows {
  Future<Map<String, String>> getAllSettings();

  Future<void> setSettings(Map<String, String> settings);
}
