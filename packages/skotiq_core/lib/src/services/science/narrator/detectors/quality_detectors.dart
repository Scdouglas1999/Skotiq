/// Quality / pipeline detectors — severity `info`/`warning`. Clipping bursts,
/// auto-grader reject bursts, plate-solve collapse, and science-stage failures.
library;

import '../narrator_context.dart';
import '../narrator_detector.dart';
import '../narrator_event.dart';

/// 16. `quality.clipping` — high/low clip percent above [clipThreshold] for ≥
/// [consecutive] consecutive frames (one event, not per frame — subsumes the
/// insights-engine per-frame rule). Re-arms when clipping subsides.
class ClippingDetector extends NarratorDetector {
  static const double clipThreshold = 1.5;
  static const int consecutive = 5;

  bool _openHigh = false;
  bool _openLow = false;

  @override
  String get id => 'quality.clipping';

  @override
  void reset() {
    _openHigh = false;
    _openLow = false;
  }

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final fq = ctx.frameQuality;
    if (fq.length < consecutive) return const [];
    final recent = fq.sublist(fq.length - consecutive);

    final out = <NarratorEventDraft>[];

    final allHigh = recent.every((r) => r.highClipPercent > clipThreshold);
    if (allHigh) {
      if (!_openHigh) {
        _openHigh = true;
        final last = recent.last.highClipPercent;
        out.add(
          NarratorEventDraft(
            eventType: id,
            category: NarratorCategory.quality,
            severity: NarratorSeverity.warning,
            headline:
                'Highlights clipping ${last.toStringAsFixed(1)}% for '
                '$consecutive frames — burning in bright stars',
            body:
                'Reduce exposure or gain to protect star cores before more '
                'frames saturate.',
            evidence: NarratorEvidence.scalar(
              value: last,
              unit: '%',
              context: 'high clip',
            ),
            dedupeKey:
                'quality.clipping.high:${recent.first.timestamp.toIso8601String()}',
            capturedImageId: ctx.capturedImageId,
          ),
        );
      }
    } else {
      _openHigh = false;
    }

    final allLow = recent.every((r) => r.lowClipPercent > clipThreshold);
    if (allLow) {
      if (!_openLow) {
        _openLow = true;
        final last = recent.last.lowClipPercent;
        out.add(
          NarratorEventDraft(
            eventType: id,
            category: NarratorCategory.quality,
            severity: NarratorSeverity.info,
            headline:
                'Shadow clipping ${last.toStringAsFixed(1)}% for $consecutive '
                'frames — losing faint detail',
            body:
                'Lengthen exposures or relax the black point so dim signal '
                "isn't crushed.",
            evidence: NarratorEvidence.scalar(
              value: last,
              unit: '%',
              context: 'low clip',
            ),
            dedupeKey:
                'quality.clipping.low:${recent.first.timestamp.toIso8601String()}',
            capturedImageId: ctx.capturedImageId,
          ),
        );
      }
    } else {
      _openLow = false;
    }

    return out;
  }
}

/// 17. `quality.reject_burst` — ≥ [burstLength] consecutive auto-grader
/// rejects. Names the dominant cause from the reject reason strings. Re-arms
/// when a frame is accepted.
class RejectBurstDetector extends NarratorDetector {
  static const int burstLength = 3;

  bool _open = false;

  @override
  String get id => 'quality.reject_burst';

  @override
  void reset() => _open = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final events = ctx.gradeEvents;
    if (events.length < burstLength) return const [];

    // Count the trailing run of consecutive rejects.
    var run = 0;
    for (var i = events.length - 1; i >= 0; i--) {
      if (events[i].rejected) {
        run++;
      } else {
        break;
      }
    }

    if (run < burstLength) {
      // Most recent frame was accepted → re-arm.
      if (events.last.rejected == false) _open = false;
      return const [];
    }
    if (_open) return const [];
    _open = true;

    final tail = events.sublist(events.length - run);
    final cause = _dominantCause(tail);
    final causeNote = cause != null ? ' — all over the $cause' : '';
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.quality,
        severity: NarratorSeverity.warning,
        headline: '$run frames rejected in a row$causeNote',
        body:
            'The auto-grader is binning consecutive subs. Check focus, '
            'guiding, or transparency before more time is wasted.',
        evidence: NarratorEvidence.scalar(
          value: run.toDouble(),
          unit: 'frames',
          context: 'consecutive rejects',
        ),
        dedupeKey: 'quality.reject_burst:${tail.first.capturedImageId}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }

