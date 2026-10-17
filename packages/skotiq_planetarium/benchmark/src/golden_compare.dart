// Perceptual-diff golden comparator — the anti-cheat gate for the benchmark.
//
// Renders the real [SkyCanvasPainter] (+ FOV overlay) at a fixed set of
// checkpoint frames to a ui.Image, then either:
//   * captures: writes the PNG as the committed baseline under benchmark/goldens,
//   * compares: re-renders and computes a perceptual delta vs the baseline.
//
// The compare gate exists so an "optimization" that quietly drops a star, label,
// glow or line is caught even if it makes the timing numbers look better. The
// tolerance is tuned to ignore sub-~2/255 antialiasing jitter but flag any real
// missing primitive.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'benchmark_scene.dart';
import 'camera_timeline.dart';
import 'stress_fixture.dart';

/// Per-channel pixel delta below this (0..255) is treated as antialiasing
/// jitter and ignored when counting "changed" pixels.
const int kGoldenChannelTolerance = 2;

/// The gate fails if more than this fraction of pixels exceed
/// [kGoldenChannelTolerance] on any channel. A dropped star/label/line moves
/// far more than this; pure AA jitter stays well under it.
const double kGoldenMaxChangedFraction = 0.002; // 0.2%

/// Result of comparing one checkpoint against its baseline.
class GoldenComparison {
  final String name;
  final int maxChannelDelta;
  final double changedFraction;
  final bool baselineMissing;

  const GoldenComparison({
    required this.name,
    required this.maxChannelDelta,
    required this.changedFraction,
    required this.baselineMissing,
  });

  bool get passed =>
      !baselineMissing && changedFraction <= kGoldenMaxChangedFraction;

  @override
  String toString() => baselineMissing
      ? '$name: BASELINE MISSING'
      : '$name: maxDelta=$maxChannelDelta '
            'changed=${(changedFraction * 100).toStringAsFixed(4)}% '
            '(limit ${(kGoldenMaxChangedFraction * 100).toStringAsFixed(2)}%) '
            '${passed ? "OK" : "FAIL"}';
}

/// The checkpoint frames sampled from the [timeline] for golden capture/compare.
/// Five spread across the path: wide start, mid-pan, deep zoom, post-time-
/// advance, wide return.
List<({String name, CameraFrame frame})> goldenCheckpoints(
  List<CameraFrame> timeline,
) {
  if (timeline.isEmpty) return const [];
  ({String name, CameraFrame frame}) at(String name, double t) {
    final idx = ((timeline.length - 1) * t).round();
    return (name: name, frame: timeline[idx]);
  }

  return [
    at('00-wide-start', 0.0),
    at('01-mid-pan', 0.25),
    at('02-deep-zoom', 0.55),
    at('03-time-advanced', 0.80),
    at('04-wide-return', 1.0),
  ];
}

/// Directory holding the committed baseline PNGs.
String goldensDir() => 'benchmark/goldens';

/// Render one checkpoint to a PNG byte buffer (RGBA -> PNG).
Future<Uint8List> renderCheckpointPng(
  StressFixture fixture,
  CameraFrame frame,
) async {
  const size = kBenchmarkCanvasSize;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  buildSkyPainter(fixture: fixture, frame: frame).paint(canvas, size);
  buildFovPainter(frame).paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (png == null) {
    throw StateError('Failed to encode checkpoint PNG');
  }
  return png.buffer.asUint8List();
}

/// Decode a PNG into raw RGBA bytes + dimensions for pixel comparison.
Future<({Uint8List rgba, int width, int height})> _decodeRgba(
  Uint8List png,
) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (
    rgba: data!.buffer.asUint8List(),
    width: image.width,
    height: image.height,
  );
  image.dispose();
  codec.dispose();
  return result;
}

/// Capture mode: render every checkpoint and (over)write its baseline PNG.
Future<void> captureGoldens(
  StressFixture fixture,
  List<CameraFrame> timeline,
) async {
  final dir = Directory(goldensDir());
  dir.createSync(recursive: true);
  for (final cp in goldenCheckpoints(timeline)) {
    final png = await renderCheckpointPng(fixture, cp.frame);
    File('${dir.path}/${cp.name}.png').writeAsBytesSync(png);
  }
}

/// Compare mode: render every checkpoint and diff against its committed
/// baseline. Returns one [GoldenComparison] per checkpoint.
Future<List<GoldenComparison>> compareGoldens(
  StressFixture fixture,
  List<CameraFrame> timeline,
) async {
  final results = <GoldenComparison>[];
  for (final cp in goldenCheckpoints(timeline)) {
    final baselineFile = File('${goldensDir()}/${cp.name}.png');
    if (!baselineFile.existsSync()) {
      results.add(
        GoldenComparison(
          name: cp.name,
          maxChannelDelta: 0,
          changedFraction: 0,
          baselineMissing: true,
        ),
      );
      continue;
    }

    final freshPng = await renderCheckpointPng(fixture, cp.frame);
    final fresh = await _decodeRgba(freshPng);
    final baseline = await _decodeRgba(baselineFile.readAsBytesSync());

    if (fresh.width != baseline.width || fresh.height != baseline.height) {
      results.add(
        GoldenComparison(
          name: cp.name,
          maxChannelDelta: 255,
          changedFraction: 1.0,
          baselineMissing: false,
        ),
      );
      continue;
    }

    var maxDelta = 0;
    var changed = 0;
    final a = fresh.rgba;
    final b = baseline.rgba;
    final pixels = fresh.width * fresh.height;
    for (var p = 0; p < pixels; p++) {
      final i = p * 4;
      var pixelChanged = false;
      for (var c = 0; c < 4; c++) {
        final d = (a[i + c] - b[i + c]).abs();
        if (d > maxDelta) maxDelta = d;
        if (d > kGoldenChannelTolerance) pixelChanged = true;
      }
      if (pixelChanged) changed++;
    }

    results.add(
      GoldenComparison(
        name: cp.name,
        maxChannelDelta: maxDelta,
        changedFraction: pixels == 0 ? 0 : changed / pixels,
        baselineMissing: false,
      ),
    );
  }
  return results;
}
