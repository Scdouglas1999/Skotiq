// ignore_for_file: unused_field

import 'dart:math' as math;
import 'dart:typed_data';

import 'visibility_models.dart';

export 'visibility_models.dart';

part 'calc/time_and_frames.dart';
part 'calc/precession.dart';
part 'calc/sun_and_twilight.dart';
part 'calc/moon.dart';
part 'calc/rise_set_transit.dart';
part 'calc/geometry.dart';
part 'calc/hour_angle_events.dart';

const double _deg2rad = math.pi / 180;

const double _rad2deg = 180 / math.pi;

const double _epsilon = 1e-12;

const double _j2000 = 2451545.0;

// Obliquity of ecliptic at J2000 (degrees)
const double _obliquityJ2000 = 23.439291111;

/// Signature for a body's apparent equatorial position (RA/Dec, degrees) at a
/// given instant. Used by [AstronomyCalculations.calculateObjectVisibility] to
/// track moving bodies (Sun/Moon/planets) across the night. Fixed catalog
/// objects simply omit this callback and their J2000 RA/Dec is used directly.
typedef EquatorialPositionAt =
    (double raDeg, double decDeg) Function(DateTime dt);

/// Canonical airmass model shared by planning and science exports.
///
/// Uses Pickering (2002) at true altitude >= 10 degrees and Young (1994) down
/// to the horizon, matching `skotiq_imaging::calculate_airmass` in the FITS
/// writer. [altitudeDegrees] is geometric altitude. Non-finite and
/// below-horizon values return `null`; valid values are not artificially
/// clamped.
double? airmassForTrueAltitude(double altitudeDegrees) {
  if (!altitudeDegrees.isFinite || altitudeDegrees < 0.0) {
    return null;
  }
  // Guard numerical noise like 90.000001, which would push sin() past 1.
  final alt = altitudeDegrees > 90.0 ? 90.0 : altitudeDegrees;
  if (alt >= 89.9) {
    // Both formulas converge to 1.0 here; short-circuit so floating-point
    // jitter cannot report 0.99999999 airmass at the zenith.
    return 1.0;
  }

  const degToRad = math.pi / 180.0;
  final double airmass;
  if (alt >= 10.0) {
    final correctionDeg = 244.0 / (165.0 + 47.0 * math.pow(alt, 1.1));
    airmass = 1.0 / math.sin((alt + correctionDeg) * degToRad);
  } else {
    // Young 1994, in true zenith angle z = 90 - h:
    //   X = (1.002432 cos^2 z + 0.148386 cos z + 0.0096467) /
    //       (cos^3 z + 0.149864 cos^2 z + 0.0102963 cos z + 0.000303978)
    final cosZ = math.cos((90.0 - alt) * degToRad);
    final cos2 = cosZ * cosZ;
    final cos3 = cos2 * cosZ;
    airmass =
        (1.002432 * cos2 + 0.148386 * cosZ + 0.0096467) /
        (cos3 + 0.149864 * cos2 + 0.0102963 * cosZ + 0.000303978);
  }

  return airmass.isFinite ? airmass : null;
}

/// The evening date, in the host's local time, of the observing night [time]
/// belongs to. A night runs from local noon to local noon, so a frame taken
/// after midnight stays with the evening it started on.
DateTime observingNightOf(DateTime time) =>
    AstronomyCalculations.nightDateOf(time.toLocal());

/// The observing night [time] falls in, as the local noon it starts at and the
/// next local noon: the night [observingNightOf] names.
({DateTime start, DateTime end}) observingNightWindow(DateTime time) {
  final evening = observingNightOf(time);
  return (
    start: DateTime(evening.year, evening.month, evening.day, 12),
    end: DateTime(evening.year, evening.month, evening.day + 1, 12),
  );
}

/// Comprehensive astronomy calculations for astrophotography planning
class AstronomyCalculations {
  AstronomyCalculations._();

  /// Julian Date (UTC) of [dt], to the millisecond.
  ///
  /// The one Julian Date in the product, taken straight from the instant's
  /// epoch milliseconds with no calendar arithmetic. It agrees with Meeus'
  /// and the Fliegel-Van Flandern calendar forms to the last bit or two of a
  /// double (under 0.1 ms) and with astropy over 2000-2032.
  static double julianDate(DateTime dt) => _julianDate(dt);

