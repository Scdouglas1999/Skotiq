import '../../models/planning/night_forecast.dart';
import '../../models/weather/radar_frame.dart';
import '../scheduler/sky_calculations.dart';
import '../weather/radar_provider.dart';

/// A single project target fed into the multi-night forecast.
///
/// Deliberately a tiny value record rather than a database entity so the
/// forecast service stays decoupled from Drift types and is trivially
/// fixture-testable. The provider layer (component C6) is responsible for
/// projecting `targets` / `project_targets` rows into these candidates.
class ProjectTargetCandidate {
  /// FK to `targets.id`. Carried through to [ForecastTargetUp.targetId].
  final int targetId;

  /// Human-readable target name (e.g. "M31", "NGC 7000").
  final String name;

  /// Right ascension in decimal hours (the `targets.ra` convention).
  final double raHours;

  /// Declination in degrees (the `targets.dec` convention).
  final double decDegrees;

  /// Minimum altitude in degrees the target must clear to count as "up"
  /// (the `targets.minAltitude` convention, default 30° in the schema).
  final double minAltitudeDeg;

  const ProjectTargetCandidate({
    required this.targetId,
    required this.name,
    required this.raHours,
    required this.decDegrees,
    required this.minAltitudeDeg,
  });
}

/// Pure, I/O-free service that scores each of the next N nights by how many
/// clear, dark hours have an imageable project target up.
///
/// This is the analytic core of the multi-night planner. It consumes
/// **already-fetched** hourly cloud data (a [RadarFetchResult] produced by
/// [OpenMeteoCloudProvider] — the fetch itself happens in the C6 provider) and
/// a decoupled list of [ProjectTargetCandidate]s, and emits a [WeekForecast].
/// Because it performs no network or database access it is unit-testable
/// against synthetic [RadarFrame] fixtures.
///
/// ## Fail-closed contract
///
/// A missing or partial forecast is **never** silently treated as clear sky:
///
/// * If [RadarFetchResult] is an error or carries no frames, [buildWeek]
///   returns [WeekForecast.unavailable] immediately — no nights are
///   fabricated.
/// * If a night's dark window lies entirely beyond the fetched forecast
///   horizon (no cloud frame within [_cloudSampleTolerance] of any dark hour),
///   that night becomes [NightForecast.unavailable] rather than a clear night.
/// * A polar night with no astronomical darkness is reported honestly with
///   `darkHours == 0` and `forecastAvailable == true` — the night genuinely
///   has no dark window; that is not a forecast failure.
class ForecastPlanningService {
  /// Site latitude in degrees, north positive.
  final double latitudeDegrees;

  /// Site longitude in degrees, east positive.
  final double longitudeDegrees;

  /// Cloud opacity (0..1) at or below which a sampled dark hour counts as
  /// "clear".
  ///
  /// The default of `0.35` (35% cloud cover) is intentionally tighter than
  /// [WeatherSettings.cloudDensityThreshold]'s 60% warning level and the 80%
  /// hard safety cutoff: planning wants nights that are *worth pointing a
  /// scope at*, not merely nights that won't trip a safety abort. Callers that
  /// want to align with a user's configured tolerance can pass
  /// `cloudDensityThreshold / 100.0`.
  final double cloudClearThreshold;

  /// Maximum distance between a requested sample hour and the nearest cloud
  /// frame for that frame to be considered representative. Open-Meteo data is
  /// hourly, so 90 minutes tolerates the half-hour rounding on either side of
  /// a top-of-hour sample without bleeding into a non-adjacent hour.
  static const Duration _cloudSampleTolerance = Duration(minutes: 90);

  /// Number of best targets retained per night, ranked by up-time.
  static const int _maxBestTargets = 5;

