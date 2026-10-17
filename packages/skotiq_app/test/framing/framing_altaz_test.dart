import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_altaz.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  test('calculateCurrentAltAz matches AstronomyCalculations', () {
    final time = DateTime.utc(2026, 2, 1, 4, 30);
    const raHours = 5.0;
    const decDegrees = 20.0;
    const lat = 35.0;
    const lon = -105.0;

    final (alt, az) = calculateCurrentAltAz(
      raHours: raHours,
      decDegrees: decDegrees,
      latitudeDeg: lat,
      longitudeDeg: lon,
      time: time,
    );

    final (expectedAlt, expectedAz) = AstronomyCalculations.objectAltAz(
      raDeg: raHours * 15.0,
      decDeg: decDegrees,
      dt: time,
      latitudeDeg: lat,
      longitudeDeg: lon,
    );

    expect(alt, closeTo(expectedAlt, 1e-6));
    expect(az, closeTo(expectedAz, 1e-6));
  });
}
