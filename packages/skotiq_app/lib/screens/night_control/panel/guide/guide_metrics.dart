// The Guide tab's numbers: RMS over the same samples the center chart draws,
// the plan's dither cadence, and a few formatters.
//
// The distances are computed in guide-camera pixels and shown in arcseconds
// only when the guider reports its pixel scale (plan N4).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../data/plan/night_plan_inputs.dart';
import '../../data/plan/plan_steps_provider.dart';
import '../../data/session/guide_series_provider.dart';

/// RMS and peak of the guide samples in the chart's window. Null fields when
/// there are no samples.
@immutable
class NightGuideRms {
  const NightGuideRms(
      {this.ra, this.dec, this.total, this.peak, this.count = 0});

  final double? ra;
  final double? dec;
  final double? total;

  /// The largest single-step distance from the lock position.
  final double? peak;
  final int count;
}

final nightGuideRmsProvider = Provider<NightGuideRms>((ref) {
  final samples = ref.watch(nightGuideSamplesProvider);
  if (samples.isEmpty) return const NightGuideRms();
  double rms(Iterable<double> values) {
    var sum = 0.0;
    var n = 0;
    for (final v in values) {
      sum += v * v;
      n++;
    }
    return math.sqrt(sum / n);
  }

  final ra = rms(samples.map((s) => s.raPx));
  final dec = rms(samples.map((s) => s.decPx));
  final peak = samples.fold<double>(
    0,
    (worst, s) =>
        math.max(worst, math.sqrt(s.raPx * s.raPx + s.decPx * s.decPx)),
  );
  return NightGuideRms(
    ra: ra,
    dec: dec,
    total: math.sqrt(ra * ra + dec * dec),
    peak: peak,
    count: samples.length,
  );
});

/// How many frames the plan dithers after: the running step's own setting,
/// else the first light step's, else a dither-interval trigger's. Null when
/// the plan does not say.
final nightDitherEveryProvider = Provider<int?>((ref) {
  final active = ref.watch(nightActiveStepProvider)?.node;
  if (active is ExposureNode) {
    final every = active.ditherEvery;
    if (every != null && every > 0) return every;
  }
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null) return null;
  for (final entry in tree.steps) {
    final node = entry.node;
    if (node is ExposureNode && node.frameType == FrameType.light) {
      final every = node.ditherEvery;
      if (every != null && every > 0) return every;
    }
  }
  for (final entry in tree.entries) {
    final node = entry.node;
    if (node is RecoveryNode &&
        node.triggerType == TriggerType.ditherInterval &&
        node.triggerEveryNFrames > 0) {
      return node.triggerEveryNFrames;
    }
  }
  return null;
});

/// The Guiding screen's mapping from the stored dither size to pixels.
double ditherScalePixels(String scale) => switch (scale) {
      'Small' => 2.0,
      'Large' => 10.0,
      _ => 5.0,
    };

/// A guide distance in arcseconds when [arcsecPerPixel] is known, else in
/// pixels; null stays null.
String? formatGuide(double? px, double? arcsecPerPixel) =>
    px == null || !px.isFinite ? null : nightGuideDistance(px, arcsecPerPixel);

/// `0.31 px`; null stays null.
String? formatPx(double? px, {int decimals = 2}) =>
    px == null || !px.isFinite ? null : '${px.toStringAsFixed(decimals)} px';

/// `8.2k`, `950`: a star mass.
String formatMass(double mass) => mass >= 10000
    ? '${(mass / 1000).toStringAsFixed(0)}k'
    : mass >= 1000
        ? '${(mass / 1000).toStringAsFixed(1)}k'
        : mass.toStringAsFixed(0);
