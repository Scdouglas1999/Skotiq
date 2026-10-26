/// Conditions detectors — severity by direction (improving `success`,
/// degrading `warning`). These narrate the sky: transparency trends, darkening,
/// the clouds-vs-focus disambiguation, and exceptional windows.
library;

import 'dart:math' as math;

import '../narrator_context.dart';
import '../narrator_detector.dart';
import '../narrator_event.dart';

/// 8. `conditions.transparency_trend` — a linear trend of transparency percent
/// over the last [windowMinutes] beyond ±[deltaThreshold] points.
///
/// Hysteresis: fires once when the trend crosses the threshold; while "open" it
/// does not re-fire; it closes (re-arms) when the trend falls back under
/// [recoverThreshold] points, so a drifting transparency reading can't flap.
class TransparencyTrendDetector extends NarratorDetector {
  static const double windowMinutes = 45.0;
  static const double minWindowMinutes = 30.0;
  static const double deltaThreshold = 8.0;
  static const double recoverThreshold = 4.0;

  /// `0` armed, `1` open-improving, `-1` open-degrading.
  int _state = 0;

  @override
  String get id => 'conditions.transparency_trend';

  @override
  void reset() => _state = 0;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final cutoff = ctx.now.subtract(
      Duration(seconds: (windowMinutes * 60).round()),
    );
    final window = ctx.transparency
        .where((p) => !p.timestamp.isBefore(cutoff))
        .toList(growable: false);
    if (window.length < 3) return const [];

    final spanMinutes =
        window.last.timestamp.difference(window.first.timestamp).inSeconds /
        60.0;
    if (spanMinutes < minWindowMinutes) return const [];

    // Predicted change over the window = slope (pts/min) × span.
    final xs = window
        .map(
          (p) =>
              p.timestamp.difference(window.first.timestamp).inSeconds / 60.0,
        )
        .toList(growable: false);
    final ys = window.map((p) => p.transparencyPercent).toList(growable: false);
    final slope = NarratorStats.slope(xs, ys);
    if (slope == null) return const [];
    final change = slope * spanMinutes;

    // Recovery / re-arm.
    if (_state != 0) {
      if (change.abs() < recoverThreshold) {
        _state = 0;
      }
      return const [];
    }

    if (change.abs() < deltaThreshold) return const [];

    final improving = change > 0;
    _state = improving ? 1 : -1;

    // Only measured extinctions of one filter are comparable.
    final comparable =
        window.first.extinctionMeasured &&
        window.last.extinctionMeasured &&
        window.first.filter == window.last.filter;
    final extinctionDelta = comparable
        ? (window.last.extinctionCoefficient -
                  window.first.extinctionCoefficient)
              .abs()
        : double.nan;
    final extinctionNote = extinctionDelta.isFinite && extinctionDelta > 0.001
        ? ' (extinction ${improving ? 'down' : 'up'} '
              '${extinctionDelta.toStringAsFixed(2)} mag/airmass)'
        : '';
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.conditions,
        severity: improving
            ? NarratorSeverity.success
            : NarratorSeverity.warning,
        headline: improving
            ? 'Transparency improving — up ${change.abs().toStringAsFixed(0)} '
                  'points over the last ${spanMinutes.round()} min$extinctionNote'
            : 'Transparency dropping — down ${change.abs().toStringAsFixed(0)} '
                  'points over the last ${spanMinutes.round()} min$extinctionNote',
        body: improving
            ? 'The sky is clearing. A good time to push fainter targets or '
                  'narrowband filters.'
            : 'Haze or thin cloud is building. Expect more frame-to-frame '
                  'scatter; consider stacking only the best windows.',
        evidence: NarratorEvidence.sparkline(
          points: ys,
          unit: '%',
          direction: improving ? 'up' : 'down',
        ),
        dedupeKey:
            'conditions.transparency_trend:${improving ? 'up' : 'down'}:'
            '${narratorHourBucket(window.first.timestamp)}',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}

