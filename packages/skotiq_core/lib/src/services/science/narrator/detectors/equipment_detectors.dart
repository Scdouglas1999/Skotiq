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
    final bearing = tiltBearingForDirection(direction);
    final dirLabel = bearing == null ? 'one side' : 'the $direction';
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
      evidence: bearing == null
          ? NarratorEvidence.scalar(
              value: score,
              unit: '',
              context: 'tilt score',
            )
          : NarratorEvidence.vector(
              // Magnitude is just the arrow length (score/100, clamped), not
              // a stat.
              directionDeg: bearing,
              magnitude: (score / 100.0).clamp(0.0, 1.0),
              label: direction,
            ),
      dedupeKey: 'equipment.tilt:$band',
      capturedImageId: ctx.capturedImageId,
    );
  }
}

/// The arrow bearing (0° = up, clockwise, on the displayed frame) for the
/// side the optical-train diagnostics name: 'top edge', 'right edge',
/// 'bottom edge', 'left edge', or a corner such as 'top-left corner'. Null
/// for 'unknown' or an empty label, so no arrow is drawn for a side nobody
/// measured.
double? tiltBearingForDirection(String direction) {
  final d = direction.toLowerCase();
  final top = d.contains('top');
  final bottom = d.contains('bottom');
  final left = d.contains('left');
  final right = d.contains('right');
  final dy = top ? -1.0 : (bottom ? 1.0 : 0.0);
  final dx = right ? 1.0 : (left ? -1.0 : 0.0);
  if (dx == 0 && dy == 0) return null;
  return compassBearingForGradient(dx, dy);
}

/// 13. `equipment.focus_drift` — frame HFR [riseFraction] or more above
/// what each filter measured right after the last autofocus, sustained for
/// [sustainMinutes]. Mentions the focuser temperature change when known.
/// Re-arms when HFR returns near its post-autofocus level.
///
/// Each frame is compared with its own filter: the median of that filter's
/// first [baselineFrames] usable frames after the autofocus. The ratios of
/// the latest [medianWindow] usable frames, any filter, give the rise. The
/// autofocus sweep's own HFR is not the reference, because the sweep measures
/// a different population of stars in one filter. Rejected, off-target,
/// obstructed and starved or darkened frames are left out (see
/// [narratorFocusUsableFrames]), so trees, cloud and a lost target never read
/// as focus drift.
class FocusDriftDetector extends NarratorDetector {
  static const double riseFraction = 0.10;
  static const double sustainMinutes = 15.0;
  static const int baselineFrames = 2;
  static const int medianWindow = 5;
  static const int minRatios = 3;

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
    final afHfr = ctx.autofocusHfrBaseline;
    if (afHfr == null || !afHfr.isFinite || afHfr <= 0) {
      return const [];
    }
    final afAt = ctx.autofocusAt;
    final frames = narratorFocusUsableFrames(ctx.imageStats)
        .where(
          (s) =>
              (afAt == null || !s.timestamp.isBefore(afAt)) &&
              s.hfr != null &&
              s.hfr!.isFinite &&
              s.hfr! > 0,
        )
        .toList(growable: false);

