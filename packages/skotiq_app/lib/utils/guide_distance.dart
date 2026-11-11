import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

// Guide distances: an RMS, a peak, one step's error.
//
// Both guiders report them in guide-camera pixels (PHD2's `RADistanceRaw` /
// `DECDistanceRaw` and `AvgDist`; the built-in guider's `raPx` / `decPx`), and
// that is what `Phd2GuideStats` and `GuiderState` carry. They are arcseconds
// only after multiplying by the guide camera's scale. Every screen that shows
// one goes through here, so none of them puts an arcsecond mark on pixels.

/// The guide camera's arcseconds per pixel as the guider reports it, or null
/// when it has not reported one; guide distances are then shown in pixels.
final guideScaleProvider = Provider<double?>((ref) {
  final scale = ref.watch(
    guiderStateProvider.select((g) => g.pixelScaleArcsecPerPixel),
  );
  return knownGuideScale(scale);
});

/// [scale] when it is a usable arcseconds-per-pixel figure, else null.
double? knownGuideScale(double? scale) =>
    scale != null && scale.isFinite && scale > 0 ? scale : null;

/// A guide distance of [px] pixels as the number to show and its unit:
/// arcseconds (`″`) when [arcsecPerPixel] is known, pixels (` px`) otherwise.
({double value, String unit}) guideDistance(
        double px, double? arcsecPerPixel) =>
    arcsecPerPixel == null
        ? (value: px, unit: ' px')
        : (value: px * arcsecPerPixel, unit: '″');

/// A guide distance of [px] pixels: `0.42″` when [arcsecPerPixel] is known,
/// `0.31 px` otherwise.
String guideDistanceText(
  double px,
  double? arcsecPerPixel, {
  int decimals = 2,
}) {
  final shown = guideDistance(px, arcsecPerPixel);
  return '${shown.value.toStringAsFixed(decimals)}${shown.unit}';
}

/// [guideDistanceText] with the unit spelled out, for a screen reader.
String guideDistanceSpoken(
  double px,
  double? arcsecPerPixel, {
  int decimals = 2,
}) {
  final shown = guideDistance(px, arcsecPerPixel);
  final unit = arcsecPerPixel == null ? 'pixels' : 'arcseconds';
  return '${shown.value.toStringAsFixed(decimals)} $unit';
}
