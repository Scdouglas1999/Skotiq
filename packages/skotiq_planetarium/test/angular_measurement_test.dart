import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// Tests for the angular-measurement primitives backing the planetarium ruler
/// tool: great-circle separation and North-through-East position angle.
///
/// Values are pinned against well-known reference pairs (Mizar/Alcor) and
/// pure-geometry cases (due-north, due-east, antipodal) so they hold
/// independent of epoch or observer.
void main() {
  // Mizar (ζ UMa) — J2000.
  const mizarRaDeg = (13 + 23 / 60 + 55.5 / 3600) * 15;
  const mizarDecDeg = 54 + 55 / 60 + 31 / 3600;

  // Alcor (80 UMa) — J2000.
  const alcorRaDeg = (13 + 25 / 60 + 13.5 / 3600) * 15;
  const alcorDecDeg = 54 + 59 / 60 + 17 / 3600;

  group('angularSeparation', () {
    test('Mizar–Alcor is about 11.8 arcminutes', () {
      final sepDeg = AstronomyCalculations.angularSeparation(
        ra1Deg: mizarRaDeg,
        dec1Deg: mizarDecDeg,
        ra2Deg: alcorRaDeg,
        dec2Deg: alcorDecDeg,
      );
      // ~11.81', allow a small tolerance for the rounded catalog coordinates.
      expect(sepDeg * 60, closeTo(11.8, 0.2));
    });

    test('coincident points have zero separation', () {
      final sepDeg = AstronomyCalculations.angularSeparation(
        ra1Deg: 83.0,
        dec1Deg: -5.0,
        ra2Deg: 83.0,
        dec2Deg: -5.0,
      );
      expect(sepDeg, closeTo(0.0, 1e-9));
    });

    test('antipodal points are 180 degrees apart', () {
      final sepDeg = AstronomyCalculations.angularSeparation(
        ra1Deg: 0,
        dec1Deg: 0,
        ra2Deg: 180,
        dec2Deg: 0,
      );
      expect(sepDeg, closeTo(180.0, 1e-6));
    });
  });

  group('positionAngle', () {
    test('a due-north companion has PA ~0 degrees', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: 100,
        dec1Deg: 0,
        ra2Deg: 100,
        dec2Deg: 1,
      );
      expect(pa, closeTo(0.0, 1e-6));
    });

    test('a due-south companion has PA ~180 degrees', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: 100,
        dec1Deg: 0,
        ra2Deg: 100,
        dec2Deg: -1,
      );
      expect(pa, closeTo(180.0, 1e-6));
    });

    test('a due-east companion at the equator has PA ~90 degrees', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: 100,
        dec1Deg: 0,
        ra2Deg: 101,
        dec2Deg: 0,
      );
      expect(pa, closeTo(90.0, 1e-6));
    });

    test('a due-west companion at the equator has PA ~270 degrees', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: 100,
        dec1Deg: 0,
        ra2Deg: 99,
        dec2Deg: 0,
      );
      expect(pa, closeTo(270.0, 1e-6));
    });

    test('Alcor lies NE of Mizar (PA ~71 degrees)', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: mizarRaDeg,
        dec1Deg: mizarDecDeg,
        ra2Deg: alcorRaDeg,
        dec2Deg: alcorDecDeg,
      );
      expect(pa, closeTo(71.3, 1.0));
    });

    test('result is always normalised to [0, 360)', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: 100,
        dec1Deg: 0,
        ra2Deg: 99,
        dec2Deg: -1,
      );
      expect(pa, greaterThanOrEqualTo(0.0));
      expect(pa, lessThan(360.0));
    });

    test('coincident points yield a defined (zero) angle', () {
      final pa = AstronomyCalculations.positionAngle(
        ra1Deg: 200,
        dec1Deg: 30,
        ra2Deg: 200,
        dec2Deg: 30,
      );
      expect(pa, 0.0);
    });
  });
}
