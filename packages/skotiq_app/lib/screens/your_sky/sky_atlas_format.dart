// Presentation helpers for the "Your Sky" atlas surface. Pure formatting — no
// DateTime.now() or other ambient state lives here (callers pass any "now").

import 'dart:math' as math;

import 'package:skotiq_core/skotiq_core.dart';

/// Format an integration duration (seconds) as a compact human string:
/// `45s`, `12m`, `3.2h`, `41h`. Negative / non-finite inputs clamp to `0s`.
String formatIntegration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '0s';
  if (seconds < 60) return '${seconds.round()}s';
  final minutes = seconds / 60.0;
  if (minutes < 60) return '${minutes.round()}m';
  final hours = seconds / 3600.0;
  if (hours < 10) return '${hours.toStringAsFixed(1)}h';
  return '${hours.round()}h';
}

/// Format an RA in degrees as `HHh MMm` (sexagesimal hours).
String formatRaDeg(double raDeg) => CoordinateFormat.raHmFromDegrees(
      raDeg,
      style: SexagesimalStyle.leadPlainLetters,
      minutes: MinutesPrecision.rounded,
    );

/// Format a Dec in degrees as `+DD° MM'` with an explicit sign.
String formatDecDeg(double decDeg) => CoordinateFormat.decDm(
      decDeg,
      style: SexagesimalStyle.leadPlainLetters,
      minutes: MinutesPrecision.rounded,
    );

/// `RA · Dec` coordinate label for a region/tile centre.
String formatCenter(double raDeg, double decDeg) =>
    '${formatRaDeg(raDeg)} · ${formatDecDeg(decDeg)}';

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
  final deeper = formatIntegration(recentSeconds);
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

/// A user-facing message for an atlas read error, trimmed of the bridge's
/// envelope noise so the empty-state body stays readable.
String describeAtlasError(Object error) {
  final raw = error.toString();
  const prefix = 'Exception: ';
  final trimmed = raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
  return trimmed.isEmpty ? 'Unknown error.' : trimmed;
}