  /// Creates a forecast planner pinned to a site.
  ///
  /// [cloudClearThreshold] must lie in `[0, 1]`; values outside that range are
  /// a programming error and throw [ArgumentError] (fail-loud).
  ForecastPlanningService({
    required this.latitudeDegrees,
    required this.longitudeDegrees,
    this.cloudClearThreshold = 0.35,
  }) {
    if (cloudClearThreshold < 0.0 || cloudClearThreshold > 1.0) {
      throw ArgumentError.value(
        cloudClearThreshold,
        'cloudClearThreshold',
        'must be in the range [0, 1]',
      );
    }
  }

  /// Builds the [nights]-night forecast lookahead starting from the local
  /// calendar date of [nowLocal].
  ///
  /// [cloudResult] is the already-fetched hourly cloud data; [targets] are the
  /// project targets to score visibility for. See the class docs for the
  /// fail-closed contract.
  WeekForecast buildWeek({
    required RadarFetchResult cloudResult,
    required List<ProjectTargetCandidate> targets,
    required DateTime nowLocal,
    int nights = 7,
  }) {
    if (nights <= 0) {
      throw ArgumentError.value(nights, 'nights', 'must be positive');
    }

    // Fail-closed: never fabricate a forecast from an error or empty feed.
    if (!cloudResult.isSuccess) {
      return WeekForecast.unavailable(
        'Cloud forecast unavailable: ${cloudResult.errorMessage}',
      );
    }
    final frames = cloudResult.frames;
    if (frames.isEmpty) {
      return const WeekForecast.unavailable(
        'Cloud forecast unavailable: no forecast frames returned',
      );
    }

    final builtNights = <NightForecast>[];
    for (var i = 0; i < nights; i++) {
      // Anchor each night at local noon of its calendar date — the noon-to-noon
      // "night" bucketing rule used across the scheduler stack. Constructing a
      // local DateTime then adding whole days keeps DST-correct local noons.
      final nightDateLocal = DateTime(
        nowLocal.year,
        nowLocal.month,
        nowLocal.day,
        12,
      ).add(Duration(days: i));

      builtNights.add(
        _buildNight(
          nightDateLocal: nightDateLocal,
          frames: frames,
          targets: targets,
        ),
      );
    }

    // Chronological order (UI ranks by score; the list itself stays by date).
    builtNights.sort((a, b) => a.nightDateLocal.compareTo(b.nightDateLocal));
    return WeekForecast(nights: builtNights);
  }

