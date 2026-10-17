// Real on-display FrameTiming measurement for the planetarium.
//
// Unlike the headless paint benchmark (which measures CPU paint-pipeline time),
// this integration test pumps the animated planetarium on a real device/display
// and captures Flutter's FrameTiming — genuine build + raster milliseconds,
// GPU included. It is NOT part of the optimization loop's gate (it needs a
// display and varies with the host GPU); it is for manual end-to-end FPS checks.
//
// Run on a machine with a display / attached device:
//   flutter test integration_test/frame_timing_test.dart -d windows
//   flutter test integration_test/frame_timing_test.dart -d <deviceId>
//
// The printed build/raster p50/p95 are the real per-frame numbers; compare the
// raster p95 against the 16.7ms (60fps) / 8.3ms (120fps) budgets.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../benchmark/src/camera_timeline.dart';
import '../benchmark/src/fixture_generator.dart';
import '../benchmark/src/frame_timing_harness.dart';
import '../benchmark/src/stress_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('planetarium real FrameTiming over the scripted timeline', (
    tester,
  ) async {
    final fixture = StressFixture.load();
    final timeline = buildBenchmarkTimeline(
      anchorRaHours: kAnchorRaHours,
      anchorDecDeg: kAnchorDecDeg,
      frameCount: 180,
    );

    final timings = <ui.FrameTiming>[];
    void collector(List<ui.FrameTiming> t) => timings.addAll(t);
    binding.addTimingsCallback(collector);
    addTearDown(() => binding.removeTimingsCallback(collector));

    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: FrameTimingHarness(
          fixture: fixture,
          timeline: timeline,
          duration: const Duration(seconds: 6),
          onCompleted: () => completed = true,
        ),
      ),
    );

    // Pump frames until the animation reports completion (or a safety cap).
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!completed && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    // Let trailing FrameTiming callbacks flush.
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      timings,
      isNotEmpty,
      reason: 'no FrameTiming captured — is this running on a real display?',
    );

    double p(List<double> xs, double q) {
      final s = [...xs]..sort();
      final rank = (q * (s.length - 1)).round().clamp(0, s.length - 1);
      return s[rank];
    }

    final buildMs = [
      for (final t in timings) t.buildDuration.inMicroseconds / 1000.0,
    ];
    final rasterMs = [
      for (final t in timings) t.rasterDuration.inMicroseconds / 1000.0,
    ];

    // ignore: avoid_print
    print(
      'FrameTiming over ${timings.length} frames:\n'
      '  build  p50=${p(buildMs, 0.50).toStringAsFixed(2)}ms '
      'p95=${p(buildMs, 0.95).toStringAsFixed(2)}ms\n'
      '  raster p50=${p(rasterMs, 0.50).toStringAsFixed(2)}ms '
      'p95=${p(rasterMs, 0.95).toStringAsFixed(2)}ms\n'
      '  (60fps budget 16.7ms, 120fps budget 8.3ms)',
    );
  });
}
