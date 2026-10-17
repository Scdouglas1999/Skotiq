// The preset → parameter mapping, which is the whole of what a preset means.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_presets.dart';

import 'depthlock_test_doubles.dart';

void main() {
  test('each preset names both of the numbers it sets', () {
    expect(DepthLockPreset.faint.scaleArcsec, 10);
    expect(DepthLockPreset.faint.threshold, 5);
    expect(DepthLockPreset.veryFaint.scaleArcsec, 20);
    expect(DepthLockPreset.veryFaint.threshold, 4);
    expect(DepthLockPreset.extreme.scaleArcsec, 40);
    expect(DepthLockPreset.extreme.threshold, 3);

    // The description is what the operator reads, so it has to state the two
    // numbers it is choosing on their behalf.
    for (final preset in DepthLockPreset.values) {
      expect(preset.description, contains('${preset.scaleArcsec.round()}″'));
      expect(
        preset.description,
        contains('signal-to-noise ${preset.threshold.round()}'),
      );
    }
  });

  test('a coarser preset asks for less depth over a bigger aperture', () {
    final byScale = DepthLockPreset.values.toList()
      ..sort((a, b) => a.scaleArcsec.compareTo(b.scaleArcsec));
    for (var i = 1; i < byScale.length; i++) {
      expect(
        byScale[i].threshold,
        lessThan(byScale[i - 1].threshold),
        reason: '${byScale[i].label} must not ask for more depth than '
            '${byScale[i - 1].label}',
      );
    }
  });

  test('applying a preset moves the aperture and the threshold together', () {
    final measurement = depthLockDefinitionFixture().measurement;
    final applied = depthLockApplyPreset(
      measurement,
      DepthLockPreset.extreme,
      pixelScaleArcsec: 1.04,
    );

    expect(applied.scaleArcsec, 40);
    expect(applied.threshold, 3);
    // Everything else is untouched: a preset chooses a depth, not a region.
    expect(applied.region, measurement.region);
    expect(applied.minCoverage, measurement.minCoverage);
    expect(applied.systematicFloorAdu, measurement.systematicFloorAdu);
  });

  test('a preset gives way to the sampler on an extreme plate scale', () {
    // 0.25 arcsec/px: 40 arcsec would be a 160 px aperture, past the 64 px
    // ceiling, so Extreme comes back at the ceiling instead.
    expect(
      depthLockPresetScale(DepthLockPreset.extreme, pixelScaleArcsec: 0.25),
      16,
    );
    // 3 arcsec/px: 10 arcsec would be a 3.3 px aperture, under the 4 px floor.
    expect(
      depthLockPresetScale(DepthLockPreset.faint, pixelScaleArcsec: 3),
      12,
    );
    // 0.1 arcsec/px: even Faint's 10 arcsec is a 100 px aperture, so the
    // ceiling binds on every preset at that scale.
    expect(
      depthLockPresetScale(DepthLockPreset.faint, pixelScaleArcsec: 0.1),
      6.4,
    );
    // An unknown plate scale cannot clamp anything, and must not pretend to.
    expect(
      depthLockPresetScale(DepthLockPreset.faint, pixelScaleArcsec: 0),
      10,
    );
  });

  test('a clamped preset still reads as that preset, not as custom', () {
    final measurement = depthLockDefinitionFixture().measurement.copyWith(
          scaleArcsec: 16,
          threshold: 3,
        );
    expect(
      depthLockPresetOf(measurement, pixelScaleArcsec: 0.25),
      DepthLockPreset.extreme,
    );
  });

  test('numbers off every preset read as custom', () {
    final measurement = depthLockDefinitionFixture().measurement.copyWith(
          scaleArcsec: 7.5,
          threshold: 5,
        );
    expect(depthLockPresetOf(measurement, pixelScaleArcsec: 1.04), isNull);
  });

  test('a new goal starts at nine apertures in ten measurable', () {
    expect(kDepthLockDefaultCoverage, 0.9);
  });
}