  NightForecast _buildNight({
    required DateTime nightDateLocal,
    required List<RadarFrame> frames,
    required List<ProjectTargetCandidate> targets,
  }) {
    final twilight = SkyCalculations.computeTwilight(
      noonLocal: nightDateLocal,
      latitudeDegrees: latitudeDegrees,
      longitudeDegrees: longitudeDegrees,
      kind: TwilightKind.astronomical,
    );

    final duskUtc = twilight.eveningEnd?.toUtc();
    final dawnUtc = twilight.morningStart?.toUtc();

    // Polar day / no astronomical darkness: honest zero-dark night, NOT a
    // forecast failure. Both endpoints must exist and be ordered for a real
    // dark window.
    if (duskUtc == null || dawnUtc == null || !dawnUtc.isAfter(duskUtc)) {
      return NightForecast(
        nightDateLocal: nightDateLocal,
        astronomicalDuskUtc: duskUtc,
        astronomicalDawnUtc: dawnUtc,
        darkHours: 0.0,
        clearDarkHours: 0.0,
        meanCloudCoverDuringDark: 0.0,
        bestTargets: const [],
      );
    }

    // Top-of-hour samples across the dark window. We anchor on the first whole
    // hour at or after dusk and step by one hour while still inside the window;
    // each sample represents one dark hour of the night. The fractional tail
    // (the partial hour before dawn) is added so darkHours reflects the true
    // window length rather than only the whole-hour samples.
    final sampleHours = _darkSampleHours(duskUtc, dawnUtc);
    final totalDarkHours = dawnUtc.difference(duskUtc).inSeconds / 3600.0;

    // Cloud accounting, gated on real coverage within tolerance.
    var coveredHours = 0;
    var clearHours = 0;
    var cloudSum = 0.0;

    // Per-target up-hour tallies and peak altitude across the dark window.
    final upHours = <int, int>{};
    final maxAlt = <int, double>{};
    final nameById = <int, String>{};
    for (final t in targets) {
      upHours[t.targetId] = 0;
      maxAlt[t.targetId] = double.negativeInfinity;
      nameById[t.targetId] = t.name;
    }

    for (final sampleUtc in sampleHours) {
      // Cloud: nearest-hour lookup (the same algorithm
      // OpenMeteoCloudProvider.getCloudCoverAt implements), additionally gated
      // on the fetched horizon — a frame is only trusted if it is within
      // tolerance of the sample hour. Open-Meteo frames carry cloud cover as
      // opacity in [0, 1], so we read it directly.
      final nearest = _nearestFrame(sampleUtc, frames);
      if (nearest != null && nearest.distance <= _cloudSampleTolerance) {
        final opacity = nearest.frame.opacity.clamp(0.0, 1.0);
        coveredHours += 1;
        cloudSum += opacity;
        if (opacity <= cloudClearThreshold) {
          clearHours += 1;
        }
      }

      // Target visibility at this dark hour.
      for (final t in targets) {
        final alt = _targetAltitudeDeg(
          raHours: t.raHours,
          decDegrees: t.decDegrees,
          timeUtc: sampleUtc,
        );
        if (alt > (maxAlt[t.targetId] ?? double.negativeInfinity)) {
          maxAlt[t.targetId] = alt;
        }
        if (alt >= t.minAltitudeDeg) {
          upHours[t.targetId] = (upHours[t.targetId] ?? 0) + 1;
        }
      }
    }

    // No dark hour had cloud coverage within tolerance → the whole night sits
    // beyond the fetched horizon. Fail-closed: unavailable, never clear.
    if (sampleHours.isNotEmpty && coveredHours == 0) {
      return NightForecast.unavailable(
        nightDateLocal,
        'Cloud forecast does not reach this night (beyond fetched horizon)',
      );
    }

    // meanCloudCover is reported only over the hours we actually have data for
    // (documented partial-coverage semantics); 0 when there are no samples at
    // all (a window shorter than an hour), in which case clearDarkHours is also
    // 0 and the night scores 0 regardless.
    final meanCloud = coveredHours > 0 ? cloudSum / coveredHours : 0.0;

    // clearDarkHours is a count of clear whole-hour samples, clamped into the
    // true window length so it can never exceed darkHours (the model also
    // enforces score's [0,1] clamp, but we keep the field honest here too).
    final clearDarkHours = clearHours
        .toDouble()
        .clamp(0.0, totalDarkHours)
        .toDouble();

    final bestTargets = _rankTargets(upHours, maxAlt, nameById);

    return NightForecast(
      nightDateLocal: nightDateLocal,
      astronomicalDuskUtc: duskUtc,
      astronomicalDawnUtc: dawnUtc,
      darkHours: totalDarkHours,
      clearDarkHours: clearDarkHours,
      meanCloudCoverDuringDark: meanCloud,
      bestTargets: bestTargets,
    );
  }

  /// Top-of-hour UTC sample instants strictly inside `[duskUtc, dawnUtc)`.
  ///
  /// Anchors on the first whole UTC hour at or after dusk, then steps hourly.
  List<DateTime> _darkSampleHours(DateTime duskUtc, DateTime dawnUtc) {
    final samples = <DateTime>[];
    // First whole hour at or after dusk.
    var hour = DateTime.utc(
      duskUtc.year,
      duskUtc.month,
      duskUtc.day,
      duskUtc.hour,
    );
    if (hour.isBefore(duskUtc)) {
      hour = hour.add(const Duration(hours: 1));
    }
    while (hour.isBefore(dawnUtc)) {
      samples.add(hour);
      hour = hour.add(const Duration(hours: 1));
    }
    return samples;
  }

