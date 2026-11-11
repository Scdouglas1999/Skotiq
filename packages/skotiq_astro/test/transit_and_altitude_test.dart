import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  group('transit and altitude', () {
    test('object at zenith has altitude near 90 degrees', () {
      // At transit with dec == lat, altitude should be 90 degrees
      // sin(alt) = sin(dec)*sin(lat) + cos(dec)*cos(lat)*cos(0)
      //          = sin^2(lat) + cos^2(lat) = 1 => alt = 90
      final testDate = DateTime.utc(2024, 6, 15, 0, 0);
      const lat = 45.0;
      const lon = -90.0;
      const dec = 45.0;
      const ra = 12.0;

      final transitTime = AstronomyCalculations.transitOnUtcDate(
        raDeg: ra * 15.0,
        decDeg: dec,
        date: testDate,
        longitudeDeg: lon,
      );

      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: ra * 15.0,
        decDeg: dec,
        dt: transitTime,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );

      expect(alt, closeTo(90.0, 1.0));
    });

    test('object below horizon has negative altitude', () {
      // A far-south object viewed from a far-north latitude
      // Dec = -80, Lat = 60 should never be visible
      final date = DateTime.utc(2024, 6, 15, 12, 0);
      final (alt, _) = AstronomyCalculations.objectAltAz(
        raDeg: 6.0 * 15.0,
        decDeg: -80.0,
        dt: date,
        latitudeDeg: 60.0,
        longitudeDeg: 0.0,
      );

      expect(
        alt,
        lessThan(0.0),
        reason: 'Far south object should be below horizon at lat 60 N',
      );
    });

    test('alt/az remains finite at zenith singularity', () {
      final testDate = DateTime.utc(2024, 6, 15, 0, 0);
      const lat = 45.0;
      const lon = -90.0;
      const dec = 45.0;
      const ra = 12.0;

      final transitTime = AstronomyCalculations.transitOnUtcDate(
        raDeg: ra * 15.0,
        decDeg: dec,
        date: testDate,
        longitudeDeg: lon,
      );

      final (alt, az) = AstronomyCalculations.objectAltAz(
        raDeg: ra * 15.0,
        decDeg: dec,
        dt: transitTime,
        latitudeDeg: lat,
        longitudeDeg: lon,
      );

      expect(alt.isFinite, isTrue);
      expect(az.isFinite, isTrue);
      expect(az, greaterThanOrEqualTo(0.0));
      expect(az, lessThan(360.0));
    });
  });
}
