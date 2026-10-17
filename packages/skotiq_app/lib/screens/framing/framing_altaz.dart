import 'package:skotiq_planetarium/skotiq_planetarium.dart';

(double alt, double az) calculateCurrentAltAz({
  required double raHours,
  required double decDegrees,
  required double latitudeDeg,
  required double longitudeDeg,
  required DateTime time,
}) {
  final raDeg = raHours * 15.0;
  return AstronomyCalculations.objectAltAz(
    raDeg: raDeg,
    decDeg: decDegrees,
    dt: time,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
}
