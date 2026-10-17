// ignore_for_file: unused_field

import 'dart:math' as math;

import 'visibility_models.dart';

export 'visibility_models.dart';

part 'calc/time_and_frames.dart';
part 'calc/precession.dart';
part 'calc/sun_and_twilight.dart';
part 'calc/moon.dart';
part 'calc/rise_set_transit.dart';
part 'calc/geometry.dart';

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

/// Comprehensive astronomy calculations for astrophotography planning
class AstronomyCalculations {
  AstronomyCalculations._();

  // Constants

  // Julian date calculations

  /// Convert DateTime to Julian Date.
  ///
  /// Fliegel–Van Flandern day-number form. This is the Julian Date the whole
  /// planetarium package uses; `PlanetaryPositions.julianDate`,
  /// `MinorPlanetCatalog._julianDate` and `VariableStarCatalog._julianDate`
  /// were byte-for-byte re-typings of it and now call through here.
  ///
  /// [includeMilliseconds] reproduces the one real difference between those
  /// copies: the variable-star catalog stopped its day fraction at whole
  /// seconds. Passing `false` makes the sub-second term a literal `0`, and
  /// `x + 0` is exact, so that catalog's phase numbers are unchanged.
  ///
  /// This is NOT the same function as `SkyCalculations.julianDate` in
  /// `skotiq_core`, which uses Meeus' Gregorian form. Both are correct
  /// Julian Dates and they agree to ~5e-10 d, but they are not the same
  /// doubles, and each side's goldens are pinned to its own. Merging them
  /// would move one set of numbers for no gain; `skotiq_planetarium` is a
  /// leaf package that cannot see `skotiq_core` anyway (the dependency
  /// runs the other way).
  static double julianDate(DateTime dt, {bool includeMilliseconds = true}) =>
      _julianDate(dt, includeMilliseconds: includeMilliseconds);

  /// Convert Julian Date to DateTime
  static DateTime fromJulianDate(double jd) => _fromJulianDate(jd);

  /// Modified Julian Date
  static double modifiedJulianDate(DateTime dt) => _modifiedJulianDate(dt);

  // Sidereal time

  /// Greenwich Mean Sidereal Time in hours
  static double greenwichMeanSiderealTime(DateTime dt) =>
      _greenwichMeanSiderealTime(dt);

  /// Local Sidereal Time in hours
  static double localSiderealTime(DateTime dt, double longitudeDeg) =>
      _localSiderealTime(dt, longitudeDeg);

  // Atmospheric refraction

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

  // Coordinate transformations

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

  // Precession & nutation

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

  // Sun calculations

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

  // Twilight calculations

  // -34/60

  // -50/60

  // Approximate

  /// Twilight type enumeration
  static const double civilTwilightAngle = -6.0;
  static const double nauticalTwilightAngle = -12.0;
  static const double astronomicalTwilightAngle = -18.0;

  /// Calculate twilight times for a given date and location
  static TwilightTimes calculateTwilightTimes({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _calculateTwilightTimes(
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  /// Calculate darkness hours between astronomical dusk and dawn
  static Duration? darknessHours(TwilightTimes twilight) =>
      _darknessHours(twilight);

  // Moon calculations

  /// Calculate Moon position for given DateTime
  /// Returns (ra, dec, distance) - ra/dec in degrees, distance in km
  static (double ra, double dec, double distance) moonPosition(DateTime dt) =>
      _moonPosition(dt);

  /// Calculate Moon illumination percentage (0-100)
  static double moonIllumination(DateTime dt) => _moonIllumination(dt);

  /// Calculate Moon phase name
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

  /// Find Moon rise/set times
  static MoonTimes calculateMoonTimes({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
  }) => _calculateMoonTimes(
    date: date,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );

  // Object rise/set/transit calculations

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

  // Meridian / meridian-flip geometry

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

  // Airmass calculation

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

  // Angular separation

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