    final baselineHfrs = <String, List<double>>{};
    final ratios = <double>[];
    double? lastBase;
    for (final f in frames) {
      final base = baselineHfrs[f.filter ?? ''] ??= <double>[];
      if (base.length < baselineFrames) {
        base.add(f.hfr!);
        continue;
      }
      final reference = NarratorStats.median(base)!;
      ratios.add(f.hfr! / reference);
      lastBase = reference;
    }
    if (ratios.length < minRatios) {
      // Not enough frames to tell; hold any open episode.
      return const [];
    }
    final rolling = NarratorStats.median(
      ratios.sublist((ratios.length - medianWindow).clamp(0, ratios.length)),
    )!;
    final rise = rolling - 1.0;

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
            'HFR up $risePct% since the last autofocus$tempNote — '
            'likely focus drift; refocus soon',
        body:
            'Frames have measured ≥${(riseFraction * 100).round()}% softer '
            'than the same filter right after the autofocus for '
            '${sustainMinutes.round()} min, with star count and sky background '
            'normal. A quick autofocus should sharpen things back up.',
        evidence: NarratorEvidence.delta(
          from: lastBase!,
          to: lastBase * rolling,
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

/// 15. `equipment.guiding_degraded` — settled guide RMS at least
/// [riseFactor] times its [baselineWindow] median, held for [sustain]. One
/// card per episode; re-arms once the RMS is back at or below the median.
///
/// Only settled readings reach the detector ([NarratorContext.guideSamples]),
/// so a dither offset, a guiding restart, autofocus or a flip never reads as
/// a rise. The number is stated in arcsec only when the guider reports its
/// pixel scale, otherwise in guide-camera pixels.
class GuidingDegradedDetector extends NarratorDetector {
  static const double riseFactor = 1.5;
  static const Duration baselineWindow = Duration(minutes: 30);
  static const Duration sustain = Duration(minutes: 3);
  static const int minBaselineSamples = 50;

  /// Readings pause for a few minutes around every dither; a longer silence
  /// means guiding stopped.
  static const Duration maxGap = Duration(minutes: 10);

  /// Beyond these the guider has lost hold of the star; wind or seeing do
  /// not move a guide star tens of pixels.
  static const double runawayFactor = 5.0;
  static const double runawayPx = 10.0;

  bool _open = false;

  @override
  String get id => 'equipment.guiding_degraded';

  @override
  void reset() => _open = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final samples = ctx.guideSamples
        .where((s) => s.rmsPx.isFinite && s.rmsPx > 0)
        .toList(growable: false);
    if (samples.isEmpty) return const [];
    final latest = samples.last;
    final cutoff = latest.timestamp.subtract(baselineWindow);
    final window = samples
        .where((s) => !s.timestamp.isBefore(cutoff))
        .map((s) => s.rmsPx)
        .toList(growable: false);
    if (window.length < minBaselineSamples) return const [];
    final median = NarratorStats.median(window)!;
    if (median <= 0) return const [];

    if (latest.rmsPx < riseFactor * median) {
      if (_open && latest.rmsPx <= median) _open = false;
      return const [];
    }
    if (_open) return const [];

    // The trailing run of readings that all stay above the limit. A gap
    // longer than [maxGap] (guiding stopped) ends the run: what came before
    // it was a different stretch of guiding.
    var runStart = latest.timestamp;
    final run = <double>[];
    for (var i = samples.length - 1; i >= 0; i--) {
      final s = samples[i];
      if (s.rmsPx < riseFactor * median ||
          s.timestamp.isBefore(cutoff) ||
          runStart.difference(s.timestamp) > maxGap) {
        break;
      }
      runStart = s.timestamp;
      run.add(s.rmsPx);
    }
    final held = latest.timestamp.difference(runStart);
    if (held < sustain) return const [];
    _open = true;

    final current = NarratorStats.median(run)!;
    final scale = ctx.guidePixelScaleArcsec;
    final hasScale = scale != null && scale.isFinite && scale > 0;
    final factor = hasScale ? scale : 1.0;
    final unit = hasScale ? '″' : ' px';
    String fmt(double px) => '${(px * factor).toStringAsFixed(2)}$unit';
    final minutes = held.inSeconds / 60.0;

    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.equipment,
        severity: NarratorSeverity.warning,
        headline:
            'Guiding RMS rose to ${fmt(current)} from ${fmt(median)} '
            'for ${minutes.round()} min',
        body: current >= runawayFactor * median || current >= runawayPx
            ? 'The guide star is wandering far from its lock position: '
                  'guiding is not holding it. The mount may have stopped '
                  'tracking, the guider calibration may not suit this side of '
                  'the pier, or the guide star is being lost behind cloud or '
                  'an obstruction.'
            : 'Total guide RMS has stayed at least ${riseFactor}x its '
                  '30-minute median for ${minutes.round()} min, outside '
                  'dithers and settling. Check the guide graph: a steady '
                  'drift on one axis usually points at balance or wind, a '
                  'noisy trace on both axes at seeing.',
        evidence: NarratorEvidence.delta(
          from: median * factor,
          to: current * factor,
          unit: hasScale ? '″' : 'px',
          direction: 'up',
        ),
        dedupeKey:
            'equipment.guiding_degraded:'
            '${runStart.toUtc().toIso8601String().substring(0, 16)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}
