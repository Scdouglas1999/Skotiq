part of '../science_models.dart';

class SolverCapabilities {
  final bool hasResidualVectors;
  final bool hasDistortionTerms;
  final bool supportsBatchSolve;
  final bool supportsLocalIndexOnly;

  const SolverCapabilities({
    this.hasResidualVectors = false,
    this.hasDistortionTerms = false,
    this.supportsBatchSolve = false,
    this.supportsLocalIndexOnly = true,
  });
}

class SolveOptions {
  final double? raHintHours;
  final double? decHintDegrees;
  final double? searchRadiusDegrees;

  const SolveOptions({
    this.raHintHours,
    this.decHintDegrees,
    this.searchRadiusDegrees,
  });
}

class WcsSolution {
  final double raHours;
  final double decDegrees;
  final double pixelScaleArcsecPerPixel;
  final double rotationDegrees;
  final double fieldWidthDegrees;
  final double fieldHeightDegrees;
  final String solverId;
  final double? cd1_1;
  final double? cd1_2;
  final double? cd2_1;
  final double? cd2_2;
  final int aOrder;
  final int bOrder;
  final List<double> aCoeffs;
  final List<double> bCoeffs;
  final int apOrder;
  final int bpOrder;
  final List<double> apCoeffs;
  final List<double> bpCoeffs;

  const WcsSolution({
    required this.raHours,
    required this.decDegrees,
    required this.pixelScaleArcsecPerPixel,
    required this.rotationDegrees,
    required this.fieldWidthDegrees,
    required this.fieldHeightDegrees,
    required this.solverId,
    this.cd1_1,
    this.cd1_2,
    this.cd2_1,
    this.cd2_2,
    this.aOrder = 0,
    this.bOrder = 0,
    this.aCoeffs = const [],
    this.bCoeffs = const [],
    this.apOrder = 0,
    this.bpOrder = 0,
    this.apCoeffs = const [],
    this.bpCoeffs = const [],
  });
}

class PhotometryOptions {
  final int apertureRadiusPixels;
  final int annulusInnerRadiusPixels;
  final int annulusOuterRadiusPixels;
  final double minSnr;

  const PhotometryOptions({
    this.apertureRadiusPixels = 6,
    this.annulusInnerRadiusPixels = 8,
    this.annulusOuterRadiusPixels = 12,
    this.minSnr = 4.0,
  });
}

class StarMeasurement {
  final double x;
  final double y;
  final double flux;
  final double hfr;
  final double fwhm;
  final double snr;
  final double eccentricity;
  final double sharpness;
  final double background;
  final double peak;

  const StarMeasurement({
    required this.x,
    required this.y,
    required this.flux,
    required this.hfr,
    required this.fwhm,
    required this.snr,
    required this.eccentricity,
    required this.sharpness,
    required this.background,
    required this.peak,
  });
}

class FramePhotometricCalibration {
  final int? capturedImageId;
  final int? sessionId;
  final DateTime timestamp;
  final double? airmass;
  final double exposureSeconds;
  final bool isCalibrated;
  final double? zeroPoint;
  final double? limitingMag3Sigma;
  final double? limitingMag5Sigma;
  final int matchedStarCount;
  final double calibrationRms;
  final String solverId;
  final PhotometricCatalogSource catalogSource;

  const FramePhotometricCalibration({
    required this.capturedImageId,
    required this.sessionId,
    required this.timestamp,
    this.airmass,
    this.exposureSeconds = 1.0,
    required this.isCalibrated,
    this.zeroPoint,
    this.limitingMag3Sigma,
    this.limitingMag5Sigma,
    this.matchedStarCount = 0,
    this.calibrationRms = 0.0,
    required this.solverId,
    this.catalogSource = PhotometricCatalogSource.auto,
  });
}
