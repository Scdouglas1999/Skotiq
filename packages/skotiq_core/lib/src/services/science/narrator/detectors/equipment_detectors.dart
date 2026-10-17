/// Equipment detectors — severity `warning`, escalating to `critical` at the
/// higher band. Tilt, focus drift, edge gradients, and guiding degradation.
library;

import 'dart:math' as math;

import '../narrator_context.dart';
import '../narrator_detector.dart';
import '../narrator_event.dart';

/// 12. `equipment.tilt` — `OpticalTrainDiagnostics.tiltScore` crossing the warn
/// ([warnScore]) / critical ([criticalScore]) bands. Once per band per session.
class TiltDetector extends NarratorDetector {
  static const double warnScore = 18.0;
  static const double criticalScore = 30.0;

  bool _firedWarn = false;
  bool _firedCritical = false;

  @override
  String get id => 'equipment.tilt';

  @override
  void reset() {
    _firedWarn = false;
    _firedCritical = false;
  }

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final diag = ctx.diagnostics;
    if (diag == null) return const [];
    final score = diag.tiltScore;
    if (!score.isFinite) return const [];
    final direction = diag.dominantTiltDirection;

    if (score >= criticalScore && !_firedCritical) {
      _firedCritical = true;
      _firedWarn = true; // a critical subsumes the warn band
      return [
        _draft(ctx, NarratorSeverity.critical, 'critical', direction, score),
      ];
    }
    if (score >= warnScore && !_firedWarn) {
      _firedWarn = true;
      return [_draft(ctx, NarratorSeverity.warning, 'warn', direction, score)];
    }
    return const [];
  }

  NarratorEventDraft _draft(
    NarratorContext ctx,
    NarratorSeverity severity,
    String band,
    String direction,
    double score,
  ) {
    final dirLabel = direction.isEmpty ? 'one corner' : 'the $direction corner';
    final bandLabel = severity == NarratorSeverity.critical
        ? 'critical'
        : 'elevated';
    // tiltScore is an abstract asymmetry index, not a percentage of anything —
    // report the score itself rather than fabricating a "% softer" figure.
    return NarratorEventDraft(
      eventType: id,
      category: NarratorCategory.equipment,
      severity: severity,
      headline:
          'Stars toward $dirLabel are noticeably softer — tilt score '
          '${score.round()} ($bandLabel)',
      body:
          'The PSF map is asymmetric across the field (tilt score '
          '${score.round()}). Open Diagnostics to inspect the tilt and adjust '
          'the tilt plate.',
      evidence: NarratorEvidence.vector(
        // Magnitude is just the arrow length (score/100, clamped), not a stat.
        directionDeg: _directionToDegrees(direction),
        magnitude: (score / 100.0).clamp(0.0, 1.0),
        label: direction.isEmpty ? null : '$direction corner',
      ),
      dedupeKey: 'equipment.tilt:$band',
      capturedImageId: ctx.capturedImageId,
    );
  }

  /// Map a compass-ish direction label to degrees (0 = N, clockwise). Unknown
  /// labels fall back to 0.
  static double _directionToDegrees(String dir) {
    switch (dir.toUpperCase()) {
      case 'N':
        return 0;
      case 'NE':
        return 45;
      case 'E':
        return 90;
      case 'SE':
        return 135;
      case 'S':
        return 180;
      case 'SW':
        return 225;
      case 'W':
        return 270;
      case 'NW':
        return 315;
      default:
        return 0;
    }
  }
}

/// 13. `equipment.focus_drift` — rolling-median HFR ≥ [riseFraction] above the
/// post-autofocus baseline, sustained ≥ [sustainMinutes]. Mentions the focuser
/// temperature delta when available. Re-arms when HFR returns near baseline.
class FocusDriftDetector extends NarratorDetector {
  static const double riseFraction = 0.10;
  static const double sustainMinutes = 15.0;
  static const int medianWindow = 5;

  DateTime? _aboveSince;
  bool _open = false;

  @override
  String get id => 'equipment.focus_drift';

  @override
  void reset() {
    _aboveSince = null;
    _open = false;
  }

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final baseline = ctx.autofocusHfrBaseline;
    if (baseline == null || !baseline.isFinite || baseline <= 0) {
      return const [];
    }

    final hfrs = ctx.imageStats
        .map((s) => s.hfr)
        .whereType<double>()
        .where((v) => v.isFinite && v > 0)
        .toList(growable: false);
    if (hfrs.length < medianWindow) return const [];
    final rollingHfr = NarratorStats.median(
      hfrs.sublist(hfrs.length - medianWindow),
    )!;

    final rise = (rollingHfr - baseline) / baseline;

    if (rise < riseFraction) {
      // Recovered (e.g. after a refocus): re-arm.
      _aboveSince = null;
      _open = false;
      return const [];
    }

    _aboveSince ??= ctx.now;
    final sustained =
        ctx.now.difference(_aboveSince!).inSeconds / 60.0 >= sustainMinutes;
    if (!sustained || _open) return const [];

    _open = true;
    final risePct = (rise * 100).round();

