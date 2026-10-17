part of '../astronomy_calculations.dart';

/// Apparent altitude (degrees, including refraction) of a body at [dt].
///
/// [positionAt] supplies the body's RA/Dec; for a fixed object pass a closure
/// that ignores its argument and returns the constant J2000 (or precessed)
/// coordinates.
double _apparentAltitudeOf(
  DateTime dt,
  EquatorialPositionAt positionAt,
  double latitudeDeg,
  double longitudeDeg,
) {
  final (ra, dec) = positionAt(dt);
  final lst = _localSiderealTime(dt, longitudeDeg);
  final (trueAlt, _) = _equatorialToHorizontal(
    raDeg: ra,
    decDeg: dec,
    latitudeDeg: latitudeDeg,
    lstHours: lst,
  );
  return _trueToApparentAltitude(trueAlt);
}

/// Find the instant within [start, end] where the body's apparent altitude
/// crosses [targetAlt]. Requires the endpoints to straddle the target (their
/// `altitude - targetAlt` signs differ); returns null otherwise. Bisection
/// recomputes the body position each step, so it tracks moving bodies and
/// converges to well under one minute.
DateTime? _refineAltitudeCrossing({
  required DateTime start,
  required DateTime end,
  required double targetAlt,
  required EquatorialPositionAt positionAt,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  var t1 = start;
  var t2 = end;
  var d1 =
      _apparentAltitudeOf(t1, positionAt, latitudeDeg, longitudeDeg) -
      targetAlt;
  final d2 =
      _apparentAltitudeOf(t2, positionAt, latitudeDeg, longitudeDeg) -
      targetAlt;
  if (d1.sign == d2.sign) return null;

  while (t2.difference(t1).inSeconds.abs() > 1) {
    final tMid = t1.add(
      Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2),
    );
    final dMid =
        _apparentAltitudeOf(tMid, positionAt, latitudeDeg, longitudeDeg) -
        targetAlt;
    if (dMid == 0) return tMid;
    if (dMid.sign == d1.sign) {
      t1 = tMid;
      d1 = dMid;
    } else {
      t2 = tMid;
    }
  }
  return t1.add(Duration(milliseconds: t2.difference(t1).inMilliseconds ~/ 2));
}

