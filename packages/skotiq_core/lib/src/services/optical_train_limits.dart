/// Physical plausibility bounds for an optical train.
///
/// Focal length is written to the FITS `FOCALLEN` card and drives plate-solve
/// field-of-view estimation and image-scale arcsec/px, so a value that is
/// merely positive is not enough: a fat-fingered `999999999` mm corrupts
/// astrometry and every derived measurement for that rig.
///
/// The bounds are far wider than any real amateur or semi-professional rig —
/// they catch typos, not unusual setups.
class OpticalTrainLimits {
  const OpticalTrainLimits._();

  /// Focal length, mm. A 12mm all-sky lens sits near the bottom; 50 m is an
  /// order of magnitude beyond the longest amateur configuration.
  static const double minFocalLengthMm = 1.0;
  static const double maxFocalLengthMm = 50000.0;

  /// Aperture, mm. 5 m exceeds any privately owned telescope.
  static const double minApertureMm = 1.0;
  static const double maxApertureMm = 5000.0;

  /// Sensor pixel pitch, microns. Real sensors run about 1-25 µm.
  static const double minPixelSizeMicrons = 0.1;
  static const double maxPixelSizeMicrons = 100.0;

  /// Focal reducer / barlow factor.
  static const double minReducerFactor = 0.1;
  static const double maxReducerFactor = 10.0;

  /// Focal ratio. Sub-f/1 optics exist (f/0.95 lenses), and long-focus solar
  /// refractors reach roughly f/30, so f/200 is a generous ceiling.
  static const double minFRatio = 0.5;
  static const double maxFRatio = 200.0;

  /// The first problem with these values, or null when they are plausible.
  ///
  /// Returns one message at a time so the UI can show the specific thing to fix
  /// rather than a wall of errors.
  static String? validate({
    required double? focalLengthMm,
    required double? apertureMm,
    required double? pixelSizeMicrons,
    required double reducerFactor,
  }) {
    if (focalLengthMm == null || focalLengthMm <= 0) {
      return 'Focal length is required.';
    }
    if (focalLengthMm < minFocalLengthMm || focalLengthMm > maxFocalLengthMm) {
      return 'Focal length must be between '
          '${_mm(minFocalLengthMm)} and ${_mm(maxFocalLengthMm)} mm.';
    }
    if (apertureMm == null || apertureMm <= 0) {
      return 'Aperture is required.';
    }
    if (apertureMm < minApertureMm || apertureMm > maxApertureMm) {
      return 'Aperture must be between '
          '${_mm(minApertureMm)} and ${_mm(maxApertureMm)} mm.';
    }
    if (pixelSizeMicrons == null || pixelSizeMicrons <= 0) {
      return 'Pixel size is required.';
    }
    if (pixelSizeMicrons < minPixelSizeMicrons ||
        pixelSizeMicrons > maxPixelSizeMicrons) {
      return 'Pixel size must be between $minPixelSizeMicrons and '
          '${_mm(maxPixelSizeMicrons)} microns.';
    }
    if (reducerFactor <= 0) {
      return 'Reducer factor must be greater than zero.';
    }
    if (reducerFactor < minReducerFactor || reducerFactor > maxReducerFactor) {
      return 'Reducer factor must be between $minReducerFactor and '
          '${_mm(maxReducerFactor)}.';
    }
    // Checked last: individually plausible numbers can still describe an
    // impossible system, which is the shape the live defect took.
    final fRatio = focalLengthMm / apertureMm;
    if (fRatio < minFRatio || fRatio > maxFRatio) {
      return 'Focal length ${_mm(focalLengthMm)} mm with aperture '
          '${_mm(apertureMm)} mm gives f/${fRatio.toStringAsFixed(1)}. '
          'Check both values.';
    }
    return null;
  }

  /// Trim a trailing `.0` so bounds read as `50000` rather than `50000.0`.
  static String _mm(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
}