  /// Pick the most common metric named across the reject reasons (HFR, stars,
  /// guiding, FWHM, eccentricity). Returns a human label or null.
  static String? _dominantCause(List<NarratorGradeEvent> rejects) {
    final counts = <String, int>{};
    for (final r in rejects) {
      final reason = r.reason?.toLowerCase() ?? '';
      if (reason.contains('hfr')) {
        counts['HFR limit'] = (counts['HFR limit'] ?? 0) + 1;
      } else if (reason.contains('star')) {
        counts['star-count limit'] = (counts['star-count limit'] ?? 0) + 1;
      } else if (reason.contains('guid')) {
        counts['guiding limit'] = (counts['guiding limit'] ?? 0) + 1;
      } else if (reason.contains('fwhm')) {
        counts['FWHM limit'] = (counts['FWHM limit'] ?? 0) + 1;
      } else if (reason.contains('eccentric')) {
        counts['eccentricity limit'] = (counts['eccentricity limit'] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return null;
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }
}

/// 18. `quality.solve_drop` — plate-solve success rate over the last [window]
/// frames falls below [minRate] after previously being healthy
/// (≥ [healthyRate]). Fires once per episode; re-arms when the rate recovers.
class SolveDropDetector extends NarratorDetector {
  static const int window = 10;
  static const double minRate = 0.50;
  static const double healthyRate = 0.80;

  bool _wasHealthy = false;
  bool _open = false;

  @override
  String get id => 'quality.solve_drop';

  @override
  void reset() {
    _wasHealthy = false;
    _open = false;
  }

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final history = ctx.solveHistory;
    if (history.length < window) return const [];
    final recent = history.sublist(history.length - window);
    final solved = recent.where((s) => s).length;
    final rate = solved / recent.length;

    if (rate >= healthyRate) {
      _wasHealthy = true;
      _open = false;
      return const [];
    }
    if (rate >= minRate) {
      // Grey zone ([minRate, healthyRate)): hold. An open episode only re-arms
      // on a *fully* healthy rate (≥ healthyRate), handled by the branch above —
      // a grey-zone rate neither fires nor re-arms.
      return const [];
    }
    if (!_wasHealthy || _open) return const [];
    _open = true;

    final pct = (rate * 100).round();
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.quality,
        severity: NarratorSeverity.warning,
        headline: 'Plate-solving dropped to $pct% over the last $window frames',
        body:
            'Solves were healthy and have collapsed. Clouds, lost focus, or a '
            'mount slip can all cause it — check the field before science '
            'products stall.',
        evidence: NarratorEvidence.scalar(
          value: pct.toDouble(),
          unit: '%',
          context: 'solve rate (last $window)',
        ),
        dedupeKey: 'quality.solve_drop:${narratorHourBucket(ctx.now)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}

/// 19. `quality.pipeline_failure` — a science stage fails. Cooldown is applied
/// per stage type (via the engine's per-eventType cooldown keyed on the
/// stage-qualified eventType). Deduped on the stage + timestamp so the same
/// failure isn't re-announced across context rebuilds.
class PipelineFailureDetector extends NarratorDetector {
  String? _lastReportedKey;

  @override
  String get id => 'quality.pipeline_failure';

  @override
  void reset() => _lastReportedKey = null;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final failure = ctx.lastStageFailure;
    if (failure == null) return const [];

    // Episode-stable key: stage + hour bucket of the (reproducible) failure
    // timestamp. The same ongoing stage failure resolves to the same key
    // within a lifetime and after a relaunch, so the DB-seeded dedupe set
    // suppresses a duplicate card; the per-stage cooldown is the second gate.
    final key =
        'quality.pipeline_failure:${failure.stage.name}:'
        '${narratorHourBucket(failure.timestamp)}';
    if (key == _lastReportedKey) return const [];
    _lastReportedKey = key;

    return [
      NarratorEventDraft(
        // Qualify the eventType by stage so the engine cooldown is per-stage.
        eventType: '$id.${failure.stage.name}',
        category: NarratorCategory.quality,
        severity: NarratorSeverity.warning,
        headline: '${failure.stage.displayName} failed on the latest frame',
        body:
            failure.note ??
            'The capture itself is unaffected — only this science derivative '
                'failed. Check the science log if it persists.',
        dedupeKey: key,
        capturedImageId: failure.capturedImageId ?? ctx.capturedImageId,
      ),
    ];
  }
}
