/// Discovery detectors — severity `celebrate`, pinned to the top of the feed.
///
/// These are the "genuinely exciting" events: a moving object, a light-curve
/// excursion (possible eclipse/transit), and a confirmed periodic signal.
library;

import '../narrator_context.dart';
import '../narrator_detector.dart';
import '../narrator_event.dart';

/// 1. `discovery.moving_object` — a new [MovingObjectCandidate] with confidence
/// ≥ [minConfidence]. Deduped per candidate id, so a candidate that persists
/// across frames is announced once.
///
/// Spam guard: on a satellite-rich tick this caps emissions to the top
/// [maxPerTick] candidates by confidence, and `discovery.moving_object` carries
/// a cooldown in [defaultNarratorCooldowns]. Note the cooldown means any
/// co-detected candidates beyond the first that survive the cap in a single
/// tick may be suppressed by the engine — acceptable: the highest-confidence
/// one still surfaces, and the rest remain on the Analytics science tab.
class MovingObjectDetector extends NarratorDetector {
  static const double minConfidence = 0.7;
  static const int maxPerTick = 3;

  @override
  String get id => 'discovery.moving_object';

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final out = <NarratorEventDraft>[];
    final candidates =
        ctx.movingObjects
            .where((c) => c.confidence >= minConfidence)
            .toList(growable: false)
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    for (final candidate in candidates.take(maxPerTick)) {
      final motion = candidate.motionArcsecPerMinute;
      final name = candidate.objectName;
      final motionText = '${motion.toStringAsFixed(1)}″/min';
      final headline = name != null
          ? 'Moving object detected — $name at $motionText'
          : 'Moving object detected — $motionText '
                '(${(candidate.confidence * 100).round()}% confidence)';
      out.add(
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.celebrate,
          headline: headline,
          body:
              'A source moved between frames. Review it on the Analytics '
              'science tab — it may be an asteroid, comet, or satellite.',
          evidence: NarratorEvidence.scalar(
            value: motion,
            unit: '″/min',
            context: 'apparent motion',
          ),
          dedupeKey: 'discovery.moving_object:${candidate.candidateId}',
          pinned: true,
          capturedImageId: ctx.capturedImageId,
        ),
      );
    }
    return out;
  }
}

/// 2. `discovery.lightcurve_event` — a rolling baseline (median of the last
/// ≥ [minBaselinePoints] points) deviates by > [sigmaThreshold]× the combined
/// uncertainty for ≥ [requiredConsecutive] consecutive points.
///
/// Hysteresis: once an excursion is announced it stays "open" and does not
/// re-fire; when the most recent point returns within [recoverSigma]× the
/// baseline uncertainty it closes with a calmer `info` event, and the detector
/// re-arms.
class LightCurveEventDetector extends NarratorDetector {
  static const int minBaselinePoints = 8;
  static const int maxBaselinePoints = 20;
  static const int requiredConsecutive = 3;
  static const double sigmaThreshold = 3.0;
  static const double recoverSigma = 1.0;

  bool _open = false;

  @override
  String get id => 'discovery.lightcurve_event';

  @override
  void reset() => _open = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    // Defensively ignore non-finite magnitudes (NaN / inf) so a junk point can
    // never masquerade as a giant excursion.
    final points = ctx.lightCurve
        .where((p) => p.differentialMagnitude.isFinite)
        .toList(growable: false);
    if (points.length < minBaselinePoints + requiredConsecutive) {
      return const [];
    }

    // Baseline = median magnitude over the points BEFORE the trailing window,
    // capped to the most recent [maxBaselinePoints] so a slow nightly trend
    // can't inflate the per-point deviations (rolling recent baseline, per spec).
    final tail = points.sublist(points.length - requiredConsecutive);
    final allBaselinePts = points.sublist(
      0,
      points.length - requiredConsecutive,
    );
    if (allBaselinePts.length < minBaselinePoints) return const [];
    final baselinePts = allBaselinePts.length > maxBaselinePoints
        ? allBaselinePts.sublist(allBaselinePts.length - maxBaselinePoints)
        : allBaselinePts;

    final baselineMags = baselinePts
        .map((p) => p.differentialMagnitude)
        .toList(growable: false);
    final baseline = NarratorStats.median(baselineMags)!;

