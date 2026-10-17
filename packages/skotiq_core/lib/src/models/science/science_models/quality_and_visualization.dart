part of '../science_models.dart';

/// Catalog a photometric calibration was fitted against. `auto` is a
/// request value only — the backend resolves it to the concrete catalog it
/// actually matched (today always [localHyg], the bundled HYG star catalog)
/// before persisting, so MAGZPSRC and the calibration rows record real
/// provenance.
enum PhotometricCatalogSource { auto, localHyg, localGaia, localApass }

enum ScienceFeature {
  photometry,
  photometricCalibration,
  transparency,
  psfMap,
  astrometricResiduals,
  movingObjects,
  narrowbandRatios,
  frameQualityMaps,
  surface3d,
}

enum ScienceLayerType {
  fwhm,
  hfr,
  eccentricity,
  uniformity,
  clipLow,
  clipHigh,
  background,
  snr,
  residualMag;

  String get dbValue {
    switch (this) {
      case ScienceLayerType.fwhm:
        return 'fwhm';
      case ScienceLayerType.hfr:
        return 'hfr';
      case ScienceLayerType.eccentricity:
        return 'eccentricity';
      case ScienceLayerType.uniformity:
        return 'uniformity';
      case ScienceLayerType.clipLow:
        return 'clip_low';
      case ScienceLayerType.clipHigh:
        return 'clip_high';
      case ScienceLayerType.background:
        return 'background';
      case ScienceLayerType.snr:
        return 'snr';
      case ScienceLayerType.residualMag:
        return 'residual_mag';
    }
  }

  static ScienceLayerType fromDbValue(String value) {
    switch (value) {
      case 'fwhm':
        return ScienceLayerType.fwhm;
      case 'hfr':
        return ScienceLayerType.hfr;
      case 'eccentricity':
        return ScienceLayerType.eccentricity;
      case 'uniformity':
        return ScienceLayerType.uniformity;
      case 'clip_low':
        return ScienceLayerType.clipLow;
      case 'clip_high':
        return ScienceLayerType.clipHigh;
      case 'background':
        return ScienceLayerType.background;
      case 'snr':
        return ScienceLayerType.snr;
      case 'residual_mag':
        return ScienceLayerType.residualMag;
      default:
        return ScienceLayerType.uniformity;
    }
  }
}

class ScienceFrameQualityMetrics {
  final int? capturedImageId;
  final int? sessionId;
  final DateTime timestamp;
  final double median;
  final double mean;
  final double stdDev;
  final double mad;
  final double background;
  final double noise;
  final double snr;
  final double dynamicRangeP1P99;
  final double lowClipPercent;
  final double highClipPercent;
  final double uniformityCv;
  final double gradientX;
  final double gradientY;
  final String processingTier;
  final int processingMs;

  const ScienceFrameQualityMetrics({
    required this.capturedImageId,
    required this.sessionId,
    required this.timestamp,
    required this.median,
    required this.mean,
    required this.stdDev,
    required this.mad,
    required this.background,
    required this.noise,
    required this.snr,
    required this.dynamicRangeP1P99,
    required this.lowClipPercent,
    required this.highClipPercent,
    required this.uniformityCv,
    required this.gradientX,
    required this.gradientY,
    required this.processingTier,
    required this.processingMs,
  });

  ScienceFrameQualityMetrics copyWith({
    int? capturedImageId,
    int? sessionId,
    DateTime? timestamp,
    double? median,
    double? mean,
    double? stdDev,
    double? mad,
    double? background,
    double? noise,
    double? snr,
    double? dynamicRangeP1P99,
    double? lowClipPercent,
    double? highClipPercent,
    double? uniformityCv,
    double? gradientX,
    double? gradientY,
    String? processingTier,
    int? processingMs,
  }) {
    return ScienceFrameQualityMetrics(
      capturedImageId: capturedImageId ?? this.capturedImageId,
      sessionId: sessionId ?? this.sessionId,
      timestamp: timestamp ?? this.timestamp,
      median: median ?? this.median,
      mean: mean ?? this.mean,
      stdDev: stdDev ?? this.stdDev,
      mad: mad ?? this.mad,
      background: background ?? this.background,
      noise: noise ?? this.noise,
      snr: snr ?? this.snr,
      dynamicRangeP1P99: dynamicRangeP1P99 ?? this.dynamicRangeP1P99,
      lowClipPercent: lowClipPercent ?? this.lowClipPercent,
      highClipPercent: highClipPercent ?? this.highClipPercent,
      uniformityCv: uniformityCv ?? this.uniformityCv,
      gradientX: gradientX ?? this.gradientX,
      gradientY: gradientY ?? this.gradientY,
      processingTier: processingTier ?? this.processingTier,
      processingMs: processingMs ?? this.processingMs,
    );
  }
}

class ScienceTileMetric {
  final int? capturedImageId;
  final int? sessionId;
  final DateTime timestamp;
  final ScienceLayerType layerType;
  final int tileRow;
  final int tileCol;
  final int sampleCount;
  final double value;
  final double p05;
  final double p50;
  final double p95;
  final double auxValue;

  const ScienceTileMetric({
    required this.capturedImageId,
    required this.sessionId,
    required this.timestamp,
    required this.layerType,
    required this.tileRow,
    required this.tileCol,
    required this.sampleCount,
    required this.value,
    required this.p05,
    required this.p50,
    required this.p95,
    required this.auxValue,
  });
}

class ScienceVisualizationPrefs {
  final double overlayOpacity;
  final int liveGridRows;
  final int liveGridCols;
  final int analysisGridRows;
  final int analysisGridCols;

  const ScienceVisualizationPrefs({
    this.overlayOpacity = 0.35,
    this.liveGridRows = 12,
    this.liveGridCols = 16,
    this.analysisGridRows = 24,
    this.analysisGridCols = 32,
  });

  ScienceVisualizationPrefs copyWith({
    double? overlayOpacity,
    int? liveGridRows,
    int? liveGridCols,
    int? analysisGridRows,
    int? analysisGridCols,
  }) {
    return ScienceVisualizationPrefs(
      overlayOpacity: overlayOpacity ?? this.overlayOpacity,
      liveGridRows: liveGridRows ?? this.liveGridRows,
      liveGridCols: liveGridCols ?? this.liveGridCols,
      analysisGridRows: analysisGridRows ?? this.analysisGridRows,
      analysisGridCols: analysisGridCols ?? this.analysisGridCols,
    );
  }
}
