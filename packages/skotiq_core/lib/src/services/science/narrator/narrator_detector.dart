/// Detector contract for the Night Narrator.
///
/// A detector is *pure given* `(ctx, its own mutable rolling state)`. Each
/// detector owns whatever hysteresis / record-keeping state it needs (so a
/// trend event fires once on crossing and closes once on recovery, without
/// flapping). The engine ([NarratorEngine]) owns cross-detector concerns —
/// dedupe and per-eventType cooldowns — so detectors never have to.
///
/// Detectors MUST read `ctx.now` rather than `DateTime.now()`; that injected
/// clock is what makes their trend maths deterministic under test.
library;

import 'dart:math' as math;

import 'narrator_context.dart';
import 'narrator_event.dart';

/// One change/event/record detector. Stateful: `evaluate` may mutate fields on
/// the instance to remember what it has already reported.
abstract class NarratorDetector {
  /// Stable id (matches the `eventType` prefix family it emits).
  String get id;

  /// Evaluate the current context. Returns zero or more drafts; the engine
  /// applies dedupe + cooldown before persisting. Never throws on missing
  /// inputs — absent data means "nothing to report".
  List<NarratorEventDraft> evaluate(NarratorContext ctx);

  /// Reset rolling state (used between sessions / in tests).
  void reset() {}
}

/// Quantize [t] to a stable hour-bucket string (UTC, `yyyy-MM-ddTHH`) for use
/// in episode dedupe keys. Coarse-graining the timestamp makes a key
/// *episode-stable*: the same ongoing episode produces the same key within a
/// service lifetime and reproduces the same key after a relaunch (so the
/// DB-seeded dedupe set matches and the episode is not re-announced).
String narratorHourBucket(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)}T${two(u.hour)}';
}

/// Small numeric helpers shared by detectors. Pure, null-tolerant.
class NarratorStats {
  const NarratorStats._();

  /// Median of [values]; null when empty.
  static double? median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = values.toList(growable: false)..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// Arithmetic mean; null when empty.
  static double? mean(List<double> values) {
    if (values.isEmpty) return null;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  /// Sample standard deviation; null when fewer than two values.
  static double? stdDev(List<double> values) {
    if (values.length < 2) return null;
    final m = mean(values)!;
    var sumSq = 0.0;
    for (final v in values) {
      final d = v - m;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / (values.length - 1));
  }

  /// Ordinary-least-squares slope of [ys] against [xs] (same length, ≥2
  /// points). Units: y per x. Null when ill-conditioned.
  static double? slope(List<double> xs, List<double> ys) {
    if (xs.length != ys.length || xs.length < 2) return null;
    final mx = mean(xs)!;
    final my = mean(ys)!;
    var num = 0.0;
    var den = 0.0;
    for (var i = 0; i < xs.length; i++) {
      final dx = xs[i] - mx;
      num += dx * (ys[i] - my);
      den += dx * dx;
    }
    if (den.abs() < 1e-12) return null;
    return num / den;
  }
}