/// 9. `conditions.sky_darkness` — a *relative* sky-brightness change, measured
/// from the light-frame background normalized by exposure (ADU/s).
///
/// The samples are not absolutely calibrated, so this reports a *change* in
/// mag (Pogson, Δmag = 2.5·log₁₀(rateEarly/rateLate)), never an absolute
/// mag/arcsec². To keep the comparison honest it is **filter-aware**: samples
/// are grouped by filter and only the busiest filter with ≥3 samples is
/// compared, so an L→Ha filter change (which swings the background by
/// magnitudes) cannot masquerade as the sky darkening. The early/late rates use
/// the median of the first/last three samples of that filter for robustness.
///
/// Fires once per direction crossing of ±[magThreshold].
class SkyDarknessDetector extends NarratorDetector {
  static const double magThreshold = 0.3;

  bool _firedDarkening = false;
  bool _firedBrightening = false;

  @override
  String get id => 'conditions.sky_darkness';

  @override
  void reset() {
    _firedDarkening = false;
    _firedBrightening = false;
  }

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final samples = ctx.skySamples;
    if (samples.length < 3) return const [];

    // Group by filter, then pick the filter with the most samples (≥3).
    final byFilter = <String, List<NarratorSkySample>>{};
    for (final s in samples) {
      if (!s.aduPerSecond.isFinite || s.aduPerSecond <= 0) continue;
      byFilter.putIfAbsent(s.filter ?? '', () => []).add(s);
    }
    List<NarratorSkySample>? chosen;
    for (final group in byFilter.values) {
      if (group.length < 3) continue;
      if (chosen == null || group.length > chosen.length) chosen = group;
    }
    if (chosen == null) return const [];

    final early = NarratorStats.median(
      chosen.take(3).map((s) => s.aduPerSecond).toList(growable: false),
    );
    final late = NarratorStats.median(
      chosen
          .sublist(chosen.length - 3)
          .map((s) => s.aduPerSecond)
          .toList(growable: false),
    );
    if (early == null || late == null || early <= 0 || late <= 0) {
      return const [];
    }

    // Pogson: positive = darker (background rate fell).
    final change = 2.5 * (math.log(early / late) / math.ln10);
    if (!change.isFinite) return const [];

    if (change >= magThreshold && !_firedDarkening) {
      _firedDarkening = true;
      return [
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.conditions,
          severity: NarratorSeverity.success,
          headline:
              'Sky darkened ${change.toStringAsFixed(1)} mag — '
              'fainter targets now in reach',
          body:
              'The measured sky background has fallen as twilight cleared or '
              'the Moon set — a relative drop, not an absolute SQM reading. '
              'Great window for low-surface-brightness objects.',
          evidence: NarratorEvidence.scalar(
            value: change,
            unit: 'mag',
            context: 'sky brightness change (${chosen.first.filter ?? '—'})',
          ),
          dedupeKey: 'conditions.sky_darkness.darker',
          capturedImageId: ctx.capturedImageId,
        ),
      ];
    }
    if (change <= -magThreshold && !_firedBrightening) {
      _firedBrightening = true;
      return [
        NarratorEventDraft(
          eventType: id,
          category: NarratorCategory.conditions,
          severity: NarratorSeverity.warning,
          headline:
              'Sky brightened ${change.abs().toStringAsFixed(1)} mag — '
              'dawn or the Moon is encroaching',
          body:
              'The measured sky background is rising — a relative change, not '
              'an absolute SQM reading. Faint targets will start to struggle; '
              'favour brighter ones.',
          evidence: NarratorEvidence.scalar(
            value: change,
            unit: 'mag',
            context: 'sky brightness change (${chosen.first.filter ?? '—'})',
          ),
          dedupeKey: 'conditions.sky_darkness.brighter',
          capturedImageId: ctx.capturedImageId,
        ),
      ];
    }
    return const [];
  }
}

/// 10. `conditions.clouds_vs_focus` — explains a star-count collapse in one
/// filter (the newest frame keeps less than [1 - countDropFraction] of the
/// median of that filter's recent frames):
///   * transparency samples falling or the weather layer reporting cloud →
///     **clouds**;
///   * sky background down [backgroundDropFraction] or more with it →
///     **something blocking the view** (trees, a roof, dew);
///   * HFR up [hfrRiseFraction] or more while measured transparency held →
///     **focus drift**; with no transparency or weather data the card only
///     states what was measured.
/// Frames the frame watch already explained (off target, obstructed) and
/// frames rejected for star shape (trailing) stay silent. Fires once per
/// episode (re-arms when the filter's star count recovers).
class CloudsVsFocusDetector extends NarratorDetector {
  static const double countDropFraction = 0.40;
  static const double hfrRiseFraction = 0.15;
  static const double backgroundDropFraction = 0.30;
  static const int medianWindow = 10;
  static const int minPriorFrames = 3;

