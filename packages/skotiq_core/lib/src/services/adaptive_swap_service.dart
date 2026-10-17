// Adaptive sky-conditions composer + Rust executor pusher.
//
// This service is the Dart counterpart of
// `crate::scheduling::adaptive_swap::pick_target_for_conditions` (Rust).
// It does NOT make scheduling decisions — that's the Rust scheduler's
// job. The service's role is:
//
//   1. Compose the composite ConditionsScore from the live transparency,
//      seeing (HFR-baseline proxy), cloud cover, and wind inputs.
//   2. Push that score into the running executor via the backend
//      abstraction, on a fixed cadence (every ~30s by default).
//   3. Pull the executor's `AdaptiveSwapSnapshot` for the Run Dashboard
//      panel.
//
// No silent fallbacks here: a missing axis is reported as
// `null` rather than as a fabricated mid-value. The composer then
// renormalises the weights over the *available* axes so the score
// remains 0..=100 instead of artificially deflating when wind data is
// unavailable.

import 'dart:async';
import 'dart:convert';

import '../models/sequence/sequence_models.dart';

/// Inputs the composer consumes. Each axis is optional: when `null` the
/// composer omits it from the weighted sum and renormalises the
/// remaining axes.
class AdaptiveSwapInputs {
  /// Live sky transparency as a fraction of clear-sky reference
  /// (0.0..=1.0, where 1.0 = perfectly clear). Source: science
  /// pipeline transparency sampler. `null` until the first reading.
  final double? transparencyFraction;

  /// Live HFR median (arcseconds) for the active filter. The composer
  /// translates HFR relative to the baseline HFR into a "seeing score"
  /// — bigger relative HFR => worse seeing. `null` when no baseline is
  /// established.
  final double? hfrMedian;

  /// Baseline HFR for the active filter (typically the median of the
  /// first N accepted frames). The composer normalises `hfrMedian /
  /// hfrBaseline` to produce a 0..=100 seeing score. `null` => seeing
  /// axis is treated as missing.
  final double? hfrBaseline;

  /// Live cloud cover percentage (0..=100). Higher = worse. Source:
  /// `cloudCoverPercentageProvider` (Open-Meteo merged with the
  /// cloud-motion analyzer). `null` => cloud axis is treated as
  /// missing.
  final double? cloudCoverPercent;

  /// Live wind speed (km/h). Higher = worse. Source: weather station
  /// (when available). `null` => wind axis is treated as missing.
  final double? windKph;

  const AdaptiveSwapInputs({
    this.transparencyFraction,
    this.hfrMedian,
    this.hfrBaseline,
    this.cloudCoverPercent,
    this.windKph,
  });

  /// True when at least one axis has data — otherwise the composer
  /// returns `null` (no fabricated score from zero inputs).
  bool get hasAnyAxis =>
      transparencyFraction != null ||
      (hfrMedian != null && hfrBaseline != null) ||
      cloudCoverPercent != null ||
      windKph != null;
}

/// Converts live app telemetry into the normalized input shape consumed by
/// [AdaptiveSwapService].
///
/// Kept pure so weather/science providers, tests, and future remote clients
/// share the same interpretation of "current conditions".
class AdaptiveSwapInputComposer {
  const AdaptiveSwapInputComposer._();

  static AdaptiveSwapInputs fromTelemetry({
    double? transparencyPercent,
    Iterable<double?> recentHfr = const [],
    double? hardwareCloudCoverPercent,
    double? apiCloudCoverPercent,
    double? windKph,
  }) {
    final hfrValues = recentHfr
        .whereType<double>()
        .where((value) => value.isFinite && value > 0)
        .toList(growable: false);
    final latestHfr = hfrValues.isEmpty ? null : hfrValues.last;

    return AdaptiveSwapInputs(
      transparencyFraction: transparencyPercent == null
          ? null
          : (transparencyPercent / 100.0).clamp(0.0, 1.5),
      hfrMedian: latestHfr,
      hfrBaseline: _hfrBaseline(hfrValues),
      cloudCoverPercent: hardwareCloudCoverPercent ?? apiCloudCoverPercent,
      windKph: windKph,
    );
  }

  static double? _hfrBaseline(List<double> hfrValues) {
    if (hfrValues.length < 2) return null;
    final baselineWindow = hfrValues.length <= 8
        ? hfrValues.take(hfrValues.length - 1)
        : hfrValues.skip(hfrValues.length - 9).take(8);
    final sorted = baselineWindow.toList()..sort();
    if (sorted.isEmpty) return null;
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }
}

/// Pure score-composition + executor-push driver. The decision logic
/// itself lives in the Rust `adaptive_swap` module — Dart's job is to
/// keep the inputs flowing and surface the executor's verdict back to
/// the UI.
class AdaptiveSwapService {
  final ConditionsScoreWeights _weights;
  ConditionsScoreWeights get weights => _weights;

  AdaptiveSwapService({
    ConditionsScoreWeights weights = const ConditionsScoreWeights(),
  }) : _weights = weights;

