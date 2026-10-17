part of '../astronomy_calculations.dart';

(double alt, double az) _objectAltAz({
  required double raDeg,
  required double decDeg,
  required DateTime dt,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final (raOfDate, decOfDate) = _precessFromJ2000ToDate(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: dt,
  );
  final lst = _localSiderealTime(dt, longitudeDeg);
  return _equatorialToHorizontal(
    raDeg: raOfDate,
    decDeg: decOfDate,
    latitudeDeg: latitudeDeg,
    lstHours: lst,
  );
}

double _hourAngleDeg({
  required double raDeg,
  required DateTime dt,
  required double longitudeDeg,
}) {
  final lst = _localSiderealTime(dt, longitudeDeg);
  var ha = lst * 15 - raDeg;
  ha = ha % 360;
  if (ha > 180) ha -= 360;
  if (ha <= -180) ha += 360;
  return ha;
}

MeridianFlipWindow? _calculateMeridianFlip({
  required double raDeg,
  required double decDeg,
  required DateTime date,
  required double latitudeDeg,
  required double longitudeDeg,
  double pastMeridianMinutes = 0,
}) {
  final visibility = _calculateObjectVisibility(
    raDeg: raDeg,
    decDeg: decDeg,
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
  final transit = visibility.transitTime;
  if (transit == null) return null;
  return MeridianFlipWindow(
    transitTime: transit,
    flipDeadline: transit.add(Duration(minutes: pastMeridianMinutes.round())),
    transitAltitude: visibility.transitAltitude,
  );
}

double _airmass(double altitudeDeg) {
  if (altitudeDeg <= 0) return double.infinity;
  return airmassForTrueAltitude(altitudeDeg) ?? double.infinity;
}

double _angularSeparation({
  required double ra1Deg,
  required double dec1Deg,
  required double ra2Deg,
  required double dec2Deg,
}) {
  final dec1 = dec1Deg * _deg2rad;
  final dec2 = dec2Deg * _deg2rad;
  final dRa = (ra2Deg - ra1Deg) * _deg2rad;
  final dDec = dec2 - dec1;

  final sinHalfDec = math.sin(dDec / 2);
  final sinHalfRa = math.sin(dRa / 2);
  final a =
      sinHalfDec * sinHalfDec +
      math.cos(dec1) * math.cos(dec2) * sinHalfRa * sinHalfRa;

  return 2 *
      math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1 - a))) *
      _rad2deg;
}

double _positionAngle({
  required double ra1Deg,
  required double dec1Deg,
  required double ra2Deg,
  required double dec2Deg,
}) {
  final dec1 = dec1Deg * _deg2rad;
  final dec2 = dec2Deg * _deg2rad;
  final deltaRa = (ra2Deg - ra1Deg) * _deg2rad;

  final y = math.sin(deltaRa) * math.cos(dec2);
  final x =
      math.cos(dec1) * math.sin(dec2) -
      math.sin(dec1) * math.cos(dec2) * math.cos(deltaRa);

  if (x.abs() < _epsilon && y.abs() < _epsilon) return 0;

  var pa = math.atan2(y, x) * _rad2deg;
  if (pa < 0) pa += 360;
  return pa;
}
