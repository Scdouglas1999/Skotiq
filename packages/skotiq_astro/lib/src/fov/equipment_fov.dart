import 'dart:math' as math;

/// Field of view and image scale of a sensor behind an optic.
class FOVCalculator {
  /// Field of view in degrees, (width, height), from sensor dimensions and
  /// focal length in millimeters: `2 * atan(sensor / (2 * focalLength))`.
  static (double, double) calculateFOV({
    required double sensorWidthMm,
    required double sensorHeightMm,
    required double focalLengthMm,
  }) {
    double degrees(double sensorMm) =>
        2 * math.atan(sensorMm / (2 * focalLengthMm)) * 180 / math.pi;
    return (degrees(sensorWidthMm), degrees(sensorHeightMm));
  }

  /// Image scale in arcseconds per pixel, from a pixel size in microns and a
  /// focal length in millimeters (small-angle: 206.265 arcseconds per
  /// micron-per-millimeter).
  static double calculateImageScale({
    required double pixelSizeMicrons,
    required double focalLengthMm,
  }) => 206.265 * pixelSizeMicrons / focalLengthMm;

  /// [calculateImageScale], or null when either input is missing or not
  /// positive: a scale is never invented from one known dimension.
  static double? imageScaleOrNull({
    double? pixelSizeMicrons,
    double? focalLengthMm,
  }) {
    if (pixelSizeMicrons == null ||
        pixelSizeMicrons <= 0 ||
        focalLengthMm == null ||
        focalLengthMm <= 0) {
      return null;
    }
    return calculateImageScale(
      pixelSizeMicrons: pixelSizeMicrons,
      focalLengthMm: focalLengthMm,
    );
  }

  /// Calculate effective focal length with reducer/barlow
  ///
  /// [focalLengthMm] - Base telescope focal length
  /// [multiplier] - Reducer (<1) or Barlow (>1) multiplier
  static double effectiveFocalLength({
    required double focalLengthMm,
    required double multiplier,
  }) {
    return focalLengthMm * multiplier;
  }

  /// Calculate focal ratio
  ///
  /// [focalLengthMm] - Focal length in mm
  /// [apertureMm] - Aperture diameter in mm
  static double focalRatio({
    required double focalLengthMm,
    required double apertureMm,
  }) {
    return focalLengthMm / apertureMm;
  }

  /// Check if equipment is well-matched (image scale between 1-3 arcsec/pixel for most DSO imaging)
  static String evaluateSampling({
    required double pixelSizeMicrons,
    required double focalLengthMm,
    required double typicalSeeingArcsec,
  }) {
    final imageScale = calculateImageScale(
      pixelSizeMicrons: pixelSizeMicrons,
      focalLengthMm: focalLengthMm,
    );

    // Nyquist sampling: optimal is ~2-3 pixels per FWHM
    final samplingRatio = typicalSeeingArcsec / imageScale;

    if (samplingRatio < 1.5) {
      return 'Undersampled: Consider longer focal length or smaller pixels';
    } else if (samplingRatio > 4) {
      return 'Oversampled: Consider shorter focal length or binning';
    } else if (samplingRatio < 2) {
      return 'Slightly undersampled but acceptable';
    } else if (samplingRatio > 3) {
      return 'Slightly oversampled but acceptable';
    } else {
      return 'Well-sampled for typical conditions';
    }
  }
}

/// Common camera sensor specifications
class CameraSensorSpecs {
  final String name;
  final double widthMm;
  final double heightMm;
  final int pixelsX;
  final int pixelsY;
  final double pixelSizeMicrons;

  const CameraSensorSpecs({
    required this.name,
    required this.widthMm,
    required this.heightMm,
    required this.pixelsX,
    required this.pixelsY,
    required this.pixelSizeMicrons,
  });

  /// Full Frame (36x24mm)
  static const fullFrame = CameraSensorSpecs(
    name: 'Full Frame',
    widthMm: 36.0,
    heightMm: 24.0,
    pixelsX: 6000,
    pixelsY: 4000,
    pixelSizeMicrons: 6.0,
  );

  /// APS-C (23.5x15.6mm)
  static const apsC = CameraSensorSpecs(
    name: 'APS-C',
    widthMm: 23.5,
    heightMm: 15.6,
    pixelsX: 6000,
    pixelsY: 4000,
    pixelSizeMicrons: 3.9,
  );

