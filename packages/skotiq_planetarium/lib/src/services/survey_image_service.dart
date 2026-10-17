/// Survey image sources
enum SurveySource {
  dss2Red('DSS2 Red', 'POSS2/UKSTU Red'),
  dss2Blue('DSS2 Blue', 'POSS2/UKSTU Blue'),
  dss2Ir('DSS2 IR', 'POSS2/UKSTU IR'),
  twomassJ('2MASS J', '2MASS J'),
  twomassH('2MASS H', '2MASS H'),
  twomassK('2MASS K', '2MASS K'),
  sdss('SDSS', 'SDSS DR12'),
  wise('WISE', 'WISE 12'),
  galex('GALEX', 'GALEX Near UV');

  final String displayName;
  final String surveyId;

  const SurveySource(this.displayName, this.surveyId);
}

/// Survey image request configuration
class SurveyImageRequest {
  /// Right Ascension in degrees
  final double raDeg;

  /// Declination in degrees
  final double decDeg;

  /// Field of view width in degrees
  final double fovWidth;

  /// Field of view height in degrees
  final double fovHeight;

  /// Image pixel width
  final int pixelWidth;

  /// Image pixel height
  final int pixelHeight;

  /// Survey source
  final SurveySource source;

  const SurveyImageRequest({
    required this.raDeg,
    required this.decDeg,
    required this.fovWidth,
    required this.fovHeight,
    this.pixelWidth = 1000,
    this.pixelHeight = 1000,
    this.source = SurveySource.dss2Red,
  });

  /// Generate SkyView API URL
  String get skyViewUrl {
    // STScI SkyView API
    const baseUrl = 'https://skyview.gsfc.nasa.gov/current/cgi/runquery.pl';
    final params = {
      'Position': '$raDeg,$decDeg',
      'Survey': source.surveyId,
      'Pixels': '$pixelWidth,$pixelHeight',
      'Size': '${fovWidth.toStringAsFixed(4)},${fovHeight.toStringAsFixed(4)}',
      'Return': 'FITS,JPEG',
      'Projection': 'Tan',
      'Coordinates': 'J2000',
      'Sampler': 'LI',
    };

    final queryString = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return '$baseUrl?$queryString';
  }

  /// Generate Aladin Lite HiPS URL (alternative)
  String get aladinUrl {
    // CDS Aladin HiPS
    const baseUrl =
        'https://alasky.cds.unistra.fr/hips-image-services/hips2fits';
    final params = {
      'ra': raDeg.toStringAsFixed(6),
      'dec': decDeg.toStringAsFixed(6),
      'fov': fovWidth.toStringAsFixed(6),
      'width': pixelWidth.toString(),
      'height': pixelHeight.toString(),
      'format': 'jpg',
      'hips': _getHipsId(source),
    };

    final queryString = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return '$baseUrl?$queryString';
  }

  static String _getHipsId(SurveySource source) {
    switch (source) {
      case SurveySource.dss2Red:
        return 'CDS/P/DSS2/red';
      case SurveySource.dss2Blue:
        return 'CDS/P/DSS2/blue';
      case SurveySource.dss2Ir:
        return 'CDS/P/DSS2/NIR';
      case SurveySource.twomassJ:
        return 'CDS/P/2MASS/J';
      case SurveySource.twomassH:
        return 'CDS/P/2MASS/H';
      case SurveySource.twomassK:
        return 'CDS/P/2MASS/K';
      case SurveySource.sdss:
        return 'CDS/P/SDSS9/color';
      case SurveySource.wise:
        return 'CDS/P/WISE/W3';
      case SurveySource.galex:
        return 'CDS/P/GALEX/FUV';
    }
  }
}

/// FOV Calculator for equipment
class FOVCalculator {
  /// Calculate field of view for a given camera and telescope
  ///
  /// [sensorWidthMm] - Camera sensor width in mm
  /// [sensorHeightMm] - Camera sensor height in mm
  /// [focalLengthMm] - Telescope focal length in mm
  ///
  /// Returns (fovWidthDeg, fovHeightDeg)
  static (double, double) calculateFOV({
    required double sensorWidthMm,
    required double sensorHeightMm,
    required double focalLengthMm,
  }) {
    // FOV = 2 * atan(sensor_size / (2 * focal_length))
    final fovWidthRad = 2 * _atan(sensorWidthMm / (2 * focalLengthMm));
    final fovHeightRad = 2 * _atan(sensorHeightMm / (2 * focalLengthMm));

    // Convert to degrees
    final fovWidthDeg = fovWidthRad * 180 / 3.14159265359;
    final fovHeightDeg = fovHeightRad * 180 / 3.14159265359;

    return (fovWidthDeg, fovHeightDeg);
  }

  /// Calculate image scale (arcseconds per pixel)
  ///
  /// [pixelSizeMicrons] - Camera pixel size in microns
  /// [focalLengthMm] - Telescope focal length in mm
  ///
  /// Returns arcseconds per pixel
  static double calculateImageScale({
    required double pixelSizeMicrons,
    required double focalLengthMm,
  }) {
    // Scale = (pixel_size_mm / focal_length_mm) * 206265
    // 206265 arcseconds per radian
    final pixelSizeMm = pixelSizeMicrons / 1000;
    return (pixelSizeMm / focalLengthMm) * 206265;
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

  static double _atan(double x) {
    // Simple atan implementation
    if (x.abs() < 1) {
      return _atanSmall(x);
    } else {
      // atan(x) = pi/2 - atan(1/x) for |x| > 1
      final sign = x.sign;
      return sign * (3.14159265359 / 2 - _atanSmall(1 / x.abs()));
    }
  }

  static double _atanSmall(double x) {
    // Taylor series for |x| < 1
    final x2 = x * x;
    return x *
        (1 -
            x2 *
                (1 / 3 - x2 * (1 / 5 - x2 * (1 / 7 - x2 * (1 / 9 - x2 / 11)))));
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
