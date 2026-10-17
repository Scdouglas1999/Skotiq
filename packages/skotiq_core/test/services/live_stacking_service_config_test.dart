// Tests for the OSC / colour-aware value types on LiveStackingService.
//
// Covers:
//   * LiveStackingConfig defaults match the historic mono behaviour.
//   * LiveStackingConfig round-trips the colour fields through copyWith.
//   * LiveStackingConfig value equality / hashCode account for colour fields.
//   * LiveStackingResult defaults to a single channel (monochrome).

import 'package:flutter_test/flutter_test.dart';
// Import the implementation path directly rather than the package barrel: the
// barrel transitively pulls in the OSC seam/orchestrator wiring (sibling
// components), so importing it here would couple this value-type test to
// unrelated source. Same direct-path convention as the other service tests.
import 'package:skotiq_core/src/services/live_stacking_service.dart';

void main() {
  group('LiveStackingConfig colour fields', () {
    test('defaults preserve historic mono behaviour', () {
      const config = LiveStackingConfig();

      expect(config.sensorMode, 'mono');
      expect(config.bayerPattern, isNull);
      expect(config.demosaicQuality, 'bilinear');
    });

    test('copyWith round-trips the colour fields', () {
      const base = LiveStackingConfig();

      final osc = base.copyWith(
        sensorMode: 'osc',
        bayerPattern: 'RGGB',
        demosaicQuality: 'vng',
      );

      expect(osc.sensorMode, 'osc');
      expect(osc.bayerPattern, 'RGGB');
      expect(osc.demosaicQuality, 'vng');

      // Non-colour fields are untouched.
      expect(osc.sigmaClipEnabled, base.sigmaClipEnabled);
      expect(osc.sigmaClipThreshold, base.sigmaClipThreshold);
      expect(osc.maxMatchStars, base.maxMatchStars);
      expect(osc.matchRadiusPx, base.matchRadiusPx);
      expect(osc.matchFluxTolerance, base.matchFluxTolerance);
      expect(osc.minMatchedPairs, base.minMatchedPairs);
    });

    test('copyWith with no colour args keeps existing colour values', () {
      const colour = LiveStackingConfig(
        sensorMode: 'osc',
        bayerPattern: 'BGGR',
        demosaicQuality: 'superpixel',
      );

      final tweaked = colour.copyWith(maxMatchStars: 250);

      expect(tweaked.maxMatchStars, 250);
      expect(tweaked.sensorMode, 'osc');
      expect(tweaked.bayerPattern, 'BGGR');
      expect(tweaked.demosaicQuality, 'superpixel');
    });

    test('copyWith can explicitly clear a Bayer-pattern override', () {
      const colour = LiveStackingConfig(
        sensorMode: 'auto',
        bayerPattern: 'BGGR',
      );

      final automatic = colour.copyWith(clearBayerPattern: true);

      expect(automatic.sensorMode, 'auto');
      expect(automatic.bayerPattern, isNull);
    });

    test('value equality and hashCode account for colour fields', () {
      const a = LiveStackingConfig(
        sensorMode: 'osc',
        bayerPattern: 'GRBG',
        demosaicQuality: 'vng',
      );
      const b = LiveStackingConfig(
        sensorMode: 'osc',
        bayerPattern: 'GRBG',
        demosaicQuality: 'vng',
      );
      const differentPattern = LiveStackingConfig(
        sensorMode: 'osc',
        bayerPattern: 'GBRG',
        demosaicQuality: 'vng',
      );
      const differentMode = LiveStackingConfig(
        sensorMode: 'mono',
        bayerPattern: 'GRBG',
        demosaicQuality: 'vng',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      expect(a, isNot(equals(differentPattern)));
      expect(a, isNot(equals(differentMode)));
    });

    test('default config equals an explicitly mono config', () {
      const defaulted = LiveStackingConfig();
      const explicitMono = LiveStackingConfig(
        sensorMode: 'mono',
        demosaicQuality: 'bilinear',
      );

      expect(defaulted, equals(explicitMono));
      expect(defaulted.hashCode, equals(explicitMono.hashCode));
    });
  });

  group('LiveStackingResult channels', () {
    test('defaults to a single (monochrome) channel', () {
      const result = LiveStackingResult(
        width: 64,
        height: 48,
        data: <int>[],
        stats: LiveStackingStats(),
      );

      expect(result.channels, 1);
    });

    test('accepts an explicit three-channel (OSC) result', () {
      const result = LiveStackingResult(
        width: 64,
        height: 48,
        channels: 3,
        data: <int>[],
        stats: LiveStackingStats(),
      );

      expect(result.channels, 3);
    });
  });
}
