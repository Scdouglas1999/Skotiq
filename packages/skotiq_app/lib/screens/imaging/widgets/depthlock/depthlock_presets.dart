import 'dart:math' as math;

import 'package:skotiq_core/skotiq_core.dart';

/// How deep a goal is asking to go, in the terms an observer thinks in.
///
/// The two numbers behind a preset are the aperture side and the depth
/// threshold, and they move together for a physical reason: a wider aperture
/// averages more sky per measurement, which is what reaches a fainter surface
/// brightness, and the signal that survives out there is weaker — so a coarser
/// preset asks for a lower score over a larger cell rather than the same score
/// over a smaller one.
///
/// A preset is a starting point, not a constraint. Advanced exposes both
/// numbers, and the native validator has the final word on either.
enum DepthLockPreset {
  /// Detail that is already visible, just noisy.
  faint,

  /// Detail that is hinted at but not yet believable.
  veryFaint,

  /// Integrated light that takes many nights.
  extreme;

  /// The aperture side this preset asks for, in arcseconds, before the
  /// sampler's pixel limits are applied.
  double get scaleArcsec => switch (this) {
        DepthLockPreset.faint => 10,
        DepthLockPreset.veryFaint => 20,
        DepthLockPreset.extreme => 40,
      };

  /// The depth score this preset asks the region to reach.
  double get threshold => switch (this) {
        DepthLockPreset.faint => 5,
        DepthLockPreset.veryFaint => 4,
        DepthLockPreset.extreme => 3,
      };

  String get label => switch (this) {
        DepthLockPreset.faint => 'Faint',
        DepthLockPreset.veryFaint => 'Very faint',
        DepthLockPreset.extreme => 'Extreme',
      };

  /// One line saying what this preset is for, in observing terms and with its
  /// two numbers stated — a preset that hides what it set is a preset nobody
  /// can check. The number is a signal-to-noise ratio: the structure's light
  /// above the local sky divided by the noise in that measurement, per
  /// square, for the *weakest quarter* of the marked area.
  String get description => switch (this) {
        DepthLockPreset.faint =>
          'Faint: 10″ squares, signal-to-noise 5 — the weakest quarter of the '
              'area reaches five times its noise. Wisps you can already glimpse '
              'in a stretched sub become clearly present.',
        DepthLockPreset.veryFaint =>
          'Very faint: 20″ squares, signal-to-noise 4 — bigger squares gather '
              'more light. Structure that is only hinted at becomes believable.',
        DepthLockPreset.extreme =>
          'Extreme: 40″ squares, signal-to-noise 3 — the coarsest look, for '
              'integrated light that takes many nights. Three is "there is '
              'something there", not a finished picture.',
      };

  /// How the number scales, so a custom target is not a guess.
  static const String scalingNote =
      'Signal-to-noise grows with the square root of the exposures: '
      'doubling the number needs about four times the integration.';
}

/// The coverage a new goal starts on: nine apertures in ten must stay
/// measurable. It is the loosest the native estimator accepts, which is the
/// right default for a region an operator drew by hand around real structure.
const double kDepthLockDefaultCoverage = 0.9;

/// [preset]'s aperture side, pulled inside the sampler's limits for a frame at
/// [pixelScaleArcsec].
///
/// The sampler refuses an aperture narrower than 4 or wider than 64 native
/// pixels, and the measurement definition refuses anything under 2″. A preset
/// is a nominal angular size, so on a very long or very short focal length it
/// has to give way to the instrument rather than produce a definition the
/// validator rejects.
double depthLockPresetScale(
  DepthLockPreset preset, {
  required double pixelScaleArcsec,
}) {
  if (pixelScaleArcsec <= 0) return preset.scaleArcsec;
  final double lower = math.max(2.0, 4.0 * pixelScaleArcsec);
  final double upper = math.max(lower, 64.0 * pixelScaleArcsec);
  final double clamped = preset.scaleArcsec.clamp(lower, upper).toDouble();
  return double.parse(clamped.toStringAsFixed(2));
}

/// The preset [measurement] currently corresponds to, or null when its
/// numbers have been moved off every preset.
///
/// Matching is on the threshold and on the aperture the preset would have
/// produced for this frame, so a preset whose scale was clamped by the
/// instrument still reads as that preset rather than as "custom".
DepthLockPreset? depthLockPresetOf(
  DepthLockMeasurement measurement, {
  required double pixelScaleArcsec,
}) {
  for (final preset in DepthLockPreset.values) {
    final double scale = depthLockPresetScale(
      preset,
      pixelScaleArcsec: pixelScaleArcsec,
    );
    if ((measurement.threshold - preset.threshold).abs() < 1e-6 &&
        (measurement.scaleArcsec - scale).abs() < 1e-6) {
      return preset;
    }
  }
  return null;
}

/// [measurement] with [preset]'s aperture and threshold applied.
DepthLockMeasurement depthLockApplyPreset(
  DepthLockMeasurement measurement,
  DepthLockPreset preset, {
  required double pixelScaleArcsec,
}) =>
    measurement.copyWith(
      scaleArcsec:
          depthLockPresetScale(preset, pixelScaleArcsec: pixelScaleArcsec),
      threshold: preset.threshold,
    );

/// The error floor a freshly built definition carries until the editor has
/// derived one from the operator's masters.
///
/// It exists only because the native validator refuses a floor of zero, so a
/// definition has to hold *something* to be checkable at all. Its source note
/// says exactly that, so a goal can never be saved with a number nobody chose:
/// the editor replaces both the moment `suggestDepthLockFloor` answers, and
/// refuses to save while neither a derived nor a typed floor exists.
const double kDepthLockSeedFloorAdu = 0.5;

/// The source note that ships with [kDepthLockSeedFloorAdu].
const String kDepthLockSeedFloorSource = 'Not yet derived from your masters';
