// On-display animation harness for the FrameTiming integration test.
//
// Hosts the real planetarium paint pipeline ([SkyCanvasPainter] + FOV overlay,
// the exact painters InteractiveSkyView drives) inside a CustomPaint that
// animates across the scripted benchmark timeline. Unlike the headless paint
// benchmark, this widget is pumped on a real device/display so Flutter's
// FrameTiming reports genuine build + raster milliseconds (GPU included).
//
// It paints the same painter InteractiveSkyView uses, but feeds the committed
// deterministic fixture directly rather than the live catalog provider graph, so
// the timing reflects the fixed worst-case scene and is reproducible.

import 'package:flutter/material.dart';

import 'benchmark_scene.dart';
import 'camera_timeline.dart';
import 'stress_fixture.dart';

/// A full-screen animated planetarium driven by the benchmark timeline.
///
/// Advances through [timeline] over [duration], repainting every tick so the
/// host can capture per-frame build/raster timing. Calls [onCompleted] once the
/// animation finishes.
class FrameTimingHarness extends StatefulWidget {
  final StressFixture fixture;
  final List<CameraFrame> timeline;
  final Duration duration;
  final VoidCallback? onCompleted;

  const FrameTimingHarness({
    super.key,
    required this.fixture,
    required this.timeline,
    this.duration = const Duration(seconds: 6),
    this.onCompleted,
  });

  @override
  State<FrameTimingHarness> createState() => _FrameTimingHarnessState();
}

class _FrameTimingHarnessState extends State<FrameTimingHarness>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onCompleted?.call();
        }
      });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  CameraFrame _frameForProgress(double t) {
    final n = widget.timeline.length;
    if (n == 0) {
      throw StateError('FrameTimingHarness given an empty timeline');
    }
    final idx = (t.clamp(0.0, 1.0) * (n - 1)).round();
    return widget.timeline[idx];
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF000000),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final frame = _frameForProgress(_controller.value);
          return CustomPaint(
            painter: buildSkyPainter(fixture: widget.fixture, frame: frame),
            foregroundPainter: buildFovPainter(frame),
            size: kBenchmarkCanvasSize,
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}