  /// Micro Four Thirds (17.3x13mm)
  static const microFourThirds = CameraSensorSpecs(
    name: 'Micro Four Thirds',
    widthMm: 17.3,
    heightMm: 13.0,
    pixelsX: 5184,
    pixelsY: 3888,
    pixelSizeMicrons: 3.3,
  );

  /// ZWO ASI2600MM Pro
  static const asi2600mm = CameraSensorSpecs(
    name: 'ZWO ASI2600MM Pro',
    widthMm: 28.3,
    heightMm: 18.9,
    pixelsX: 6248,
    pixelsY: 4176,
    pixelSizeMicrons: 3.76,
  );

  /// ZWO ASI294MC Pro
  static const asi294mc = CameraSensorSpecs(
    name: 'ZWO ASI294MC Pro',
    widthMm: 23.2,
    heightMm: 15.5,
    pixelsX: 4144,
    pixelsY: 2822,
    pixelSizeMicrons: 4.63,
  );

  /// ZWO ASI533MC Pro
  static const asi533mc = CameraSensorSpecs(
    name: 'ZWO ASI533MC Pro',
    widthMm: 11.31,
    heightMm: 11.31,
    pixelsX: 3008,
    pixelsY: 3008,
    pixelSizeMicrons: 3.76,
  );

  /// ZWO ASI183MM Pro
  static const asi183mm = CameraSensorSpecs(
    name: 'ZWO ASI183MM Pro',
    widthMm: 13.2,
    heightMm: 8.8,
    pixelsX: 5496,
    pixelsY: 3672,
    pixelSizeMicrons: 2.4,
  );

  static List<CameraSensorSpecs> get commonCameras => [
    fullFrame,
    apsC,
    microFourThirds,
    asi2600mm,
    asi294mc,
    asi533mc,
    asi183mm,
  ];
}

/// Common telescope specifications
class TelescopeSpecs {
  final String name;
  final double focalLengthMm;
  final double apertureMm;

  const TelescopeSpecs({
    required this.name,
    required this.focalLengthMm,
    required this.apertureMm,
  });

  double get focalRatio => focalLengthMm / apertureMm;

  // Common refractors
  static const ed80 = TelescopeSpecs(
    name: 'ED80',
    focalLengthMm: 480,
    apertureMm: 80,
  );
  static const ed102 = TelescopeSpecs(
    name: 'ED102',
    focalLengthMm: 714,
    apertureMm: 102,
  );
  static const fsq106 = TelescopeSpecs(
    name: 'FSQ-106',
    focalLengthMm: 530,
    apertureMm: 106,
  );
  static const toa130 = TelescopeSpecs(
    name: 'TOA-130',
    focalLengthMm: 1000,
    apertureMm: 130,
  );

  // Common reflectors
  static const newton8 = TelescopeSpecs(
    name: '8" f/4 Newt',
    focalLengthMm: 800,
    apertureMm: 203,
  );
  static const newton10 = TelescopeSpecs(
    name: '10" f/4 Newt',
    focalLengthMm: 1000,
    apertureMm: 254,
  );
  static const rc8 = TelescopeSpecs(
    name: 'RC8',
    focalLengthMm: 1624,
    apertureMm: 203,
  );
  static const rc10 = TelescopeSpecs(
    name: 'RC10',
    focalLengthMm: 2000,
    apertureMm: 254,
  );

  // Common SCTs
  static const sct8 = TelescopeSpecs(
    name: '8" SCT',
    focalLengthMm: 2032,
    apertureMm: 203,
  );
  static const sct11 = TelescopeSpecs(
    name: '11" SCT',
    focalLengthMm: 2800,
    apertureMm: 280,
  );
  static const sct14 = TelescopeSpecs(
    name: '14" SCT',
    focalLengthMm: 3910,
    apertureMm: 356,
  );

  // RASA
  static const rasa8 = TelescopeSpecs(
    name: 'RASA 8',
    focalLengthMm: 400,
    apertureMm: 203,
  );
  static const rasa11 = TelescopeSpecs(
    name: 'RASA 11',
    focalLengthMm: 620,
    apertureMm: 280,
  );

  static List<TelescopeSpecs> get commonTelescopes => [
    ed80,
    ed102,
    fsq106,
    toa130,
    newton8,
    newton10,
    rc8,
    rc10,
    sct8,
    sct11,
    sct14,
    rasa8,
    rasa11,
  ];
}
