// Headless paint-pipeline benchmark for the planetarium.
//
// Run from the package root:
//   flutter test test/benchmark/paint_benchmark_test.dart
//
// Loads the committed deterministic stress fixture, drives the scripted camera
// timeline, times each frame's rasterize-and-readback (real fill/blend/glow
// cost via the software rasterizer) and writes the aggregated result to
// benchmark/results/latest.json. No GPU, window or network is required.
//
// Honesty note: this is a CPU-side rasterization proxy, not on-device GPU FPS.
// See benchmark/README.md and integration_test/frame_timing_test.dart for the
// real FrameTiming measurement.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/src/benchmark_runner.dart';
import '../../benchmark/src/camera_timeline.dart';
import '../../benchmark/src/fixture_generator.dart';
import '../../benchmark/src/stress_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('planetarium paint benchmark produces results JSON', () async {
    final fixture = StressFixture.load();

    // Sanity: the committed fixture must actually be the dense worst case.
    expect(
      fixture.stars.length,
      greaterThan(5000),
      reason: 'fixture is not dense — regenerate it',
    );
    expect(fixture.dsos.length, greaterThan(100));
    expect(fixture.milkyWayPoints, isNotEmpty);

    final timeline = buildBenchmarkTimeline(
      anchorRaHours: kAnchorRaHours,
      anchorDecDeg: kAnchorDecDeg,
      frameCount: 180,
    );
    expect(timeline.length, 180);

    final result = await runPaintBenchmark(
      fixture: fixture,
      timeline: timeline,
      warmupFrames: 8,
      note:
          'headless rasterize-and-readback time (CPU raster proxy); '
          'balanced quality; $kBenchmarkCanvasDescription',
    );

    // The numbers must be real and sane.
    expect(result.frames, 180);
    expect(result.meanMs, greaterThan(0));
    expect(result.p50Ms, greaterThan(0));
    expect(result.p99Ms, greaterThanOrEqualTo(result.p50Ms));
    expect(result.avgFps, greaterThan(0));
    expect(result.rssMb, greaterThan(0));
    expect(result.objectsDrawn, greaterThan(0));

    writeResults(result);
    final out = File('benchmark/results/latest.json');
    expect(out.existsSync(), isTrue);

    // ignore: avoid_print
    print(
      'Paint benchmark: p50=${result.p50Ms}ms p95=${result.p95Ms}ms '
      'p99=${result.p99Ms}ms avgFps=${result.avgFps.toStringAsFixed(1)} '
      'rss=${result.rssMb.toStringAsFixed(1)}MB '
      'objectsDrawn=${result.objectsDrawn} -> ${out.path}',
    );
  });
}

/// Short human description of the benchmark canvas, embedded in the result note.
const String kBenchmarkCanvasDescription = '1280x800';
