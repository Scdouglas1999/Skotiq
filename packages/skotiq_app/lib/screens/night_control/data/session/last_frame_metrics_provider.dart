// Overview's "Last frame" block: the latest frame's numbers and how each
// compares with the night's median.
//
// The frame's own numbers come from `currentImageProvider` (the full
// ImageStats of the frame on screen). The medians come from wherever the
// night actually kept that metric: HFR, stars and background noise from the
// session's captured_images rows, FWHM, eccentricity, SNR and the median
// level only from the in-memory session list, which holds them on the host
// and not at all on a remote viewer. A metric the night has no median for
// shows its value with no delta; nothing is compared against a made-up
// baseline.

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart'
    show runDashboardActiveTargetProvider;
import '../../night_control_contracts.dart';
import 'session_format.dart';
import 'session_frames_provider.dart';

/// Which way is better for a metric.
enum _Better { lower, higher, neither }

/// A delta smaller than this share of the median is noise and stays neutral.
const double _improvementShare = 0.01;

/// A change for the worse beyond this share of the median is flagged.
const double _worseningShare = 0.10;

MetricVm _metric(
  String key, {
  required double? value,
  required double? median,
  required int decimals,
  required _Better better,
  String unit = '',
}) {
  final label = NightText(key);
  if (value == null || !value.isFinite) return MetricVm(label: label);
  final text = '${nightFixed(value, decimals)}$unit';
  if (median == null) return MetricVm(label: label, value: text);
  final delta = value - median;
  var tone = MetricTone.neutral;
  final scale = median.abs();
  if (better != _Better.neither && scale > 0) {
    final improving = better == _Better.lower ? delta < 0 : delta > 0;
    final share = delta.abs() / scale;
    if (improving && share >= _improvementShare) {
      tone = MetricTone.good;
    } else if (!improving && share >= _worseningShare) {
      tone = MetricTone.warning;
    }
  }
  return MetricVm(
    label: label,
    value: text,
    delta: nightSignedDelta(delta, decimals),
    deltaTone: tone,
  );
}

/// Great-circle separation in arcseconds; RA in hours, Dec in degrees.
double nightSeparationArcsec(
  double ra1Hours,
  double dec1Deg,
  double ra2Hours,
  double dec2Deg,
) {
  const toRad = math.pi / 180;
  final ra1 = ra1Hours * 15 * toRad;
  final ra2 = ra2Hours * 15 * toRad;
  final d1 = dec1Deg * toRad;
  final d2 = dec2Deg * toRad;
  final sinDd = math.sin((d2 - d1) / 2);
  final sinDr = math.sin((ra2 - ra1) / 2);
  final h = sinDd * sinDd + math.cos(d1) * math.cos(d2) * sinDr * sinDr;
  return 2 * math.asin(math.min(1, math.sqrt(h))) / toRad * 3600;
}

/// `0.8″`, `12.4′`, `1.2°`.
String nightAngle(double arcsec) {
  if (arcsec < 60) return '${arcsec.toStringAsFixed(1)}″';
  if (arcsec < 3600) return '${(arcsec / 60).toStringAsFixed(1)}′';
  return '${(arcsec / 3600).toStringAsFixed(1)}°';
}

final nightLastFrameProvider = Provider<NightLastFrameVm?>((ref) {
  final current = ref.watch(currentImageProvider);
  final lights = ref.watch(nightSessionLightRowsProvider);
  if (current == null && lights.isEmpty) return null;

  final frameNumber = current == null
      ? lights.length
      : nightFrameNumberForPath(lights, current.filePath);
  final row = frameNumber == null ? null : lights[frameNumber - 1];

  // Without the frame on screen (a remote viewer, or after a restart) the
  // newest row stands in, with only what the row stores.
  final stats = current?.stats;
  final hfr = stats != null ? stats.hfr : row?.hfr;
  final stars = stats != null ? stats.starCount : row?.starCount;
  final noise = stats != null ? stats.noise : row?.noise;

  final kept = lights.where((r) => r.isAccepted);
  final memory = ref
      .watch(sessionImagesProvider)
      .map((image) => image.stats)
      .whereType<ImageStats>()
      .toList(growable: false);

  String? solve;
  final target = ref.watch(runDashboardActiveTargetProvider);
  final solvedRa = row?.solvedRa;
  final solvedDec = row?.solvedDec;
  if (target != null &&
      row != null &&
      row.isPlateSolved &&
      solvedRa != null &&
      solvedDec != null) {
    solve = nightAngle(
      nightSeparationArcsec(
        solvedRa,
        solvedDec,
        target.raHours,
        target.decDegrees,
      ),
    );
  }

  final histogram = current?.histogram;
  return NightLastFrameVm(
    frameNumber: frameNumber,
    histogram: histogram == null || histogram.isEmpty ? null : histogram,
    metrics: <MetricVm>[
      _metric(
        'nightSessionMetricHfr',
        value: hfr,
        median: nightMedian(kept.map((r) => r.hfr)),
        decimals: 2,
        better: _Better.lower,
      ),
      _metric(
        'nightSessionMetricFwhm',
        value: stats?.fwhm,
        median: nightMedian(memory.map((s) => s.fwhm)),
        decimals: 2,
        better: _Better.lower,
      ),
      _metric(
        'nightSessionMetricEcc',
        value: stats?.eccentricity,
        median: nightMedian(memory.map((s) => s.eccentricity)),
        decimals: 2,
        better: _Better.lower,
      ),
      _metric(
        'nightSessionMetricStars',
        value: stars?.toDouble(),
        median: nightMedian(kept.map((r) => r.starCount?.toDouble())),
        decimals: 0,
        better: _Better.higher,
      ),
      _metric(
        'nightSessionMetricMedian',
        value: stats?.median,
        median: nightMedian(memory.map((s) => s.median)),
        decimals: 0,
        better: _Better.neither,
      ),
      _metric(
        'nightSessionMetricBgSigma',
        value: noise,
        median: nightMedian(kept.map((r) => r.noise)),
        decimals: 1,
        better: _Better.lower,
      ),
      _metric(
        'nightSessionMetricSnr',
        value: stats?.snr,
        median: nightMedian(memory.map((s) => s.snr)),
        decimals: 1,
        better: _Better.higher,
      ),
      MetricVm(
        label: const NightText('nightSessionMetricOffTarget'),
        value: solve,
      ),
    ],
  );
});
