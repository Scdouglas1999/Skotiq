import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';
import 'package:skotiq_core/src/services/stacking_engine_seam.dart';

/// Tests for the OSC/colour additions to [StackingEngineSeam] (component C9):
///
///   * [LinearFrameData] surfaces the per-frame Bayer pattern so the
///     orchestrator can branch on CFA geometry.
///   * The auto-stretch channel dispatch rejects unsupported channel counts
///     before reaching the native bridge.
///   * The OSC config fields (`sensorMode` / `bayerPattern` / `demosaicQuality`)
///     thread through the seam unchanged.
///
/// The actual colour STF curve now lives in Rust
/// (`imaging_ops::auto_stretch_color_image`, exposed as
/// `apiAutoStretchColorImage`) and is verified by that crate's own unit tests
/// (`auto_stretch_color_tests`) — the per-channel-independence, identity-on-
/// constant, and length-guard behaviours are pinned there against the single
/// source of truth. The seam no longer reimplements the STF in Dart, so the
/// behavioural curve assertions are intentionally not duplicated here; the only
/// seam-level dispatch logic that does not require the native library (the
/// unsupported-channel-count guard) is covered below.
void main() {
  group('LinearFrameData', () {
    test('exposes the Bayer pattern (CFA frame)', () {
      const frame = LinearFrameData(
        width: 2,
        height: 2,
        linearData: [10.0, 20.0, 30.0, 40.0],
        bayerPattern: 'RGGB',
      );

      expect(frame.bayerPattern, 'RGGB');
      expect(frame.width, 2);
      expect(frame.height, 2);
      expect(frame.linearData, [10.0, 20.0, 30.0, 40.0]);
    });

    test('defaults the Bayer pattern to null (mono frame)', () {
      const frame = LinearFrameData(width: 1, height: 1, linearData: [42.0]);

      expect(frame.bayerPattern, isNull);
    });
  });

  group('BridgeStackingEngineSeam.autoStretch channel dispatch', () {
    const seam = BridgeStackingEngineSeam();

    test('rejects a non-{1,3} channel count before reaching the bridge', () {
      // The guard lives in the seam's `switch` default, ahead of any native
      // call, so it is testable without the Rust library loaded.
      expect(
        () => seam.autoStretch(width: 1, height: 1, data: [0], channels: 2),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => seam.autoStretch(width: 1, height: 1, data: [0], channels: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('OSC config pass-through', () {
    test(
      'startFromData forwards sensorMode/bayerPattern/demosaicQuality',
      () async {
        final engine = _CapturingSeam();
        const config = LiveStackingConfig(
          sensorMode: 'osc',
          bayerPattern: 'GRBG',
          demosaicQuality: 'vng',
        );

        await engine.startFromData(
          width: 4,
          height: 4,
          data: const [0, 0, 0, 0],
          config: config,
        );

        expect(engine.lastConfig, isNotNull);
        expect(engine.lastConfig!.sensorMode, 'osc');
        expect(engine.lastConfig!.bayerPattern, 'GRBG');
        expect(engine.lastConfig!.demosaicQuality, 'vng');
      },
    );

    test('startFromFile forwards the colour config unchanged', () async {
      final engine = _CapturingSeam();
      const config = LiveStackingConfig(
        sensorMode: 'auto',
        bayerPattern: null,
        demosaicQuality: 'superpixel',
      );

      await engine.startFromFile(
        referenceImagePath: '/ref.fits',
        config: config,
      );

      expect(engine.lastConfig!.sensorMode, 'auto');
      expect(engine.lastConfig!.bayerPattern, isNull);
      expect(engine.lastConfig!.demosaicQuality, 'superpixel');
    });
  });
}

/// A minimal [StackingEngineSeam] that records the [LiveStackingConfig] handed
/// to its start paths so the colour-config pass-through can be asserted without
/// the native bridge. Mirrors the production interface exactly (it is a
/// compile-time check that the seam stays in sync with the colour fields).
class _CapturingSeam implements StackingEngineSeam {
  LiveStackingConfig? lastConfig;
  int? lastStretchChannels;

  @override
  bool isActive() => false;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    required LiveStackingConfig config,
  }) async {
    lastConfig = config;
    return const LiveStackingStats();
  }

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    required LiveStackingConfig config,
  }) async {
    lastConfig = config;
    return const LiveStackingStats();
  }

  @override
  Future<LinearFrameData> readLinearFrame(String filePath) async {
    return const LinearFrameData(width: 1, height: 1, linearData: [0.0]);
  }

  @override
  Uint8List autoStretch({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) {
    lastStretchChannels = channels;
    return Uint8List(width * height * 4);
  }

  @override
  Future<void> stop() async {}
}
