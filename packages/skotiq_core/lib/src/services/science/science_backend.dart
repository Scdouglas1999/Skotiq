import '../../models/science/science_models.dart';

abstract class ScienceBackend {
  Future<SolverCapabilities> getSolverCapabilities();

  Future<WcsSolution?> solveForScience(String imagePath, SolveOptions options);

  Future<List<StarMeasurement>> measureStars(
    String imagePath,
    PhotometryOptions options,
  );

  Future<FramePhotometricCalibration?> calibrateFramePhotometry(
    String imagePath,
    WcsSolution wcs,
    PhotometricCatalogSource catalog,
    ScienceFrameContext? frameContext,
  );

  Future<TransparencySample?> estimateTransparency(
    List<FramePhotometricCalibration> recentCalibrations,
    TransparencyOptions options,
  );

  Future<PsfFieldMap> buildPsfFieldMap(
    String imagePath,
    WcsSolution? wcs,
    PsfMapOptions options,
  );

  Future<AstrometricResidualMap?> computeAstrometricResiduals(
    String imagePath,
    WcsSolution wcs,
    AstrometryOptions options,
  );

  Future<List<MovingObjectMatch>> detectMovingObjects(
    List<String> imagePaths,
    WcsSolution wcs,
    MovingObjectOptions options,
  );

  Future<(ScienceFrameQualityMetrics, List<ScienceTileMetric>)>
  computeLastCaptureQualityMaps({
    required String deviceId,
    required int gridRows,
    required int gridCols,
    required int lowClipAdu,
    required int highClipAdu,
    required DateTime timestamp,
    int? capturedImageId,
    int? sessionId,
  });

  Future<(ScienceFrameQualityMetrics, List<ScienceTileMetric>)>
  computeFitsQualityMaps({
    required String filePath,
    required int gridRows,
    required int gridCols,
    required int lowClipAdu,
    required int highClipAdu,
    required DateTime timestamp,
    int? capturedImageId,
    int? sessionId,
  });

  Future<LineRatioProduct> computeLineRatios(
    NarrowbandSet set,
    LineRatioOptions options,
  );
}