    // Temperature delta over the *drift* window (since HFR first went high),
    // not the whole session — the headline claims "over the same window".
    final temps = ctx.imageStats
        .where((s) => !s.timestamp.isBefore(_aboveSince!))
        .map((s) => s.focuserTempC)
        .whereType<double>()
        .where((t) => t.isFinite)
        .toList(growable: false);
    String tempNote = '';
    if (temps.length >= 2) {
      final delta = temps.last - temps.first;
      if (delta.abs() >= 0.5) {
        tempNote =
            ' while temperature ${delta < 0 ? 'fell' : 'rose'} '
            '${delta.abs().toStringAsFixed(1)} °C';
      }
    }

    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.equipment,
        severity: NarratorSeverity.warning,
        headline:
            'HFR up $risePct%$tempNote — likely focus drift; refocus soon',
        body:
            'Rolling HFR has stayed ≥${(riseFraction * 100).round()}% above the '
            'post-autofocus baseline for ${sustainMinutes.round()} min. A quick '
            'autofocus will sharpen things back up.',
        evidence: NarratorEvidence.delta(
          from: baseline,
          to: rollingHfr,
          unit: 'px',
          direction: 'up',
        ),
        dedupeKey: 'equipment.focus_drift:${narratorHourBucket(_aboveSince!)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}

/// Maps a math-convention gradient vector `(gx, gy)` (gy positive = toward the
/// bottom of a screen-y-down frame) to the compass bearing the UI's
/// `_VectorPainter` expects (0° = up/N, clockwise). So +x/right → 90° and
/// +y/screen-down → 180°. Exported for the unit test that pins this mapping.
double compassBearingForGradient(double gx, double gy) {
  return (math.atan2(gx, -gy) * 180 / math.pi + 360) % 360;
}

/// 14. `equipment.gradient` — `gradientX/Y` magnitude above [threshold] for ≥
/// [consecutive] consecutive frames. Fires once per episode.
class GradientDetector extends NarratorDetector {
  static const double threshold = 0.15;
  static const int consecutive = 5;

  bool _open = false;

  @override
  String get id => 'equipment.gradient';

  @override
  void reset() => _open = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final fq = ctx.frameQuality;
    if (fq.length < consecutive) return const [];

    final recent = fq.sublist(fq.length - consecutive);
    final allOver = recent.every((r) {
      final mag = math.sqrt(
        r.gradientX * r.gradientX + r.gradientY * r.gradientY,
      );
      return mag.isFinite && mag > threshold;
    });

    if (!allOver) {
      _open = false;
      return const [];
    }
    if (_open) return const [];
    _open = true;

    final last = recent.last;
    final mag = math.sqrt(
      last.gradientX * last.gradientX + last.gradientY * last.gradientY,
    );
    // The UI's _VectorPainter reads directionDeg as a compass bearing (0 = up,
    // clockwise) on a screen-y-down canvas. Convert from the math-convention
    // gradient vector so arrows point the right way: +x/right → 90°,
    // +y/screen-down → 180°. (Consistent with _edgeLabel: gy ≥ 0 = bottom.)
    final angle = compassBearingForGradient(last.gradientX, last.gradientY);
    final edge = _edgeLabel(last.gradientX, last.gradientY);

    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.equipment,
        severity: NarratorSeverity.warning,
        headline:
            'Persistent $edge gradient — check for stray light or a light-'
            'pollution dome',
        body:
            'A background gradient has held for $consecutive frames. Flats, a '
            'dew shield, or repositioning may help.',
        evidence: NarratorEvidence.vector(
          directionDeg: angle,
          magnitude: mag,
          label: '$edge edge',
        ),
        dedupeKey:
            'equipment.gradient:${narratorHourBucket(recent.first.timestamp)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }

  static String _edgeLabel(double gx, double gy) {
    if (gx.abs() >= gy.abs()) {
      return gx >= 0 ? 'right-edge' : 'left-edge';
    }
    return gy >= 0 ? 'bottom-edge' : 'top-edge';
  }
}

/// 15. `equipment.guiding_degraded` — guide RMS total ≥ [riseFraction] above the
/// session median, sustained. Re-arms when guiding recovers below the median.
class GuidingDegradedDetector extends NarratorDetector {
  static const double riseFraction = 0.50;
  static const int minSamples = 10;

  bool _open = false;

  @override
  String get id => 'equipment.guiding_degraded';

  @override
  void reset() => _open = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final history = ctx.guideRmsTotalHistory
        .where((v) => v.isFinite && v > 0)
        .toList(growable: false);
    if (history.length < minSamples) return const [];

    final median = NarratorStats.median(history)!;
    if (median <= 0) return const [];
    final latest = ctx.guideRmsTotal ?? history.last;
    final rise = (latest - median) / median;

    if (rise < riseFraction) {
      if (_open && latest <= median) _open = false;
      return const [];
    }
    if (_open) return const [];
    _open = true;

    final deltaArcsec = latest - median;
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.equipment,
        severity: NarratorSeverity.warning,
        headline:
            'Guiding RMS up ${deltaArcsec.toStringAsFixed(2)}″ — wind, balance, '
            'or seeing?',
        body:
            'Total RMS is ≥${(riseFraction * 100).round()}% above the session '
            'median. Check the guide graph for a runaway axis before stars '
            'start to elongate.',
        evidence: NarratorEvidence.delta(
          from: median,
          to: latest,
          unit: '″',
          direction: 'up',
        ),
        dedupeKey: 'equipment.guiding_degraded:${latest.toStringAsFixed(2)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}
