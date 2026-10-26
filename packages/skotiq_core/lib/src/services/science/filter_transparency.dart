import 'dart:math' as math;

import '../../models/science/science_models.dart';
import 'photometric_bands.dart';

/// Transparency of the newest calibration in [calibrations], measured
/// against the earlier zero points of the same filter and band.
///
/// When those zero points cover at least [TransparencyOptions.minAirmassSpan]
/// of airmass, the clear-sky line `ZP = ZP0 − k·X` is fitted to their upper
/// envelope (cloud and haze only ever lower a zero point, so points well
/// below the line are dropped), the newest frame is compared with the line
/// at its own airmass, and k is reported as the extinction when it is
/// plausible. Otherwise the newest zero point is compared with the filter's
/// reference zero point (the 90th percentile of the session's zero points in
/// that filter) and no extinction is reported; [TransparencySample.note]
/// says why.
///
/// Returns null when fewer than [TransparencyOptions.minimumSampleCount]
/// calibrations of the newest frame's filter exist.
TransparencySample? estimateFilterTransparency(
  List<FramePhotometricCalibration> calibrations,
  TransparencyOptions options,
) {
  final usable =
      calibrations
          .where(
            (c) =>
                c.isCalibrated && c.zeroPoint != null && c.zeroPoint!.isFinite,
          )
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  if (usable.isEmpty) return null;
  final current = usable.last;
  final key = normalizeFilterKey(current.filter);
  final same = usable
      .where(
        (c) =>
            normalizeFilterKey(c.filter) == key &&
            c.photometricBand == current.photometricBand,
      )
      .toList(growable: false);
  if (same.length < options.minimumSampleCount) return null;
  final filterLabel = key.isEmpty ? 'no filter' : key;
  final zpNow = current.zeroPoint!;

  final earlier = same.sublist(0, same.length - 1);
  final fitData = earlier
      .where((c) => c.airmass != null && c.airmass!.isFinite)
      .toList(growable: false);
  final span = fitData.length < 2
      ? 0.0
      : fitData.map((c) => c.airmass!).reduce(math.max) -
            fitData.map((c) => c.airmass!).reduce(math.min);

  double? extinction;
  double? predicted;
  double fitRms = 0;
  String note;
  if (span >= options.minAirmassSpan &&
      fitData.length >= options.minimumSampleCount &&
      current.airmass != null) {
    final line = _upperEnvelopeFit(
      fitData.map((c) => c.airmass!).toList(),
      fitData.map((c) => c.zeroPoint!).toList(),
    );
    final k = line == null ? null : -line.slope;
    if (line != null &&
        k! >= options.minPlausibleExtinction &&
        k <= options.maxPlausibleExtinction) {
      extinction = k;
      predicted = line.intercept + line.slope * current.airmass!;
      fitRms = line.rms;
      note =
          'Extinction ${k.toStringAsFixed(2)} mag/airmass in $filterLabel '
          'from ${line.used} frames over ${span.toStringAsFixed(2)} airmass';
    } else {
      note = line == null
          ? 'Extinction not measured: the $filterLabel zero points do not '
                'fit a line'
          : 'Extinction not measured: the $filterLabel zero points change by '
                '${k!.toStringAsFixed(2)} mag per airmass, so the sky changed '
                'during the night';
    }
  } else {
    note =
        'Extinction not measured: $filterLabel frames cover '
        '${span.toStringAsFixed(2)} airmass, '
        '${options.minAirmassSpan.toStringAsFixed(1)} needed';
  }

  final double deltaMag;
  final int sampleCount;
  final double scatter;
  if (predicted != null) {
    deltaMag = predicted - zpNow;
    sampleCount = fitData.length;
    scatter = fitRms;
  } else {
    final zps = same.map((c) => c.zeroPoint!).toList()..sort();
    final reference = zps[((zps.length - 1) * 0.9).round()];
    deltaMag = reference - zpNow;
    sampleCount = same.length;
    scatter = _robustSigma(zps);
  }
  final transparency = (math.pow(10.0, -0.4 * deltaMag) * 100.0)
      .clamp(0.0, 100.0)
      .toDouble();
  final sampleFactor = (sampleCount / 12).clamp(0.25, 1.0);
  final scatterPenalty = math.exp(-(scatter / 0.1).clamp(0.0, 4.0));
  final confidence = (sampleFactor * scatterPenalty).clamp(0.1, 1.0);

  final quality = transparency >= 95
      ? 'Excellent'
      : transparency >= 85
      ? 'Good'
      : transparency >= 70
      ? 'Fair'
      : 'Poor';
  return TransparencySample(
    capturedImageId: current.capturedImageId,
    sessionId: current.sessionId,
    timestamp: current.timestamp,
    transparencyPercent: transparency,
    extinctionCoefficient: extinction ?? 0.0,
    qualityBucket: quality,
    confidence: confidence.toDouble(),
    extinctionFromAirmassFit: extinction != null,
    filter: current.filter,
    note: note,
  );
}

class _Line {
  const _Line(this.slope, this.intercept, this.rms, this.used);
  final double slope;
  final double intercept;
  final double rms;
  final int used;
}

_Line? _upperEnvelopeFit(List<double> x, List<double> y) {
  var keep = List<bool>.filled(x.length, true);
  _Line? line;
  for (var iteration = 0; iteration < 5; iteration++) {
    final xs = <double>[], ys = <double>[];
    for (var i = 0; i < x.length; i++) {
      if (keep[i]) {
        xs.add(x[i]);
        ys.add(y[i]);
      }
    }
    if (xs.length < 3) return line;
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxy = 0.0;
    for (var i = 0; i < n; i++) {
      sxx += (xs[i] - mx) * (xs[i] - mx);
      sxy += (xs[i] - mx) * (ys[i] - my);
    }
    if (sxx <= 1e-9) return line;
    final slope = sxy / sxx;
    final intercept = my - slope * mx;
    final residuals = [
      for (var i = 0; i < x.length; i++) y[i] - (intercept + slope * x[i]),
    ];
    final kept = [
      for (var i = 0; i < x.length; i++)
        if (keep[i]) residuals[i],
    ];
    final sigma = math.max(0.01, _robustSigma(kept));
    final rms = math.sqrt(
      kept.map((r) => r * r).reduce((a, b) => a + b) / kept.length,
    );
    line = _Line(slope, intercept, rms, n);
    final lower = -math.max(0.05, 2.5 * sigma);
    final next = [
      for (var i = 0; i < x.length; i++)
        residuals[i] >= lower && residuals[i] <= 3 * sigma + 0.05,
    ];
    var changed = false;
    for (var i = 0; i < x.length; i++) {
      if (next[i] != keep[i]) changed = true;
    }
    if (!changed) break;
    keep = next;
  }
  return line;
}

double _robustSigma(List<double> values) {
  if (values.length < 2) return 0;
  final sorted = values.toList()..sort();
  final med = sorted[sorted.length ~/ 2];
  final dev = sorted.map((v) => (v - med).abs()).toList()..sort();
  return 1.4826 * dev[dev.length ~/ 2];
}
