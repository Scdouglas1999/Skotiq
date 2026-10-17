import 'package:equatable/equatable.dart';

/// One project target that clears its minimum altitude during a night's dark
/// window, with how much dark time it is actually up for.
///
/// Produced by the forecast lookahead (component C2) when scoring an upcoming
/// night: the planner walks each project target across the night's dark hours,
/// keeps the ones that rise above their configured minimum altitude, and ranks
/// them by how many dark+clear hours they are visible. Pure value type — no
/// database identity, never persisted on its own.
class ForecastTargetUp extends Equatable {
  /// FK to `targets.id`.
  final int targetId;

  final String targetName;

  /// Hours the target spends above its minimum altitude *during the dark
  /// window* (not the whole night). Always `>= 0`.
  final double upDarkHours;

  /// Peak altitude reached during the dark window, in degrees.
  final double maxAltitudeDeg;

  const ForecastTargetUp({
    required this.targetId,
    required this.targetName,
    required this.upDarkHours,
    required this.maxAltitudeDeg,
  });

  Map<String, dynamic> toJson() => {
    'targetId': targetId,
    'targetName': targetName,
    'upDarkHours': upDarkHours,
    'maxAltitudeDeg': maxAltitudeDeg,
  };

  @override
  List<Object?> get props => [
    targetId,
    targetName,
    upDarkHours,
    maxAltitudeDeg,
  ];
}

/// Forecast score and supporting figures for one upcoming night.
///
/// Binds to the multi-night planner's week view: each night carries its dark
/// window, how much of that window is expected to be clear (cloud at or below
/// the configured threshold), the targets that are up, and a single composite
/// [score] used to rank nights against each other.
///
/// Fail-closed is structural here. When a forecast cannot be produced (no
/// forecast feed reachable, site outside the forecast horizon, polar day, etc.)
/// callers must use [NightForecast.unavailable] with an honest reason rather
/// than fabricating a clear-sky default — a missing forecast is never silently
/// treated as a good night. Pure derivation model; no persistence.
class NightForecast extends Equatable {
  /// The local calendar date the dark window belongs to, normalized to local
  /// noon (the noon-to-noon "night" bucketing rule used across the scheduler
  /// stack). Noon avoids the after-midnight ambiguity of which calendar day a
  /// pre-dawn dark hour belongs to.
  final DateTime nightDateLocal;

  /// Astronomical dusk (sun reaches -18 deg) in UTC, or null when there is no
  /// astronomical darkness this night (e.g. high-latitude summer) or the
  /// forecast is unavailable.
  final DateTime? astronomicalDuskUtc;

  /// Astronomical dawn (sun rises back past -18 deg) in UTC, or null under the
  /// same conditions as [astronomicalDuskUtc].
  final DateTime? astronomicalDawnUtc;

  /// Total hours of astronomical darkness in the night. Always `>= 0`.
  final double darkHours;

  /// Dark hours during which cloud cover is at or below the configured
  /// threshold. Clamped by construction to `[0, darkHours]`; never exceeds
  /// [darkHours].
  final double clearDarkHours;

  /// Mean cloud cover across the dark window, `0..1` (0 = clear, 1 = overcast).
  final double meanCloudCoverDuringDark;

  /// Project targets that clear their minimum altitude during the dark window,
  /// ranked descending by [ForecastTargetUp.upDarkHours] (most up-time first).
  final List<ForecastTargetUp> bestTargets;

  /// False when no forecast could be produced for this night. When false the
  /// numeric fields are all zero, [bestTargets] is empty, and
  /// [unavailableReason] explains why.
  final bool forecastAvailable;

  /// Human-readable reason the forecast is unavailable, or null when
  /// [forecastAvailable] is true. Surfaced to the operator — never swallowed.
  final String? unavailableReason;

  const NightForecast({
    required this.nightDateLocal,
    required this.astronomicalDuskUtc,
    required this.astronomicalDawnUtc,
    required this.darkHours,
    required this.clearDarkHours,
    required this.meanCloudCoverDuringDark,
    required this.bestTargets,
    this.forecastAvailable = true,
    this.unavailableReason,
  });

  /// Builds an explicitly-unavailable night for [nightDateLocal] carrying the
  /// honest [reason]. All numeric fields are zero, twilight times are null, and
  /// [bestTargets] is empty — there is no clear-sky default.
  const NightForecast.unavailable(this.nightDateLocal, String reason)
    : astronomicalDuskUtc = null,
      astronomicalDawnUtc = null,
      darkHours = 0,
      clearDarkHours = 0,
      meanCloudCoverDuringDark = 0,
      bestTargets = const [],
      forecastAvailable = false,
      unavailableReason = reason;

