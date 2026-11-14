// Presentation helpers for the "Your Sky" atlas surface. Pure formatting — no
// DateTime.now() or other ambient state lives here (callers pass any "now").

import 'dart:math' as math;

import 'package:skotiq_astro/format.dart';

String formatCenter(double raDeg, double decDeg) =>
    '${CoordinateFormat.raCompactFromDegrees(raDeg)} · ${CoordinateFormat.decCompact(decDeg)}';

/// A relative "deeper than" growth phrase comparing the integration gained in
/// the most recent window against the prior comparable window.
///
/// [recentSeconds] is the integration added in the latest period (e.g. the last
/// session/day); [priorSeconds] is what existed before it. Returns null when
/// there is nothing meaningful to say (no recent growth).
String? formatGrowthDelta({
  required double recentSeconds,
  required double priorSeconds,
  String period = 'yesterday',
}) {
  if (!recentSeconds.isFinite || recentSeconds <= 0) return null;
  final deeper = DurationFormat.decimalHours(recentSeconds);
  if (priorSeconds <= 0) {
    return '$deeper of first light';
  }
  return '$deeper deeper than $period';
}

/// Coverage depth expressed as an approximate frame-equivalent count, for the
/// heat label. [coverageMean] is the mean per-pixel sample count the bridge
/// reports; we surface it rounded to a readable integer.
String formatCoverageDepth(double coverageMean) {
  if (!coverageMean.isFinite || coverageMean <= 0) return '0×';
  if (coverageMean >= 10) return '${coverageMean.round()}×';
  return '${coverageMean.toStringAsFixed(1)}×';
}

/// A 0..1 normalized depth for a tile relative to the deepest tile in a set,
/// using a perceptual (sqrt) ramp so shallow tiles are still visible.
double normalizedDepth(double seconds, double maxSeconds) {
  if (maxSeconds <= 0 || !seconds.isFinite || seconds <= 0) return 0.0;
  final ratio = (seconds / maxSeconds).clamp(0.0, 1.0);
  return math.sqrt(ratio);
}
