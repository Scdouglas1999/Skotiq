// Tagged "golden" so the perceptual/pixel-diff golden gate is excluded by
// `melos run test` (Linux CI + default local runs) and opt-in via
// `melos run test:golden`. Baselines are host-specific; see
// docs/testing/golden-tests.md.
@Tags(['golden'])
library;

// Golden / perceptual-diff gate for the planetarium benchmark.
//
// Two modes, selected by the BENCHMARK_GOLDEN_MODE environment variable:
//
//   capture  — render the checkpoint frames and (over)write the committed
//              baselines under benchmark/goldens/. Run this once to establish or
//              intentionally refresh the baseline:
//                $env:BENCHMARK_GOLDEN_MODE="capture"; `
//                  flutter test test/benchmark/golden_compare_test.dart
//
//   compare  — (default) re-render and perceptually diff against the baselines.
//              Fails if any checkpoint exceeds tolerance, catching a dropped
//              star / label / glow / line even when timing looks better:
//                flutter test test/benchmark/golden_compare_test.dart
//
// See benchmark/README.md for the tolerance rationale.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/src/camera_timeline.dart';
import '../../benchmark/src/fixture_generator.dart';
import '../../benchmark/src/golden_compare.dart';
import '../../benchmark/src/stress_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mode = (Platform.environment['BENCHMARK_GOLDEN_MODE'] ?? '')
      .toLowerCase()
      .trim();

  test(
    'benchmark golden checkpoints (${mode.isEmpty ? "compare" : mode})',
    () async {
      final fixture = StressFixture.load();
      final timeline = buildBenchmarkTimeline(
        anchorRaHours: kAnchorRaHours,
        anchorDecDeg: kAnchorDecDeg,
        frameCount: 180,
      );

      if (mode == 'capture') {
        await captureGoldens(fixture, timeline);
        // ignore: avoid_print
        print(
          'Captured ${goldenCheckpoints(timeline).length} golden checkpoints '
          'to ${goldensDir()}/',
        );
        return;
      }

      final comparisons = await compareGoldens(fixture, timeline);
      expect(comparisons, isNotEmpty);

      for (final c in comparisons) {
        // ignore: avoid_print
        print(c.toString());
      }

      final missing = comparisons.where((c) => c.baselineMissing).toList();
      expect(
        missing,
        isEmpty,
        reason:
            'Missing baseline goldens: ${missing.map((c) => c.name).join(", ")}. '
            'Run with BENCHMARK_GOLDEN_MODE=capture to create them.',
      );

      for (final c in comparisons) {
        expect(c.passed, isTrue, reason: 'Golden checkpoint regressed: $c');
      }
    },
  );
}
