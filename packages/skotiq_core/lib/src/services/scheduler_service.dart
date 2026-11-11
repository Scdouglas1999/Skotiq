// ignore_for_file: unused_field, unused_local_variable

import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart'
    show AstronomyCalculations;
import 'scheduler/sky_calculations.dart';

/// Provider for the scheduler service
final schedulerServiceProvider = Provider<SchedulerService>((ref) {
  return SchedulerService(ref);
});

/// Service for intelligent target scheduling
class SchedulerService {
  final Ref _ref;

  SchedulerService(this._ref);

  /// Calculate altitude for a celestial object at a given time
  ///
  /// Uses standard spherical astronomy formulas
  double calculateAltitude({
    required double raHours,
    required double decDegrees,
    required DateTime time,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    final (alt, _) = calculateAltAz(
      raHours: raHours,
      decDegrees: decDegrees,
      time: time,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
    );
    return alt;
  }

  /// Calculate both altitude and azimuth for a celestial object at a given time.
  /// Returns (altitude, azimuth) in degrees.
  ///
  /// [raHours]/[decDegrees] are J2000, as every catalog and target row stores
  /// them; they are precessed to the equinox of [time] before the hour angle
  /// is formed, so this agrees with [AstronomyCalculations.objectAltAz] (the
  /// Framing and Planner altitude) instead of drifting ~0.3 degrees from it.
  (double altitude, double azimuth) calculateAltAz({
    required double raHours,
    required double decDegrees,
    required DateTime time,
    required double latitudeDegrees,
    required double longitudeDegrees,
  }) {
    final (ra, dec) = _ofDate(raHours, decDegrees, time);
    return SkyCalculations.altAzDegrees(
      raHours: ra,
      decDegrees: dec,
      latitudeDegrees: latitudeDegrees,
      lstHours: _calculateLST(time, longitudeDegrees),
    );
  }

  /// J2000 [raHours]/[decDegrees] referred to the equator and equinox of
  /// [time], in hours and degrees.
  static (double raHours, double decDegrees) _ofDate(
    double raHours,
    double decDegrees,
    DateTime time,
  ) {
    final (raDeg, decDeg) = AstronomyCalculations.precessFromJ2000ToDate(
      raDeg: raHours * 15.0,
      decDeg: decDegrees,
      dt: time,
    );
    return (raDeg / 15.0, decDeg);
  }

  /// Calculate Local Sidereal Time in hours.
  ///
  /// Delegates to [SkyCalculations.localSiderealTimeHours]: whole-second day
  /// fraction, GMST normalized to [0,360) before the longitude is added in
  /// hours.
  double _calculateLST(DateTime utcTime, double longitudeDegrees) =>
      SkyCalculations.localSiderealTimeHours(utcTime, longitudeDegrees);

  /// Compute the next time the target falls to (or below) [horizonDeg].
  ///
  /// This is the canonical "time-to-set" helper used by the Run Dashboard
  /// and the planetarium altitude card so both surfaces agree to the
  /// second. The math is a Newton-style binary search on the analytical
  /// rise/set hour-angle equation:
  ///
  ///   * Closed-form hour-angle: `cos(H) = (sin(alt) - sin(δ)sin(φ)) /
  ///     (cos(δ)cos(φ))`. The sidereal rotation of Earth (one solar day ≈
  ///     0.9972 sidereal day) converts the hour-angle delta to a wall-clock
  ///     delta directly, with no probing.
  ///   * Circumpolar / never-rises detection up-front, so the caller gets
  ///     `null` (never sets) or `Duration.zero` (already below) without a
  ///     12 h timeout.
  ///
  /// Returns:
  ///   * `null` if the target never sets above [horizonDeg] within 24 h
  ///     (circumpolar relative to the chosen horizon) — UI should render
  ///     this as "—" / "never sets".
  ///   * `Duration.zero` if the target is already at/below the horizon.
  ///   * Otherwise: the wall-clock duration from [now] to the next time
  ///     the target's altitude crosses [horizonDeg] downward.
  Duration? nextSetTime({
    required double raHours,
    required double decDegrees,
    required DateTime now,
    required double latitudeDegrees,
    required double longitudeDegrees,
    double horizonDeg = 0.0,
  }) {
    // The hour angle below is measured from the equinox of date.
    final (raOfDate, decOfDate) = _ofDate(raHours, decDegrees, now);
    final dec = decOfDate * math.pi / 180.0;
    final lat = latitudeDegrees * math.pi / 180.0;
    final alt = horizonDeg * math.pi / 180.0;

    final cosDec = math.cos(dec);
    final cosLat = math.cos(lat);
    final denominator = cosDec * cosLat;

    // Polar / equator degeneracies: when either latitude or declination
    // pins the daily altitude to a single value, fall back to the simple
    // "above-or-below" check.
    if (denominator.abs() < 1e-12) {
      final fixedAlt = math.asin(math.sin(dec) * math.sin(lat));
      return fixedAlt >= alt ? null : Duration.zero;
    }

    final cosH0 = (math.sin(alt) - math.sin(dec) * math.sin(lat)) / denominator;
    if (cosH0 <= -1.0) {
      // Circumpolar: never crosses the horizon downward.
      return null;
    }
    if (cosH0 >= 1.0) {
      // Never rises above the horizon.
      return Duration.zero;
    }

    // Hour angle at horizon crossing (degrees, then to sidereal hours).
    final h0Deg = math.acos(cosH0) * 180.0 / math.pi;
    final h0SiderealHours = h0Deg / 15.0;

    // Current hour angle (sidereal hours, normalised to [-12, +12]).
    final lst = _calculateLST(now, longitudeDegrees);
    var haHours = lst - raOfDate;
    while (haHours > 12.0) {
      haHours -= 24.0;
    }
    while (haHours < -12.0) {
      haHours += 24.0;
    }

    // Setting happens when HA reaches +h0SiderealHours; if we're already
    // past that, the target is below the horizon. Return zero so the UI
    // can render "set" rather than waiting another sidereal day.
    if (haHours >= h0SiderealHours) {
      // Verify with a direct altitude check — a target whose HA wraps
      // beyond +h0 is below the horizon now.
      final currentAlt = calculateAltitude(
        raHours: raHours,
        decDegrees: decDegrees,
        time: now,
        latitudeDegrees: latitudeDegrees,
        longitudeDegrees: longitudeDegrees,
      );
      if (currentAlt <= horizonDeg) return Duration.zero;
      // Otherwise fall through and treat as a full sidereal day away.
      haHours -= 24.0;
    }

    final siderealHoursToSet = h0SiderealHours - haHours;
    // Convert sidereal hours to solar (mean) hours.
    final solarHoursToSet = siderealHoursToSet * 0.9972695663;
    final seconds = (solarHoursToSet * 3600).round();
    if (seconds <= 0) return Duration.zero;
    return Duration(seconds: seconds);
  }

  /// Calculate transit time for a target
  DateTime calculateTransitTime({
    required double raHours,
    required double decDegrees,
    required DateTime date,
    required double longitudeDegrees,
  }) {
    // Transit occurs when hour angle = 0, i.e., LST = RA
    // We need to find the time when this occurs

    // Start at midnight UTC on the given date
    final midnight = DateTime.utc(date.year, date.month, date.day);

    // Calculate LST at midnight
    final lstMidnight = _calculateLST(midnight, longitudeDegrees);

    // Time until transit in sidereal hours, against the J2000 RA precessed to
    // the equinox of date.
    final (raOfDate, _) = _ofDate(raHours, decDegrees, midnight);
    double hoursUntilTransit = raOfDate - lstMidnight;
    if (hoursUntilTransit < 0) hoursUntilTransit += 24.0;
    if (hoursUntilTransit > 24) hoursUntilTransit -= 24.0;

    // Convert sidereal time to solar time (sidereal day is ~23h 56m 4s)
    final solarHours = hoursUntilTransit * 0.9972695663;

    return midnight.add(
      Duration(
        hours: solarHours.floor(),
        minutes: ((solarHours % 1) * 60).floor(),
        seconds: (((solarHours * 60) % 1) * 60).floor(),
      ),
    );
  }
}
