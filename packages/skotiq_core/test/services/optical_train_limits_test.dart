import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/optical_train_limits.dart';

/// Rejecting only `<= 0` accepts focal length `999999999` mm and aperture
/// `0.0001` mm, and the first-run wizard step renders `f/9999999990000.00`.
/// Focal length reaches the FITS `FOCALLEN` card and drives plate-solve
/// field-of-view and arcsec/px, so an implausible value silently corrupts
/// astrometry for that rig.
void main() {
  String? check({
    double? focalLengthMm = 600,
    double? apertureMm = 100,
    double? pixelSizeMicrons = 3.76,
    double reducerFactor = 1.0,
  }) => OpticalTrainLimits.validate(
    focalLengthMm: focalLengthMm,
    apertureMm: apertureMm,
    pixelSizeMicrons: pixelSizeMicrons,
    reducerFactor: reducerFactor,
  );

  test('the exact live values are rejected', () {
    final message = check(focalLengthMm: 999999999, apertureMm: 0.0001);
    expect(message, isNotNull);
    // Must name a number the user can act on, not just say "invalid".
    expect(message, contains('Focal length'));
  });

  test('an impossible f-ratio is caught even when each value is in range', () {
    // 40000mm at 2mm is f/20000 — both inside their own bounds.
    final message = check(focalLengthMm: 40000, apertureMm: 2);
    expect(message, contains('f/'));
  });

  group('real rigs still validate', () {
    const rigs = <(String, double, double, double)>[
      // (name, focal length mm, aperture mm, pixel size microns)
      ('Samyang 135mm f/2', 135, 67.5, 3.76),
      ('RedCat 51', 250, 51, 3.76),
      ('EdgeHD 8 with 0.7x', 1422, 203, 3.76),
      ('RASA 11 f/2.2', 620, 279, 3.76),
      ('Planetary C14 + 2x barlow', 7800, 356, 2.9),
      ('All-sky 12mm fisheye', 12, 8, 5.6),
      ('1m professional f/8', 8000, 1000, 9.0),
    ];
    for (final (name, fl, ap, px) in rigs) {
      test(name, () {
        expect(
          check(focalLengthMm: fl, apertureMm: ap, pixelSizeMicrons: px),
          isNull,
          reason: '$name is a real configuration and must be accepted',
        );
      });
    }
  });

  test('missing values still report as required, not out of range', () {
    expect(check(focalLengthMm: null), 'Focal length is required.');
    expect(check(apertureMm: null), 'Aperture is required.');
    expect(check(pixelSizeMicrons: null), 'Pixel size is required.');
  });

  test('zero and negative are still rejected', () {
    expect(check(focalLengthMm: 0), isNotNull);
    expect(check(apertureMm: -100), isNotNull);
    expect(check(reducerFactor: 0), isNotNull);
  });

  test('an absurd pixel size and reducer factor are rejected', () {
    expect(check(pixelSizeMicrons: 5000), contains('Pixel size'));
    expect(check(reducerFactor: 1000), contains('Reducer factor'));
  });

  test('bounds messages do not print a trailing .0', () {
    final message = check(focalLengthMm: 99999999);
    expect(message, contains('50000 mm'));
    expect(message, isNot(contains('50000.0')));
  });
}