  static DateTime fromJulianDate(double jd) => _fromJulianDate(jd);

  static double modifiedJulianDate(DateTime dt) => _modifiedJulianDate(dt);

  /// Greenwich Mean Sidereal Time in hours
  static double greenwichMeanSiderealTime(DateTime dt) =>
      _greenwichMeanSiderealTime(dt);

  /// Local Sidereal Time in hours
  static double localSiderealTime(DateTime dt, double longitudeDeg) =>
      _localSiderealTime(dt, longitudeDeg);

  /// Hour angle in hours, normalized to (-12, +12], from a right ascension
  /// and a local sidereal time in hours. Positive is west of the meridian.
  static double hourAngleHours(double raHours, double lstHours) {
    var ha = (lstHours - raHours) % 24.0;
    if (ha > 12.0) ha -= 24.0;
    if (ha <= -12.0) ha += 24.0;
    return ha;
  }

  /// Calculate atmospheric refraction correction using Bennett (1982) formula
  /// This is the standard formula used by the USNO
  ///
  /// Assumes standard atmospheric conditions:
  /// - Temperature: 10°C
  /// - Pressure: 1010 mbar
  /// - Humidity: Standard
  ///
  /// Accuracy: ~0.1 arcmin for altitudes > 15°, ~1 arcmin near horizon
  ///
  /// Returns refraction in degrees (always positive, adds to apparent altitude)
  static double atmosphericRefraction(double trueAltitudeDeg) =>
      _atmosphericRefraction(trueAltitudeDeg);

  /// Convert true (geometric) altitude to apparent (observed) altitude
  /// by adding atmospheric refraction
  static double trueToApparentAltitude(double trueAltDeg) =>
      _trueToApparentAltitude(trueAltDeg);

  /// Convert apparent (observed) altitude to true (geometric) altitude
  /// by removing atmospheric refraction
  ///
  /// Uses iterative method since refraction depends on altitude
  /// 3 iterations provide sub-arcsecond accuracy
  static double apparentToTrueAltitude(double apparentAltDeg) =>
      _apparentToTrueAltitude(apparentAltDeg);

  /// Convert equatorial (RA/Dec) to horizontal (Alt/Az) coordinates
  /// Returns (altitude, azimuth) in degrees
  static (double alt, double az) equatorialToHorizontal({
    required double raDeg,
    required double decDeg,
    required double latitudeDeg,
    required double lstHours,
  }) => _equatorialToHorizontal(
    raDeg: raDeg,
    decDeg: decDeg,
    latitudeDeg: latitudeDeg,
    lstHours: lstHours,
  );

  /// Convert horizontal (Alt/Az) to equatorial (RA/Dec) coordinates
  /// Returns (ra, dec) in degrees
  static (double ra, double dec) horizontalToEquatorial({
    required double altDeg,
    required double azDeg,
    required double latitudeDeg,
    required double lstHours,
  }) => _horizontalToEquatorial(
    altDeg: altDeg,
    azDeg: azDeg,
    latitudeDeg: latitudeDeg,
    lstHours: lstHours,
  );

  /// Convert ecliptic to equatorial coordinates
  /// Returns (ra, dec) in degrees
  static (double ra, double dec) eclipticToEquatorial({
    required double lonDeg,
    required double latDeg,
    required double obliquityDeg,
  }) => _eclipticToEquatorial(
    lonDeg: lonDeg,
    latDeg: latDeg,
    obliquityDeg: obliquityDeg,
  );

  /// Convert galactic coordinates to equatorial (J2000) coordinates.
  /// Uses the IAU 1958 galactic coordinate system:
  ///   - North galactic pole at RA 12h51m26.28s, Dec +27°07'41.7" (J2000)
  ///   - Galactic center direction at RA 17h45m37.2s, Dec -28°56'10.2" (J2000)
  ///   - Ascending node of galactic plane on equator at RA 282.8595°
  /// Returns (ra, dec) in degrees.
  static (double ra, double dec) galacticToEquatorial({
    required double lonDeg,
    required double latDeg,
  }) => _galacticToEquatorial(lonDeg: lonDeg, latDeg: latDeg);

