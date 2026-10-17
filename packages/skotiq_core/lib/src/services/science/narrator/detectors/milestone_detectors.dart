/// Milestone detectors — severity `success`. The "personal bests" and
/// round-number achievements that make a night feel like progress.
library;

import '../narrator_context.dart';
import '../narrator_detector.dart';
import '../narrator_event.dart';

/// 4. `milestone.limiting_mag` — the first calibration of the night, and each
/// time `limitingMag5Sigma` beats the running session best by ≥ [beatBy] mag.
class LimitingMagDetector extends NarratorDetector {
  static const double beatBy = 0.2;

  double? _sessionBest;
  bool _announcedFirst = false;

  @override
  String get id => 'milestone.limiting_mag';

  @override
  void reset() {
    _sessionBest = null;
    _announcedFirst = false;
  }

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    if (ctx.calibrations.isEmpty) return const [];
    final latest = ctx.calibrations.last;
    final mag = latest.limitingMag5Sigma;
    if (mag == null || !mag.isFinite || !latest.isCalibrated) return const [];

    // First calibration of the night.
    if (!_announcedFirst) {
      _announcedFirst = true;
      _sessionBest = mag;
      return [
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.milestone,
          severity: NarratorSeverity.success,
          headline:
              "You're reaching magnitude ${mag.toStringAsFixed(1)} stars (5σ)",
          body:
              'First photometric calibration is in. Limiting magnitude is a '
              'good proxy for how faint tonight will go.',
          evidence: NarratorEvidence.scalar(
            value: mag,
            unit: 'mag',
            context: 'limiting (5σ)',
          ),
          dedupeKey: 'milestone.limiting_mag.first',
          capturedImageId: ctx.capturedImageId,
        ),
      ];
    }

    // New session best (deeper = larger limiting magnitude).
    final best = _sessionBest;
    if (best != null && mag >= best + beatBy) {
      _sessionBest = mag;
      return [
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.milestone,
          severity: NarratorSeverity.success,
          headline:
              'New depth record — magnitude ${mag.toStringAsFixed(1)} stars (5σ)',
          body:
              'Conditions or focus just improved your limiting magnitude by '
              '≥${beatBy.toStringAsFixed(1)} mag. Faint targets are in reach.',
          evidence: NarratorEvidence.delta(
            from: best,
            to: mag,
            unit: 'mag',
            direction: 'up',
          ),
          dedupeKey: 'milestone.limiting_mag.best:${mag.toStringAsFixed(2)}',
          capturedImageId: ctx.capturedImageId,
        ),
      ];
    }
    return const [];
  }
}

/// 5. `milestone.calibration_locked` — ≥ [minFrames] calibrated frames and the
/// zero-point std dev over the last [window] ≤ [maxZpStd] mag. Fires once.
class CalibrationLockedDetector extends NarratorDetector {
  static const int minFrames = 10;
  static const int window = 10;
  static const double maxZpStd = 0.05;

  bool _locked = false;

  @override
  String get id => 'milestone.calibration_locked';

  @override
  void reset() => _locked = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    if (_locked) return const [];
    final zps = ctx.calibrations
        .where((c) => c.isCalibrated && (c.zeroPoint?.isFinite ?? false))
        .map((c) => c.zeroPoint!)
        .toList(growable: false);
    if (zps.length < minFrames) return const [];

    final recent = zps.sublist(zps.length - window);
    final std = NarratorStats.stdDev(recent);
    if (std == null || std > maxZpStd) return const [];

    _locked = true;
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.milestone,
        severity: NarratorSeverity.success,
        headline:
            'Photometric calibration locked: ZP stable to ±${std.toStringAsFixed(2)}',
        body:
            'The zero point has settled across the last $window frames — your '
            'magnitudes are now trustworthy for science.',
        evidence: NarratorEvidence.scalar(
          value: std,
          unit: 'mag',
          context: 'ZP scatter (last $window)',
        ),
        dedupeKey: 'milestone.calibration_locked',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}

/// 6. `milestone.best_seeing` — a frame whose FWHM is in the best (lowest)
/// [bestFraction] of the session, once ≥ [minFrames] frames exist. Engine-level
/// cooldown keeps it to roughly once per [cooldown] window.
class BestSeeingDetector extends NarratorDetector {
  static const int minFrames = 20;
  static const double bestFraction = 0.05;
  static const Duration cooldown = Duration(minutes: 30);

  double? _bestSoFar;

  @override
  String get id => 'milestone.best_seeing';

  @override
  void reset() => _bestSoFar = null;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final fwhms = ctx.imageStats
        .map((s) => s.fwhm)
        .whereType<double>()
        .where((v) => v.isFinite && v > 0)
        .toList(growable: false);
    if (fwhms.length < minFrames) return const [];

    final latest = ctx.imageStats.last.fwhm;
    if (latest == null || !latest.isFinite || latest <= 0) return const [];

    // Threshold = the bestFraction-th percentile (lower is better).
    final sorted = fwhms.toList(growable: false)..sort();
    final idx = (sorted.length * bestFraction).floor().clamp(
      0,
      sorted.length - 1,
    );
    final threshold = sorted[idx];

    if (latest > threshold) return const [];
    // Only celebrate a genuine improvement over the previous best announced.
    if (_bestSoFar != null && latest >= _bestSoFar!) return const [];
    _bestSoFar = latest;

    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.milestone,
        severity: NarratorSeverity.success,
        headline:
            'Best seeing of the night — FWHM ${latest.toStringAsFixed(1)} px',
        body:
            'This frame is in the sharpest ${(bestFraction * 100).round()}% of '
            'the session. A great moment for your most detailed targets.',
        evidence: NarratorEvidence.scalar(
          value: latest,
          unit: 'px',
          context: 'session best FWHM',
        ),
        dedupeKey: 'milestone.best_seeing:${latest.toStringAsFixed(2)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}

/// 7. `milestone.integration` — accumulated integration per filter crossing a
/// whole-hour mark. Deduped per (filter, hour), so each hour is announced once.
class IntegrationMilestoneDetector extends NarratorDetector {
  @override
  String get id => 'milestone.integration';

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final out = <NarratorEventDraft>[];
    for (final entry in ctx.filterIntegration) {
      if (!entry.seconds.isFinite || entry.seconds <= 0) continue;
      final hours = entry.seconds ~/ 3600;
      if (hours < 1) continue;
      final target = entry.targetName;
      final onTarget = target != null ? ' on $target' : '';
      out.add(
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.milestone,
          severity: NarratorSeverity.success,
          headline:
              '$hours ${hours == 1 ? 'hour' : 'hours'} of ${entry.filter}'
              '$onTarget in the bag',
          body:
              'Total integration on this filter just crossed $hours h. Deep '
              'and getting deeper.',
          evidence: NarratorEvidence.scalar(
            value: hours.toDouble(),
            unit: 'h',
            context: '${entry.filter} integration',
          ),
          dedupeKey: 'milestone.integration:${entry.filter}:$hours',
          capturedImageId: ctx.capturedImageId,
        ),
      );
    }
    return out;
  }
}
