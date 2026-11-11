part of '../astronomy_calculations.dart';

/// Solar seconds per sidereal second.
const double _solarPerSidereal = 0.9972695663;

Duration? _timeUntilBelow({
  required double raDeg,
  required double decDeg,
  required DateTime now,
  required double latitudeDeg,
  required double longitudeDeg,
  required double horizonDeg,
}) {
  final (raOfDate, decOfDate) = _precessFromJ2000ToDate(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: now,
  );
  final dec = decOfDate * _deg2rad;
  final lat = latitudeDeg * _deg2rad;
  final alt = horizonDeg * _deg2rad;

  final denominator = math.cos(dec) * math.cos(lat);
  // At a pole (or for a target on the celestial pole) the altitude never
  // changes through the day.
  if (denominator.abs() < 1e-12) {
    final fixedAlt = math.asin(math.sin(dec) * math.sin(lat));
    return fixedAlt >= alt ? null : Duration.zero;
  }

  final cosH0 = (math.sin(alt) - math.sin(dec) * math.sin(lat)) / denominator;
  if (cosH0 <= -1.0) return null;
  if (cosH0 >= 1.0) return Duration.zero;
  final h0Hours = math.acos(cosH0) * _rad2deg / 15.0;

  var haHours = AstronomyCalculations.hourAngleHours(
    raOfDate / 15.0,
    _localSiderealTime(now, longitudeDeg),
  );
  if (haHours >= h0Hours) {
    final (currentAlt, _) = _equatorialToHorizontal(
      raDeg: raOfDate,
      decDeg: decOfDate,
      latitudeDeg: latitudeDeg,
      lstHours: _localSiderealTime(now, longitudeDeg),
    );
    if (currentAlt <= horizonDeg) return Duration.zero;
    haHours -= 24.0;
  }

  final seconds = ((h0Hours - haHours) * _solarPerSidereal * 3600).round();
  return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
}

DateTime _transitOnUtcDate({
  required double raDeg,
  required double decDeg,
  required DateTime date,
  required double longitudeDeg,
}) {
  final midnight = DateTime.utc(date.year, date.month, date.day);
  final (raOfDate, _) = _precessFromJ2000ToDate(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: midnight,
  );
  var siderealHours =
      raOfDate / 15.0 - _localSiderealTime(midnight, longitudeDeg);
  if (siderealHours < 0) siderealHours += 24.0;
  final solarHours = siderealHours * _solarPerSidereal;
  return midnight.add(
    Duration(
      hours: solarHours.floor(),
      minutes: ((solarHours % 1) * 60).floor(),
      seconds: (((solarHours * 60) % 1) * 60).floor(),
    ),
  );
}