  /// Nutation in longitude and obliquity (degrees) for a given Julian Date.
  ///
  /// Uses the four dominant terms of the IAU 1980 nutation series (the 18.6-yr
  /// lunar-node term plus the principal solar/lunar terms), accurate to within
  /// roughly an arcsecond — far finer than the ~1-arcminute target of the
  /// rise/set and grid work this feeds. Returns (dPsi, dEps) in degrees.
  static (double dPsiDeg, double dEpsDeg) nutation(double jd) => _nutation(jd);

  /// Mean obliquity of the ecliptic (degrees) for a Julian Date, per the
  /// IAU 1980 polynomial (Meeus eq. 22.2).
  static double meanObliquity(double jd) => _meanObliquity(jd);

  /// Precess equatorial coordinates from J2000.0 to the equinox of [dt],
  /// then apply nutation, yielding apparent RA/Dec referred to the true
  /// equator and equinox of date.
  ///
  /// Uses the rigorous IAU 1976 precession angles (Lieske) followed by the
  /// classic nutation rotation. Inputs and outputs are degrees. This is what
  /// the coordinate grid and rise/set logic should use to place J2000 catalog
  /// positions in the sky of the requested instant.
  static (double raDeg, double decDeg) precessFromJ2000ToDate({
    required double raDeg,
    required double decDeg,
    required DateTime dt,
  }) => _precessFromJ2000ToDate(raDeg: raDeg, decDeg: decDeg, dt: dt);

  /// Exact inverse of [precessFromJ2000ToDate]: takes apparent RA/Dec referred
  /// to the true equator and equinox of [dt] and returns the mean J2000 place.
  ///
  /// The planetarium draws EVERYTHING in one frame, and that frame is J2000 —
  /// the frame the star and DSO catalogues are published in. Ephemerides
  /// (VSOP87D planets, the Sun, the Moon) naturally come out referred to the
  /// equinox of date, so they are brought here before they reach the chart.
  /// Without it the two families were drawn ~22 arcmin apart in 2026 — Jupiter
  /// sat two thirds of a Moon diameter away from where it really is against
  /// M44 — which is worse than either frame chosen consistently.
  ///
  /// Nutation is removed first (the forward transform applies it last), then
  /// the precession rotation is inverted with Meeus eq. 21.5. Inputs and
  /// outputs are degrees.
  static (double raDeg, double decDeg) precessFromDateToJ2000({
    required double raDeg,
    required double decDeg,
    required DateTime dt,
  }) => _precessFromDateToJ2000(raDeg: raDeg, decDeg: decDeg, dt: dt);

  /// Calculate Sun position for given DateTime
  /// Returns (ra, dec) in degrees
  static (double ra, double dec) sunPosition(DateTime dt) => _sunPosition(dt);

  /// Calculate Sun altitude at given time and location
  ///
  /// If [apparent] is true (default), returns apparent altitude including
  /// atmospheric refraction. If false, returns true geometric altitude.
  static double sunAltitude({
    required DateTime dt,
    required double latitudeDeg,
    required double longitudeDeg,
    bool apparent = true,
  }) => _sunAltitude(
    dt: dt,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    apparent: apparent,
  );