  /// The frame in [frames] nearest in time to [time], paired with its absolute
  /// time distance, or null when [frames] is empty. This is the same
  /// nearest-hour search [OpenMeteoCloudProvider.getCloudCoverAt] performs,
  /// surfaced as a value so the caller can both gate on the distance and read
  /// the opacity from a single scan.
  ({RadarFrame frame, Duration distance})? _nearestFrame(
    DateTime time,
    List<RadarFrame> frames,
  ) {
    RadarFrame? best;
    Duration? bestDistance;
    for (final frame in frames) {
      final d = frame.timestamp.difference(time).abs();
      if (bestDistance == null || d < bestDistance) {
        bestDistance = d;
        best = frame;
      }
    }
    if (best == null || bestDistance == null) return null;
    return (frame: best, distance: bestDistance);
  }

  /// Ranks targets that are up for at least one dark hour, descending by
  /// up-time (ties broken by higher peak altitude, then by name for
  /// determinism), and keeps the top [_maxBestTargets].
  List<ForecastTargetUp> _rankTargets(
    Map<int, int> upHours,
    Map<int, double> maxAlt,
    Map<int, String> nameById,
  ) {
    final entries = <ForecastTargetUp>[];
    for (final entry in upHours.entries) {
      if (entry.value <= 0) continue;
      final peak = maxAlt[entry.key];
      entries.add(
        ForecastTargetUp(
          targetId: entry.key,
          targetName: nameById[entry.key] ?? '',
          upDarkHours: entry.value.toDouble(),
          // A target with up-hours > 0 always reached its min altitude, so peak
          // is a real finite value; guard the impossible -inf for safety.
          maxAltitudeDeg: (peak == null || peak == double.negativeInfinity)
              ? 0.0
              : peak,
        ),
      );
    }
    entries.sort((a, b) {
      final byHours = b.upDarkHours.compareTo(a.upDarkHours);
      if (byHours != 0) return byHours;
      final byAlt = b.maxAltitudeDeg.compareTo(a.maxAltitudeDeg);
      if (byAlt != 0) return byAlt;
      return a.targetName.compareTo(b.targetName);
    });
    if (entries.length > _maxBestTargets) {
      return entries.sublist(0, _maxBestTargets);
    }
    return entries;
  }

  /// Apparent topocentric altitude (degrees) of an equatorial target at
  /// [timeUtc] for this site.
  ///
  /// Uses the standard spherical-astronomy altitude formula — the same
  /// derivation as [SchedulerService.calculateAltAz], reusing
  /// [SkyCalculations.julianDate] for the Julian Date so the time base stays
  /// single-sourced with the twilight engine. (Neither public alt-az helper is
  /// usable directly here: `SkyCalculations.sunAltAz` only does the sun, and
  /// `SchedulerService.calculateAltAz` is an instance method requiring a
  /// Riverpod `Ref`, which a pure service must not hold.)
  double _targetAltitudeDeg({
    required double raHours,
    required double decDegrees,
    required DateTime timeUtc,
  }) {
    final lstHours = _localSiderealTimeHours(timeUtc);
    return SkyCalculations.altitudeDegrees(
      hourAngleDegrees: (lstHours - raHours) * 15.0,
      declinationDegrees: decDegrees,
      latitudeDegrees: latitudeDegrees,
    );
  }

  /// Local apparent sidereal time in hours `[0, 24)` for this site at
  /// [timeUtc], from the IAU GMST polynomial — identical to the formula
  /// embedded in [SkyCalculations.sunAltAz].
  double _localSiderealTimeHours(DateTime timeUtc) {
    final jd = SkyCalculations.julianDate(timeUtc);
    var gmstDeg = SkyCalculations.gmstDegreesRaw(jd);
    gmstDeg %= 360.0;
    if (gmstDeg < 0) gmstDeg += 360.0;
    var lstDeg = (gmstDeg + longitudeDegrees) % 360.0;
    if (lstDeg < 0) lstDeg += 360.0;
    return lstDeg / 15.0;
  }
}