  bool _open = false;

  @override
  String get id => 'conditions.clouds_vs_focus';

  @override
  void reset() => _open = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    final stats = ctx.imageStats;
    if (stats.isEmpty) return const [];
    final latest = stats.last;
    final latestCount = latest.starCount;
    if (latestCount == null) return const [];

    final prior = stats
        .sublist(0, stats.length - 1)
        .where(
          (s) =>
              s.filter == latest.filter &&
              s.accepted &&
              !s.offTarget &&
              !s.obstructed,
        )
        .toList(growable: false);
    final reference = prior.sublist(
      (prior.length - medianWindow).clamp(0, prior.length),
    );
    final counts = reference
        .map((s) => s.starCount?.toDouble())
        .whereType<double>()
        .toList(growable: false);
    if (counts.length < minPriorFrames) return const [];
    final medianCount = NarratorStats.median(counts)!;
    if (medianCount <= 0) return const [];

    final drop = (medianCount - latestCount) / medianCount;

    // Re-arm once the star count recovers above the rolling median.
    if (_open) {
      if (latestCount >= medianCount) _open = false;
      return const [];
    }
    if (drop < countDropFraction) return const [];

    // The frame watch already reported these, with the right cause.
    if (latest.offTarget || latest.obstructed) return const [];
    final reason = latest.rejectionReason?.toLowerCase() ?? '';
    if (reason.contains('eccentric') ||
        reason.contains('trail') ||
        reason.contains('tracking')) {
      return const [];
    }

    final measuredTransparency = _transparencyTrend(ctx);
    final cloudy = ctx.weather?.cloudy ?? false;

    double? ratioOf(double? value, Iterable<double?> refs) {
      final base = NarratorStats.median(
        refs
            .whereType<double>()
            .where((v) => v.isFinite && v > 0)
            .toList(growable: false),
      );
      if (value == null || base == null || base <= 0) return null;
      return value / base;
    }

    final bgRatio = ratioOf(
      latest.backgroundPerSecond,
      reference.map((s) => s.backgroundPerSecond),
    );
    final hfrRatio = ratioOf(latest.hfr, reference.map((s) => s.hfr));
    final bgDropped =
        bgRatio != null && bgRatio <= 1.0 - backgroundDropFraction;
    final hfrRose = hfrRatio != null && hfrRatio - 1.0 >= hfrRiseFraction;

    final dropPct = (drop * 100).round();
    final filterLabel = latest.filter == null || latest.filter!.isEmpty
        ? ''
        : ' in ${latest.filter}';
    final evidence = NarratorEvidence.scalar(
      value: dropPct.toDouble(),
      unit: '%',
      context: 'star-count drop$filterLabel',
    );
    String key(String kind) =>
        'conditions.clouds_vs_focus.$kind:'
        '${narratorHourBucket(latest.timestamp)}';