  /// Compose a [ConditionsScore] from the live inputs. Returns `null` when no
  /// axis has data — the executor then treats the score as "telemetry missing"
  /// and falls back to the ordinary scheduler ranking. `null` is the honest
  /// answer; a fabricated 50 is not.
  ConditionsScore? compose(AdaptiveSwapInputs inputs, {DateTime? now}) {
    if (!inputs.hasAnyAxis) return null;

    final t = inputs.transparencyFraction == null
        ? null
        : _transparencyAxisScore(inputs.transparencyFraction!);
    final s = (inputs.hfrMedian == null || inputs.hfrBaseline == null)
        ? null
        : _seeingAxisScore(
            hfr: inputs.hfrMedian!,
            baseline: inputs.hfrBaseline!,
          );
    final c = inputs.cloudCoverPercent == null
        ? null
        : _cloudAxisScore(inputs.cloudCoverPercent!);
    final w = inputs.windKph == null ? null : _windAxisScore(inputs.windKph!);

    // Build the weighted sum over only the available axes, renormalising
    // the weights so the composite stays 0..=100. The Rust side mirrors
    // the same renormalisation for parity.
    double weightedSum = 0;
    double weightTotal = 0;
    if (t != null) {
      weightedSum += t * _weights.transparencyWeight;
      weightTotal += _weights.transparencyWeight;
    }
    if (s != null) {
      weightedSum += s * _weights.seeingWeight;
      weightTotal += _weights.seeingWeight;
    }
    if (c != null) {
      weightedSum += c * _weights.cloudWeight;
      weightTotal += _weights.cloudWeight;
    }
    if (w != null) {
      weightedSum += w * _weights.windWeight;
      weightTotal += _weights.windWeight;
    }
    if (weightTotal <= 0) return null;

    final score = (weightedSum / weightTotal).clamp(0.0, 100.0);

    return ConditionsScore(
      score: score,
      transparencyScore: t,
      seeingScore: s,
      cloudScore: c,
      windScore: w,
      weights: _weights,
      generatedAt: (now ?? DateTime.now().toUtc()).toUtc(),
    );
  }

  // Per-axis 0..=100 scorers

  /// Transparency: 1.0 => 100, 0.0 => 0. Linear in the operationally
  /// relevant 0..=1 band; values > 1.0 (rare but possible from photometric
  /// calibration noise) clamp to 100.
  double _transparencyAxisScore(double fraction) =>
      (fraction.clamp(0.0, 1.5) * 100.0).clamp(0.0, 100.0);

  /// Seeing proxy from rolling HFR: a 30% rise above baseline => degraded
  /// (≤ 50); 0% rise => 100; doubled HFR => 0. The piecewise mirrors
  /// the Rust port so Dart and Rust produce identical scores for the
  /// same inputs (parity check below).
  double _seeingAxisScore({required double hfr, required double baseline}) {
    if (baseline <= 0) return 50.0; // can't compute => neutral
    final ratio = hfr / baseline;
    if (ratio <= 1.0) return 100.0;
    if (ratio <= 1.15) return 90.0;
    if (ratio <= 1.30) return 70.0;
    if (ratio <= 1.50) return 50.0;
    if (ratio <= 1.80) return 30.0;
    if (ratio <= 2.0) return 15.0;
    return 0.0;
  }

  /// Cloud cover: 0% => 100, 100% => 0, with a generous mid-band so a
  /// hazy 30% night still counts as "fine".
  double _cloudAxisScore(double percent) {
    final p = percent.clamp(0.0, 100.0);
    if (p <= 10.0) return 100.0;
    if (p <= 30.0) return 90.0;
    if (p <= 50.0) return 70.0;
    if (p <= 70.0) return 50.0;
    if (p <= 85.0) return 30.0;
    return 10.0;
  }

  /// Wind: light breeze fine, gusts to ~50 km/h start hurting tracking
  /// for typical refractors / SCTs.
  double _windAxisScore(double kph) {
    if (kph <= 5.0) return 100.0;
    if (kph <= 15.0) return 90.0;
    if (kph <= 25.0) return 70.0;
    if (kph <= 40.0) return 50.0;
    if (kph <= 60.0) return 30.0;
    return 10.0;
  }
}

/// Backend-agnostic adapter for pushing the composed score into the
/// Rust executor and reading the dashboard snapshot back. Implemented
/// by `FfiBackend` (local Rust), `NetworkBackend` (remote control), and
/// `DisconnectedBackend` (clear not-connected failure).
abstract class AdaptiveSwapBackend {
  /// Push the composed score (or `null` to clear) to the executor's
  /// `ExecutorCommand::UpdateConditionsScore` handler.
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score);

  /// Pull the executor's current adaptive-swap snapshot for the Run
  /// Dashboard panel. Returns `null` when no telemetry has been pushed
  /// since startup.
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot();
}

/// Helper that builds an [AdaptiveSwapInputs] from common inputs +
/// composes a score + pushes it to the backend. Designed to be called
/// from a periodic timer in the imaging service.
class AdaptiveSwapDriver {
  final AdaptiveSwapService composer;
  final AdaptiveSwapBackend backend;

  /// Last composed score — exposed so tests can observe the most recent
  /// push without subscribing to the timer.
  ConditionsScore? lastPushed;

  AdaptiveSwapDriver({required this.composer, required this.backend});

  /// Compose + push. Returns the score that was sent (or `null` when
  /// no axis had data — backend receives `null` in that case so it can
  /// distinguish "no data" from "stale data").
  Future<ConditionsScore?> tick(
    AdaptiveSwapInputs inputs, {
    DateTime? now,
  }) async {
    final score = composer.compose(inputs, now: now);
    lastPushed = score;
    await backend.sequencerUpdateConditionsScore(score);
    return score;
  }

  /// Pull the dashboard snapshot. Convenience wrapper.
  Future<AdaptiveSwapSnapshot?> pullSnapshot() =>
      backend.sequencerGetAdaptiveSwapSnapshot();

  /// Decode a raw JSON string (as returned by
  /// `api_sequencer_get_adaptive_swap_json`) into an
  /// [AdaptiveSwapSnapshot]. Surfaces parse errors as `null` (with a
  /// descriptive throw deferred to the caller via [error]) so a malformed
  /// snapshot doesn't crash the dashboard timer.
  static AdaptiveSwapSnapshot? decodeSnapshotJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        return AdaptiveSwapSnapshot.fromJson(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