  /// Composite forecast score in `[0.0, 1.0]` used to rank nights.
  ///
  /// The base is the clear fraction of the dark window
  /// (`clearDarkHours / darkHours`), which is 0 when there is no darkness. That
  /// fraction is then gated by whether any project target is actually up: a
  /// night with no imageable target scores 0 no matter how clear it is, since
  /// there is nothing to point at. An unavailable night scores 0 (its
  /// [darkHours] is 0 by construction).
  double get score {
    if (darkHours <= 0.0) return 0.0;
    if (bestTargets.isEmpty) return 0.0;
    final ratio = clearDarkHours / darkHours;
    if (ratio < 0.0) return 0.0;
    if (ratio > 1.0) return 1.0;
    return ratio;
  }

  Map<String, dynamic> toJson() => {
    'nightDateLocal': nightDateLocal.toUtc().toIso8601String(),
    'astronomicalDuskUtc': astronomicalDuskUtc?.toUtc().toIso8601String(),
    'astronomicalDawnUtc': astronomicalDawnUtc?.toUtc().toIso8601String(),
    'darkHours': darkHours,
    'clearDarkHours': clearDarkHours,
    'meanCloudCoverDuringDark': meanCloudCoverDuringDark,
    'bestTargets': bestTargets.map((t) => t.toJson()).toList(),
    'forecastAvailable': forecastAvailable,
    'unavailableReason': unavailableReason,
    'score': score,
  };

  @override
  List<Object?> get props => [
    nightDateLocal,
    astronomicalDuskUtc,
    astronomicalDawnUtc,
    darkHours,
    clearDarkHours,
    meanCloudCoverDuringDark,
    bestTargets,
    forecastAvailable,
    unavailableReason,
  ];
}

/// A multi-night forecast lookahead — the ranked collection the planner's week
/// view renders.
///
/// Holds one [NightForecast] per upcoming night (available or not) and exposes
/// the single [bestNight] to highlight. When the whole lookahead cannot be
/// produced (e.g. the forecast feed is unreachable for every night) use
/// [WeekForecast.unavailable]; per-night unavailability is carried on the
/// individual [NightForecast]s instead. Pure derivation model; no persistence.
class WeekForecast extends Equatable {
  /// One entry per night in the lookahead, in chronological order. May contain
  /// a mix of available and unavailable nights.
  final List<NightForecast> nights;

  /// False only when the entire lookahead failed to build. Individual nights
  /// can still be unavailable while this is true.
  final bool available;

  /// Reason the whole lookahead is unavailable, or null when [available] is
  /// true. Surfaced to the operator — never swallowed.
  final String? unavailableReason;

  const WeekForecast({
    required this.nights,
    this.available = true,
    this.unavailableReason,
  });

  /// Builds an explicitly-unavailable week carrying the honest [reason], with
  /// no nights — there is no clear-sky default.
  const WeekForecast.unavailable(String reason)
    : nights = const [],
      available = false,
      unavailableReason = reason;

  /// The available night with the highest [NightForecast.score], or null when
  /// no night is available or no night scores above zero. Unavailable nights
  /// are ignored entirely; ties keep the earliest (first) qualifying night.
  ///
  /// The zero-score guard is what stops the week strip recommending a night.
  /// [NightForecast.score] is 0 for every night that has no darkness, no clear
  /// dark time, or no project target up — so with an empty project EVERY night
  /// scores 0 and the "keep the earliest on a tie" rule would star night one
  /// regardless of its weather, putting the "best night" marker on a fully
  /// clouded night while a clear one sits next to it. There is no best night
  /// when nothing is imageable on any of them; say so instead of guessing.
  NightForecast? get bestNight {
    NightForecast? best;
    for (final night in nights) {
      if (!night.forecastAvailable) continue;
      if (best == null || night.score > best.score) {
        best = night;
      }
    }
    if (best != null && best.score <= 0.0) return null;
    return best;
  }

  Map<String, dynamic> toJson() => {
    'nights': nights.map((n) => n.toJson()).toList(),
    'available': available,
    'unavailableReason': unavailableReason,
  };

  @override
  List<Object?> get props => [nights, available, unavailableReason];
}