  /// True (geometric) altitude and azimuth of the Sun's centre, degrees.
  /// Azimuth is measured east of north.
  static (double alt, double az) sunAltAz({
    required DateTime dt,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _sunAltAz(dt: dt, latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg);

  static const double civilTwilightAngle = -6.0;
  static const double nauticalTwilightAngle = -12.0;
  static const double astronomicalTwilightAngle = -18.0;

  /// Twilight times for the night that follows the site's solar noon on the
  /// calendar day of [date].
  ///
  /// Only the calendar day of [date] is read, so an instant past local
  /// midnight selects the NEXT night; use [twilightTimesNear] when all you
  /// hold is an instant. Events are returned in the host's local time.
  static TwilightTimes calculateTwilightTimes({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _twilightTimesFromSolarNoon(
    siteSolarNoon: _siteSolarNoonOfDate(date, longitudeDeg),
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// Twilight times for the night that follows the site's solar noon nearest
  /// to [instant].
  ///
  /// Pass the host's local noon to get "tonight" for a site in any timezone,
  /// or an instant during a night to get that night's own dusk and dawn once
  /// it is past the site's solar midnight. Events are returned in the zone of
  /// [instant] (UTC in, UTC out).
  static TwilightTimes twilightTimesNear({
    required DateTime instant,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _twilightTimesFromSolarNoon(
    siteSolarNoon: _siteSolarNoonNearest(instant, longitudeDeg),
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// The next [kind] dawn at the site that is not already behind [now]: last
  /// night's while it is still ahead (after midnight), otherwise tonight's.
  /// Null when neither night has one (a night that never gets that dark).
  static DateTime? nextDawn({
    required DateTime now,
    required double latitudeDeg,
    required double longitudeDeg,
    TwilightKind kind = TwilightKind.astronomical,
  }) {
    for (final daysBack in const [1, 0]) {
      final dawn = twilightTimesNear(
        instant: DateTime(now.year, now.month, now.day - daysBack, 12),
        latitudeDeg: latitudeDeg,
        longitudeDeg: longitudeDeg,
      ).dawn(kind);
      if (dawn == null || now.isAfter(dawn)) continue;
      return dawn;
    }
    return null;
  }

  /// Calculate darkness hours between astronomical dusk and dawn
  static Duration? darknessHours(TwilightTimes twilight) =>
      _darknessHours(twilight);

  /// Calculate Moon position for given DateTime
  /// Returns (ra, dec, distance) - ra/dec in degrees, distance in km
  static (double ra, double dec, double distance) moonPosition(DateTime dt) =>
      _moonPosition(dt);

  /// Calculate Moon illumination percentage (0-100)
  static double moonIllumination(DateTime dt) => _moonIllumination(dt);

  static String moonPhaseName(DateTime dt) => _moonPhaseName(dt);

  /// Calculate Moon altitude at given time and location
  ///
  /// If [apparent] is true (default), returns apparent altitude including
  /// atmospheric refraction. If false, returns true geometric altitude.
  static double moonAltitude({
    required DateTime dt,
    required double latitudeDeg,
    required double longitudeDeg,
    bool apparent = true,
  }) => _moonAltitude(
    dt: dt,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    apparent: apparent,
  );

  static MoonTimes calculateMoonTimes({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _calculateMoonTimes(
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// The calendar date of the night that CONTAINS [instant] — the value to pass
  /// as `date` to [calculateObjectVisibility] when all you hold is a timestamp.
  ///
  /// The observing night runs local noon to local noon, so anything before noon
  /// belongs to the night that started the previous day. Handing `date` a raw
  /// instant that has crossed midnight describes the FOLLOWING night — a whole
  /// sidereal day (~4 min) of error in every rise/transit/set time.
  static DateTime nightDateOf(DateTime instant) => _nightDateOf(instant);

  /// Calculate rise, transit, and set times for an object.
  ///
  /// The window scanned is the local day of [date] from noon to the following
  /// noon. [date] is therefore the DATE of the night, not an instant within it —
  /// only its calendar day is read, and a timestamp past local midnight selects
  /// the NEXT night. Convert an instant with [nightDateOf].
  ///
  /// The three times describe ONE pass of the sky: rise < transit < set, and
  /// the rise may fall before the window when the body is already up as it
  /// opens. Which pass is reported is decided by the transit — the window's
  /// altitude maximum — so it is the culmination the window was opened for.
  ///
  /// Every sample recomputes the body's position via [positionAt], so
  /// Sun/Moon/planets track across the night; fixed catalog objects omit
  /// [positionAt] and use their constant RA/Dec.
  ///
  /// [minAltitude] is the altitude that defines "up" for rise/set (default 0°,
  /// i.e. the geometric horizon). [standardAltitude] overrides the altitude
  /// actually used for the crossing search — pass e.g. -0.833° for the Sun/Moon
  /// limb (refraction + semi-diameter). When omitted it follows [minAltitude].
  static ObjectVisibility calculateObjectVisibility({
    required double raDeg,
    required double decDeg,
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
    double minAltitude = 0,
    double? standardAltitude,
    EquatorialPositionAt? positionAt,
  }) => _calculateObjectVisibility(
    raDeg: raDeg,
    decDeg: decDeg,
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    minAltitude: minAltitude,
    standardAltitude: standardAltitude,
    positionAt: positionAt,
  );

  /// Rise, transit and set for the pass culminating closest to [center]:
  /// the window runs from 12 hours before [center] to 12 hours after.
  ///
  /// Use this with a night's midpoint when the observing site is not in the
  /// host computer's time zone. [calculateObjectVisibility] opens its window
  /// at the host's local noon, which for a distant site can cut the night in
  /// two and report the previous day's culmination.
  static ObjectVisibility calculateObjectVisibilityAround({
    required double raDeg,
    required double decDeg,
    required DateTime center,
    required double latitudeDeg,
    required double longitudeDeg,
    double minAltitude = 0,
  }) => _calculateObjectVisibility(
    raDeg: raDeg,
    decDeg: decDeg,
    date: center,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    minAltitude: minAltitude,
    windowStart: center.subtract(const Duration(hours: 12)),
  );

  /// Sun rise/transit/set for the local day of [date], tracking the Sun's
  /// motion and using the standard -0.833° limb altitude.
  ///
  /// One daytime pass: rise, culmination and set all belong to [date]. For the
  /// dusk-tonight → dawn-tomorrow span the night strip draws, use
  /// [calculateTwilightTimes] — that pairs this sunset with the NEXT sunrise.
  static ObjectVisibility calculateSunVisibility({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _calculateSunVisibility(
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// Moon rise/transit/set for the local day of [date], tracking the Moon's
  /// fast motion and using the approximate -0.7° limb altitude.
  static ObjectVisibility calculateMoonVisibility({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _calculateMoonVisibility(
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// True (geometric) altitude and azimuth of a catalog object at [dt].
  ///
  /// [raDeg]/[decDeg] are J2000 catalog coordinates — what every Skotiq
  /// catalog and target row stores — and are precessed (and nutated) to the
  /// equinox of [dt] before the hour angle is formed, because the hour angle is
  /// measured from the equinox of DATE. Skipping that step is not a rounding
  /// error: a quarter-century past J2000 the equinox has moved ~22 arcmin, and
  /// because the azimuth error is amplified by 1/cos(altitude) it reached 1.4
  /// degrees for a near-zenith target in the audited case — enough to mis-call
  /// an obstruction check or a meridian flip. [precessFromJ2000ToDate] existed
  /// for exactly this and had no callers.
  ///
  /// Refraction is deliberately NOT applied: callers use this for pointing and
  /// altitude limits, which are geometric. Use [trueToApparentAltitude] on the
  /// result where the observed (refracted) altitude is what is wanted.
  static (double alt, double az) objectAltAz({
    required double raDeg,
    required double decDeg,
    required DateTime dt,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _objectAltAz(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: dt,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// How long until a J2000 target next drops to [horizonDeg], from the
  /// closed-form hour angle of that altitude (geometric, no refraction).
  ///
  /// Null when it never gets that low (circumpolar for this horizon);
  /// [Duration.zero] when it is already at or below it, or never rises above
  /// it. This answers "how long can I keep imaging from now" for any altitude
  /// limit; [calculateObjectVisibility] answers "when does it rise and set on
  /// this night" at the refracted horizon.
  static Duration? timeUntilBelow({
    required double raDeg,
    required double decDeg,
    required DateTime now,
    required double latitudeDeg,
    required double longitudeDeg,
    double horizonDeg = 0.0,
  }) => _timeUntilBelow(
    raDeg: raDeg,
    decDeg: decDeg,
    now: now,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    horizonDeg: horizonDeg,
  );

  /// The meridian transit of a J2000 target on the UTC calendar day of
  /// [date]: the first instant at or after 00:00 UTC that its hour angle is 0.
  static DateTime transitOnUtcDate({
    required double raDeg,
    required double decDeg,
    required DateTime date,
    required double longitudeDeg,
  }) => _transitOnUtcDate(
    raDeg: raDeg,
    decDeg: decDeg,
    date: date,
    longitudeDeg: longitudeDeg,
  );

  /// Hour angle of a target (degrees) for the given instant and location.
  ///
  /// HA = LST - RA, normalised to (-180, 180]. Negative means the target is
  /// east of the local meridian (rising side); positive means west (setting
  /// side); zero is the meridian transit. This is the quantity a German
  /// equatorial mount uses to decide which side of the pier it must sit on, so
  /// it is the geometric basis of the meridian-flip marker.
  static double hourAngleDeg({
    required double raDeg,
    required DateTime dt,
    required double longitudeDeg,
  }) => _hourAngleDeg(raDeg: raDeg, dt: dt, longitudeDeg: longitudeDeg);

  /// The meridian-flip window for a target on the local day of [date].
  ///
  /// The flip itself happens at the target's meridian transit (hour angle 0),
  /// which is exactly the transit returned by [calculateObjectVisibility]. A
  /// real GEM is usually allowed to track a little past the meridian before the
  /// flip is forced; [pastMeridianMinutes] expresses that limit as the latest
  /// time imaging can continue on the east side before the flip is required.
  ///
  /// Returns null when the target never transits on this day (never rises), so
  /// callers can skip the marker entirely rather than draw a meaningless one.
  static MeridianFlipWindow? calculateMeridianFlip({
    required double raDeg,
    required double decDeg,
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
    double pastMeridianMinutes = 0,
  }) => _calculateMeridianFlip(
    raDeg: raDeg,
    decDeg: decDeg,
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
    pastMeridianMinutes: pastMeridianMinutes,
  );

  /// Airmass for planning surfaces, with the scheduler's convention applied.
  ///
  /// The number itself comes from [airmassForTrueAltitude] — the product's one
  /// model — so the altitude chart, the target score and the FITS `AIRMASS`
  /// card of the frame that gets captured all describe the same atmosphere.
  ///
  /// The one thing layered on top is a deliberate, named CONVENTION: an object
  /// at or below the horizon scores as `infinity` rather than "unknown", so
  /// weighted target scoring drives it to zero instead of having to special-case
  /// a null. This mirrors `skotiq_sequencer::scheduling::astronomy::airmass`
  /// on the Rust side, which does the same for the same reason.
  static double airmass(double altitudeDeg) => _airmass(altitudeDeg);

  /// Calculate angular separation between two sky coordinates (degrees).
  ///
  /// The haversine form is used rather than the spherical law of cosines
  /// because the app compares separations at arcsecond scale — coincident-star
  /// merging, catalog cone search, guide-star matching. At those separations
  /// `acos` of a cosine within ~1e-16 of 1 loses roughly half the mantissa,
  /// which is the difference between two distinct stars and one.
  static double angularSeparation({
    required double ra1Deg,
    required double dec1Deg,
    required double ra2Deg,
    required double dec2Deg,
  }) => _angularSeparation(
    ra1Deg: ra1Deg,
    dec1Deg: dec1Deg,
    ra2Deg: ra2Deg,
    dec2Deg: dec2Deg,
  );

  /// Position angle of the second point as seen from the first, measured at the
  /// first point from celestial North through East (degrees, 0–360).
  ///
  /// This is the standard astronomical convention used for double-star and
  /// reference-frame measurements: 0° = the companion lies due north of the
  /// primary, 90° = due east, 180° = south, 270° = west. The angle is computed
  /// on the sphere (great-circle bearing), so it is exact for any separation
  /// rather than a flat-sky approximation.
  ///
  /// Returns 0 when the two points coincide (degenerate, undefined PA).
  static double positionAngle({
    required double ra1Deg,
    required double dec1Deg,
    required double ra2Deg,
    required double dec2Deg,
  }) => _positionAngle(
    ra1Deg: ra1Deg,
    dec1Deg: dec1Deg,
    ra2Deg: ra2Deg,
    dec2Deg: dec2Deg,
  );
}