/// The rise that began the up-period already in progress at [windowStart].
///
/// Samples backwards from [windowStart] (up to a day) for the last instant
/// the body was below [targetAlt], then refines the crossing. Returns null if
/// it never was — a circumpolar body has no rise to report.
DateTime? _findRiseBefore({
  required DateTime windowStart,
  required Duration step,
  required double targetAlt,
  required EquatorialPositionAt positionAt,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  if (_apparentAltitudeOf(windowStart, positionAt, latitudeDeg, longitudeDeg) <
      targetAlt) {
    return null;
  }
  final searchStart = windowStart.subtract(const Duration(hours: 24));
  var later = windowStart;
  for (
    var t = windowStart.subtract(step);
    !t.isBefore(searchStart);
    t = t.subtract(step)
  ) {
    if (_apparentAltitudeOf(t, positionAt, latitudeDeg, longitudeDeg) <
        targetAlt) {
      return _refineAltitudeCrossing(
        start: t,
        end: later,
        targetAlt: targetAlt,
        positionAt: positionAt,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
      );
    }
    later = t;
  }
  return null;
}

DateTime _nightDateOf(DateTime instant) {
  final d = instant.hour < 12
      ? instant.subtract(const Duration(days: 1))
      : instant;
  return instant.isUtc
      ? DateTime.utc(d.year, d.month, d.day)
      : DateTime(d.year, d.month, d.day);
}

ObjectVisibility _calculateObjectVisibility({
  required double raDeg,
  required double decDeg,
  required DateTime date,
  required double latitudeDeg,
  required double longitudeDeg,
  double minAltitude = 0,
  double? standardAltitude,
  EquatorialPositionAt? positionAt,
}) {
  final localNoon = DateTime(date.year, date.month, date.day, 12);
  final windowEnd = localNoon.add(const Duration(hours: 24));
  final crossingAlt = standardAltitude ?? minAltitude;

  // Position source: moving body or constant catalog coordinates.
  final posAt = positionAt ?? ((DateTime _) => (raDeg, decDeg));

  // Sample altitude every 5 minutes across the window. A 5-min step is fine
  // enough that even the Moon (~0.5°/hr in altitude near the horizon) cannot
  // skip a crossing, while keeping the loop cheap.
  const step = Duration(minutes: 5);
  final samples = <(DateTime, double)>[];
  for (var t = localNoon; !t.isAfter(windowEnd); t = t.add(step)) {
    samples.add((t, _apparentAltitudeOf(t, posAt, latitudeDeg, longitudeDeg)));
  }

  DateTime? riseTime;
  DateTime? setTime;
  DateTime? transitTime;
  var maxAlt = -91.0;
  var minSampledAlt = 91.0;

  for (var i = 0; i < samples.length; i++) {
    final (t, alt) = samples[i];
    if (alt > maxAlt) {
      maxAlt = alt;
      transitTime = t;
    }
    if (alt < minSampledAlt) minSampledAlt = alt;

    if (i == 0) continue;
    final (prevT, prevAlt) = samples[i - 1];

    // Rising crossing.
    if (riseTime == null && prevAlt < crossingAlt && alt >= crossingAlt) {
      riseTime = _refineAltitudeCrossing(
        start: prevT,
        end: t,
        targetAlt: crossingAlt,
        positionAt: posAt,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
      );
    }
    // Setting crossing (prefer one after rise when both exist in window).
    if (prevAlt >= crossingAlt && alt < crossingAlt) {
      final candidate = _refineAltitudeCrossing(
        start: prevT,
        end: t,
        targetAlt: crossingAlt,
        positionAt: posAt,
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
      );
      if (candidate != null &&
          (setTime == null ||
              (riseTime != null && candidate.isAfter(riseTime)))) {
        setTime = candidate;
      }
    }
  }

  // When the object is already above the threshold at local noon, the first
  // crossing in this 24-hour window is a SET and the next RISE occurs near
  // the end of the window. Returning those two timestamps made
  // durationAboveHorizon negative and exposed an impossible negative-hours
  // result through the scheduler API.
  //
  // Two different objects land in that ordering, and they need opposite
  // repairs. The transit says which: it is the window's altitude maximum, so
  // it belongs to whichever up-period actually culminates inside the window.
  //
  //  * Transit BEFORE the late rise — an object that culminates in the
  //    afternoon and sets in the evening. The set found in the window is the
  //    right one; the rise that began this period lies BEFORE the window.
  //    Pair that set with the rise before the window.
  //  * Transit AFTER the late rise — an object whose up-period starts late in
  //    the window. That rise is the right one and its set lies beyond the
  //    window, so sample forward for it.
  if (riseTime != null &&
      setTime != null &&
      !setTime.isAfter(riseTime) &&
      transitTime != null &&
      transitTime.isBefore(riseTime)) {
    riseTime =
        _findRiseBefore(
          windowStart: localNoon,
          step: step,
          targetAlt: crossingAlt,
          positionAt: posAt,
          latitudeDeg: latitudeDeg,
          longitudeDeg: longitudeDeg,
        ) ??
        riseTime;
  } else if (riseTime != null &&
      setTime != null &&
      !setTime.isAfter(riseTime)) {
    final searchEnd = riseTime.add(const Duration(hours: 24));
    var previousTime = riseTime;
    var previousAltitude = _apparentAltitudeOf(
      previousTime,
      posAt,
      latitudeDeg,
      longitudeDeg,
    );
    DateTime? followingSet;
    for (
      var t = previousTime.add(step);
      !t.isAfter(searchEnd);
      t = t.add(step)
    ) {
      final altitude = _apparentAltitudeOf(t, posAt, latitudeDeg, longitudeDeg);
      if (previousAltitude >= crossingAlt && altitude < crossingAlt) {
        followingSet = _refineAltitudeCrossing(
          start: previousTime,
          end: t,
          targetAlt: crossingAlt,
          positionAt: posAt,
          latitudeDeg: latitudeDeg,
          longitudeDeg: longitudeDeg,
        );
        break;
      }
      previousTime = t;
      previousAltitude = altitude;
    }
    if (followingSet != null) {
      setTime = followingSet;
    }
  }

  // Refine the transit by maximising apparent altitude in the interval
  // bracketing the coarse peak sample (ternary search, sub-minute).
  if (transitTime != null) {
    transitTime = _refineTransit(
      peak: transitTime,
      step: step,
      windowStart: localNoon,
      windowEnd: windowEnd,
      positionAt: posAt,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
  }

  // Transit altitude from the precessed/peak position (not the lat/dec
  // shortcut, which ignores both refraction and the body's motion).
  final transitAltitude = transitTime != null
      ? _apparentAltitudeOf(transitTime, posAt, latitudeDeg, longitudeDeg)
      : maxAlt;

  final isCircumpolar =
      riseTime == null && setTime == null && minSampledAlt >= crossingAlt;
  final neverRises =
      riseTime == null && setTime == null && maxAlt < crossingAlt;

  return ObjectVisibility(
    riseTime: riseTime,
    transitTime: neverRises ? null : transitTime,
    setTime: setTime,
    transitAltitude: transitAltitude,
    isCircumpolar: isCircumpolar,
    neverRises: neverRises,
  );
}

/// Refine the meridian transit near a coarse [peak] sample by maximising
/// apparent altitude with a ternary search over the bracketing interval.
DateTime _refineTransit({
  required DateTime peak,
  required Duration step,
  required DateTime windowStart,
  required DateTime windowEnd,
  required EquatorialPositionAt positionAt,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  var lo = peak.subtract(step);
  if (lo.isBefore(windowStart)) lo = windowStart;
  var hi = peak.add(step);
  if (hi.isAfter(windowEnd)) hi = windowEnd;

  double altAt(DateTime t) =>
      _apparentAltitudeOf(t, positionAt, latitudeDeg, longitudeDeg);

  while (hi.difference(lo).inSeconds > 1) {
    final third = hi.difference(lo).inMilliseconds ~/ 3;
    final m1 = lo.add(Duration(milliseconds: third));
    final m2 = hi.subtract(Duration(milliseconds: third));
    if (altAt(m1) < altAt(m2)) {
      lo = m1;
    } else {
      hi = m2;
    }
  }
  return lo.add(Duration(milliseconds: hi.difference(lo).inMilliseconds ~/ 2));
}

ObjectVisibility _calculateSunVisibility({
  required DateTime date,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final (ra0, dec0) = _sunPosition(date);
  return _calculateObjectVisibility(
    raDeg: ra0,
    decDeg: dec0,
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    standardAltitude: _apparentLimb(_sunRiseSetAltitude),
    positionAt: (dt) => _sunPosition(dt),
  );
}

ObjectVisibility _calculateMoonVisibility({
  required DateTime date,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final (ra0, dec0, _) = _moonPosition(date);
  return _calculateObjectVisibility(
    raDeg: ra0,
    decDeg: dec0,
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    standardAltitude: _apparentLimb(_moonRiseSetAltitude),
    positionAt: (dt) {
      final (ra, dec, _) = _moonPosition(dt);
      return (ra, dec);
    },
  );
}
