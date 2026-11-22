import '../../models/planning/night_forecast.dart';
import '../../models/site/altitude_floor.dart';
import '../../models/weather/cloud_cover_series.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

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

  const ProjectTargetCandidate({
    required this.targetId,
    required this.name,
    required this.raHours,
    required this.decDegrees,
  });
}

/// Pure, I/O-free service that scores each of the next N nights by how many
/// clear, dark hours have an imageable project target up.
///
/// This is the analytic core of the multi-night planner. It consumes
/// **already-fetched** hourly cloud data (a [CloudCoverSeries] from the
/// forecast feed, `LocationCloudForecastService`) and a decoupled list of
/// [ProjectTargetCandidate]s, and emits a [WeekForecast]. Because it performs
/// no network or database access it is unit-testable against synthetic
/// [CloudCoverSample] fixtures.
///
/// ## Fail-closed contract
///
/// A missing or partial forecast is **never** silently treated as clear sky:
///
/// * If the [CloudCoverSeries] is an error or carries no samples, [buildWeek]
///   returns [WeekForecast.unavailable] immediately — no nights are
///   fabricated.
/// * If a night's dark window lies entirely beyond the fetched forecast
///   horizon (no cloud sample within [_cloudSampleTolerance] of any dark hour),
///   that night becomes [NightForecast.unavailable] rather than a clear night.
/// * A polar night with no astronomical darkness is reported honestly with
///   `darkHours == 0` and `forecastAvailable == true` — the night genuinely
///   has no dark window; that is not a forecast failure.
class ForecastPlanningService {
  /// Site latitude in degrees, north positive.
  final double latitudeDegrees;

  /// Site longitude in degrees, east positive.
  final double longitudeDegrees;

  /// The site's altitude floor: a target is "up" in a dark hour when it
  /// stands above it.
  final AltitudeFloor floor;

  /// Cloud fraction (0..1) at or below which a sampled dark hour counts as
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
  /// sample for that sample to be considered representative. Open-Meteo data is
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
    required this.floor,
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
    required CloudCoverSeries cloudResult,
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
    final samples = cloudResult.samples;
    if (samples.isEmpty) {
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
          samples: samples,
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
    required List<CloudCoverSample> samples,
    required List<ProjectTargetCandidate> targets,
  }) {
    final twilight = AstronomyCalculations.twilightTimesNear(
      instant: nightDateLocal,
      latitudeDeg: latitudeDegrees,
      longitudeDeg: longitudeDegrees,
    );

    final duskUtc = twilight.astronomicalDusk?.toUtc();
    final dawnUtc = twilight.astronomicalDawn?.toUtc();

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
      // Cloud: nearest-hour lookup, gated on the fetched horizon — a sample
      // is only trusted if it is within tolerance of the dark hour.
      final nearest = _nearestSample(sampleUtc, samples);
      if (nearest != null && nearest.distance <= _cloudSampleTolerance) {
        final fraction = nearest.sample.fraction.clamp(0.0, 1.0);
        coveredHours += 1;
        cloudSum += fraction;
        if (fraction <= cloudClearThreshold) {
          clearHours += 1;
        }
      }

      // Target visibility at this dark hour.
      for (final t in targets) {
        final (alt, az) = AstronomyCalculations.objectAltAz(
          raDeg: t.raHours * 15.0,
          decDeg: t.decDegrees,
          dt: sampleUtc,
          latitudeDeg: latitudeDegrees,
          longitudeDeg: longitudeDegrees,
        );
        if (alt > (maxAlt[t.targetId] ?? double.negativeInfinity)) {
          maxAlt[t.targetId] = alt;
        }
        if (floor.clears(alt, az)) {
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

  /// The sample in [samples] nearest in time to [time], paired with its
  /// absolute time distance, or null when [samples] is empty.
  ({CloudCoverSample sample, Duration distance})? _nearestSample(
    DateTime time,
    List<CloudCoverSample> samples,
  ) {
    CloudCoverSample? best;
    Duration? bestDistance;
    for (final sample in samples) {
      final d = sample.time.difference(time).abs();
      if (bestDistance == null || d < bestDistance) {
        bestDistance = d;
        best = sample;
      }
    }
    if (best == null || bestDistance == null) return null;
    return (sample: best, distance: bestDistance);
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
}