    // Combined uncertainty: typical per-point sigma. Fall back to the scatter
    // of the baseline when per-point uncertainties are absent (all zero).
    final sigmas = baselinePts
        .map((p) => p.uncertainty)
        .where((u) => u.isFinite && u > 0)
        .toList(growable: false);
    var sigma = NarratorStats.median(sigmas) ?? 0.0;
    if (sigma <= 0) {
      sigma = NarratorStats.stdDev(baselineMags) ?? 0.0;
    }
    if (sigma <= 0) return const [];

    final lastDev = tail.last.differentialMagnitude - baseline;

    // Recovery / hysteresis: if open and we're back within recoverSigma, close.
    if (_open) {
      if (lastDev.abs() <= recoverSigma * sigma) {
        _open = false;
        return [
          NarratorEventDraft(
            eventType: id,
            category: NarratorCategory.discovery,
            severity: NarratorSeverity.info,
            headline:
                'Target brightness back to baseline (within '
                '${recoverSigma.toStringAsFixed(0)}σ)',
            body:
                'The light-curve excursion has recovered. Worth keeping the '
                'frames for follow-up if it was a transit.',
            evidence: NarratorEvidence.sparkline(
              points: points
                  .map((p) => p.differentialMagnitude)
                  .toList(growable: false),
              unit: 'mag',
            ),
            dedupeKey:
                'discovery.lightcurve_event.recovered:'
                '${narratorHourBucket(tail.last.timestamp)}',
            capturedImageId: ctx.capturedImageId,
          ),
        ];
      }
      return const [];
    }

    // Need every point in the trailing window to deviate in the same direction
    // beyond the threshold.
    final threshold = sigmaThreshold * sigma;
    final allUp = tail.every(
      (p) => (p.differentialMagnitude - baseline) > threshold,
    );
    final allDown = tail.every(
      (p) => (baseline - p.differentialMagnitude) > threshold,
    );
    if (!allUp && !allDown) return const [];

    _open = true;
    // In magnitudes, larger = fainter. allUp => faded; allDown => brightened.
    final faded = allUp;
    final magDelta = (tail.last.differentialMagnitude - baseline).abs();
    final headline = faded
        ? 'Your target faded ${magDelta.toStringAsFixed(2)} mag — possible '
              'eclipse/transit ingress'
        : 'Your target brightened ${magDelta.toStringAsFixed(2)} mag — '
              'possible outburst or flare';
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.discovery,
        severity: NarratorSeverity.celebrate,
        headline: headline,
        body:
            'A sustained ${faded ? 'dip' : 'rise'} over the last '
            '$requiredConsecutive points exceeds '
            '${sigmaThreshold.toStringAsFixed(0)}× the scatter. Keep imaging '
            'to capture the full event.',
        evidence: NarratorEvidence.delta(
          from: baseline,
          to: tail.last.differentialMagnitude,
          unit: 'mag',
          direction: faded ? 'down' : 'up',
        ),
        dedupeKey:
            'discovery.lightcurve_event:'
            '${narratorHourBucket(tail.first.timestamp)}',
        pinned: true,
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}

/// 3. `discovery.period_found` — a completed period analysis with Lomb-Scargle
/// FAP < [maxFap] or BLS SDE > [minSde].
class PeriodFoundDetector extends NarratorDetector {
  static const double maxFap = 0.01;
  static const double minSde = 7.0;

  @override
  String get id => 'discovery.period_found';

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final out = <NarratorEventDraft>[];
    for (final result in ctx.periodResults) {
      final fap = result.lombScargleFap;
      final sde = result.blsSde;
      final byFap = fap != null && fap.isFinite && fap < maxFap;
      final bySde = sde != null && sde.isFinite && sde > minSde;
      if (!byFap && !bySde) continue;

      final confidence =
          (byFap && (fap < maxFap / 10)) || (bySde && sde > minSde + 3)
          ? 'high confidence'
          : 'good confidence';
      out.add(
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.discovery,
          severity: NarratorSeverity.celebrate,
          headline:
              'Periodic signal found: ${result.periodDays.toStringAsFixed(3)} d '
              '($confidence)',
          body:
              'Phase-fold the light curve on the Analytics science tab to '
              'confirm the shape. Variable star or transit candidate.',
          evidence: NarratorEvidence.scalar(
            value: result.periodDays,
            unit: 'd',
            context: 'best period',
          ),
          dedupeKey:
              'discovery.period_found:${result.objectId}:${result.periodDays.toStringAsFixed(4)}',
          pinned: true,
          capturedImageId: ctx.capturedImageId,
        ),
      );
    }
    return out;
  }
}