    NarratorEventDraft draft(String kind, String headline, String body) {
      _open = true;
      return NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.conditions,
        severity: NarratorSeverity.warning,
        headline: headline,
        body: body,
        evidence: evidence,
        dedupeKey: key(kind),
        capturedImageId: ctx.capturedImageId,
      );
    }

    if (measuredTransparency == _Trend.falling || cloudy) {
      return [
        draft(
          'clouds',
          'Star count collapsed $dropPct%$filterLabel with '
              '${cloudy ? 'clouds reported' : 'transparency falling'} — '
              'clouds, not focus',
          'The thinning is atmospheric. Keep the rig as-is; frames will '
              'recover when the cloud passes.',
        ),
      ];
    }
    if (bgDropped) {
      final bgPct = ((1.0 - bgRatio) * 100).round();
      return [
        draft(
          'blocked',
          'Star count down $dropPct% and sky background down $bgPct%'
              '$filterLabel — something may be blocking the view',
          'Fewer stars on a darker sky usually means part of the beam is '
              'blocked: trees or a building as the target sinks, a roof, or '
              'dew on the optics. Refocusing will not help.',
        ),
      ];
    }
    if (hfrRose && measuredTransparency == _Trend.steady) {
      return [
        draft(
          'focus',
          'Star count dropped $dropPct%$filterLabel with transparency steady '
              'and HFR up — looks like focus drift, not clouds',
          'Measured transparency held but the stars softened. Run an '
              'autofocus before more frames blur.',
        ),
      ];
    }
    if (hfrRose) {
      final hfrPct = ((hfrRatio - 1.0) * 100).round();
      return [
        draft(
          'measured',
          'Star count down $dropPct% and HFR up $hfrPct%$filterLabel',
          'There is no transparency or weather data to tell cloud from '
              'focus. Look at the latest frame: soft but evenly spread '
              'stars point at focus, a dim or patchy field at cloud.',
        ),
      ];
    }
    return const [];
  }

  /// Transparency trend over the last 15 minutes, or [_Trend.unknown] when
  /// fewer than three samples cover that window.
  _Trend _transparencyTrend(NarratorContext ctx) {
    final cutoff = ctx.now.subtract(const Duration(minutes: 15));
    final recent = ctx.transparency
        .where((p) => !p.timestamp.isBefore(cutoff))
        .toList(growable: false);
    if (recent.length < 3) return _Trend.unknown;
    final xs = <double>[];
    final ys = <double>[];
    for (final p in recent) {
      xs.add(p.timestamp.difference(recent.first.timestamp).inSeconds / 60.0);
      ys.add(p.transparencyPercent);
    }
    final slope = NarratorStats.slope(xs, ys);
    if (slope == null) return _Trend.unknown;
    return slope < -0.2 ? _Trend.falling : _Trend.steady;
  }
}

enum _Trend { unknown, steady, falling }

/// 11. `conditions.excellent` — transparency > [threshold]% sustained for ≥
/// [sustainMinutes]. Once per session.
class ExcellentTransparencyDetector extends NarratorDetector {
  static const double threshold = 90.0;
  static const double sustainMinutes = 20.0;

  bool _fired = false;

  @override
  String get id => 'conditions.excellent';

  @override
  void reset() => _fired = false;

  @override
  List<NarratorEventDraft> evaluate(NarratorContext ctx) {
    if (_fired) return const [];
    final t = ctx.transparency;
    if (t.length < 2) return const [];

    // Consider points within the last 2×sustainMinutes, then take the TRAILING
    // run of consecutive points all above the threshold. The window has to be
    // wider than sustainMinutes: one bounded by a sustainMinutes cutoff can
    // never *span* sustainMinutes, so it could never fire.
    final cutoff = ctx.now.subtract(
      Duration(seconds: (2 * sustainMinutes * 60).round()),
    );
    final window = t.where((p) => !p.timestamp.isBefore(cutoff)).toList();
    if (window.length < 2) return const [];

    // Walk back from the newest point while it stays above threshold.
    var startIdx = window.length;
    for (var i = window.length - 1; i >= 0; i--) {
      if (window[i].transparencyPercent > threshold) {
        startIdx = i;
      } else {
        break;
      }
    }
    final run = window.sublist(startIdx);
    if (run.length < 2) return const [];
    final span =
        run.last.timestamp.difference(run.first.timestamp).inSeconds / 60.0;
    if (span < sustainMinutes) return const [];

    _fired = true;
    final avg = NarratorStats.mean(
      run.map((p) => p.transparencyPercent).toList(growable: false),
    )!;
    return [
      NarratorEventDraft(
        eventType: id,
        category: NarratorCategory.conditions,
        severity: NarratorSeverity.success,
        headline:
            'Exceptional transparency right now — a great window for your '
            'faintest filters',
        body:
            'Transparency has held above ${threshold.round()}% for '
            '${span.round()} min. Push the dim stuff while it lasts.',
        evidence: NarratorEvidence.scalar(
          value: avg,
          unit: '%',
          context: 'sustained transparency',
        ),
        dedupeKey: 'conditions.excellent',
        capturedImageId: ctx.capturedImageId,
      ),
    ];
  }
}
