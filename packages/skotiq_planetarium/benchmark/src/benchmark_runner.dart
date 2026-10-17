// Core measurement loop for the planetarium paint benchmark.
//
// Headless and deterministic: builds the real [SkyCanvasPainter] (+ FOV overlay)
// for each scripted camera frame, records paint() into a PictureRecorder, then
// RASTERIZES the recorded display list to a real bitmap (toImage) and reads the
// pixels back (toByteData) so the actual fill/blend/glow/atlas-blit cost is
// included — not just the cheap cost of building the op list. Each frame is
// timed with a high-resolution Stopwatch. A few warm-up frames are discarded so
// JIT/cache effects don't pollute the numbers.
//
// Why rasterize-and-read-back: recording paint() alone only builds a Skia
// display list and finishes in ~1ms regardless of scene weight, so it is blind
// to overdraw, blur passes and fill rate — the things optimization actually
// changes. Forcing the pixels to materialize makes the timing track real render
// work and respond to optimizations. This uses the software rasterizer under
// `flutter test` (no GPU), so it is a CPU-side proxy for on-device GPU cost:
// directionally faithful for overdraw/fill/blend and, crucially, deterministic
// and responsive. True end-to-end GPU FPS is captured separately by the
// integration_test using Flutter FrameTiming. See benchmark/README.md.

import 'dart:io';
import 'dart:ui' as ui;

import 'benchmark_scene.dart';
import 'camera_timeline.dart';
import 'stress_fixture.dart';

/// Aggregated result of one benchmark run. Mirrors the stable results JSON
/// schema documented in benchmark/README.md.
class BenchmarkResult {
  final double p50Ms;
  final double p95Ms;
  final double p99Ms;
  final double meanMs;
  final double avgFps;
  final double rssMb;
  final int objectsDrawn;
  final int frames;
  final String scene;
  final String note;

  const BenchmarkResult({
    required this.p50Ms,
    required this.p95Ms,
    required this.p99Ms,
    required this.meanMs,
    required this.avgFps,
    required this.rssMb,
    required this.objectsDrawn,
    required this.frames,
    required this.scene,
    required this.note,
  });

  /// Stable on-disk schema. Field order/names are part of the contract — the
  /// optimization loop diffs successive runs by these keys.
  Map<String, dynamic> toJson() => {
    'p50Ms': _round(p50Ms),
    'p95Ms': _round(p95Ms),
    'p99Ms': _round(p99Ms),
    'avgFps': _round(avgFps),
    'rssMb': _round(rssMb),
    'objectsDrawn': objectsDrawn,
    'frames': frames,
    'scene': scene,
    'note': note,
  };

  static double _round(double v) => double.parse(v.toStringAsFixed(3));
}

/// Run the full paint benchmark over the scripted timeline.
///
/// [warmupFrames] paints are run and discarded before timing begins. The
/// remaining [CameraFrame]s are each timed once. Returns the aggregated result;
/// the caller decides whether to persist it.
Future<BenchmarkResult> runPaintBenchmark({
  required StressFixture fixture,
  required List<CameraFrame> timeline,
  int warmupFrames = 8,
  String note = '',
}) async {
  const size = kBenchmarkCanvasSize;

  // Warm-up: render the first few frames without timing so lazy atlas baking,
  // projection-cache priming and JIT warm-up don't land in the measured set.
  for (var i = 0; i < warmupFrames && i < timeline.length; i++) {
    await _paintFrame(fixture, timeline[i], size);
  }

  final timingsMs = <double>[];
  var peakRssBytes = ProcessInfo.currentRss;
  var densestObjects = 0;

  for (final frame in timeline) {
    final sw = Stopwatch()..start();
    await _paintFrame(fixture, frame, size);
    sw.stop();
    timingsMs.add(sw.elapsedMicroseconds / 1000.0);

    final rss = ProcessInfo.currentRss;
    if (rss > peakRssBytes) peakRssBytes = rss;

    // Cheap drawn-primitive proxy: count catalog objects whose centre projects
    // inside the canvas at this frame. The densest frame's count is reported.
    final n = _countOnScreen(fixture, frame, size);
    if (n > densestObjects) densestObjects = n;
  }

  final sorted = [...timingsMs]..sort();
  final mean = sorted.reduce((a, b) => a + b) / sorted.length;

  return BenchmarkResult(
    p50Ms: _percentile(sorted, 0.50),
    p95Ms: _percentile(sorted, 0.95),
    p99Ms: _percentile(sorted, 0.99),
    meanMs: mean,
    avgFps: mean > 0 ? 1000.0 / mean : 0,
    rssMb: peakRssBytes / (1024 * 1024),
    objectsDrawn: densestObjects,
    frames: timingsMs.length,
    scene: fixture.composition.split('\n').first,
    note: note,
  );
}

/// Render one frame (sky + FOV overlay) and rasterize it to real pixels. Used by
/// both the warm-up and timed loops so they do identical work.
///
/// The recorded display list is rasterized via [ui.Picture.toImage] and the
/// pixels are read back with [ui.Image.toByteData], which forces the raster to
/// actually execute (overdraw, blends, glow blur, atlas blits) rather than being
/// deferred or elided. That readback is what makes the timing track real render
/// cost. Everything is disposed each frame to avoid leaking images/pictures
/// across the (potentially hundreds of) timed frames.
Future<void> _paintFrame(
  StressFixture fixture,
  CameraFrame frame,
  ui.Size size,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  buildSkyPainter(fixture: fixture, frame: frame).paint(canvas, size);
  buildFovPainter(frame).paint(canvas, size);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(
      size.width.round(),
      size.height.round(),
    );
    try {
      // Force full rasterization to memory; the result is intentionally unused.
      await image.toByteData();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

/// Number of catalog objects (stars + DSOs) whose centre falls within the
/// canvas for [frame]. A cheap stand-in for "primitives drawn" — exact glyph
/// counts vary per layer, but on-screen object count tracks scene density.
int _countOnScreen(StressFixture fixture, CameraFrame frame, ui.Size size) {
  final scale =
      (size.width < size.height ? size.width : size.height) /
      2 /
      (frame.fieldOfViewDeg / 2);
  final cx = size.width / 2;
  final cy = size.height / 2;
  var count = 0;

  bool onScreen(double raHours, double decDeg) {
    var dRaHours = raHours - frame.centerRaHours;
    if (dRaHours > 12) dRaHours -= 24;
    if (dRaHours < -12) dRaHours += 24;
    // Small-angle planar approximation — adequate for an on-screen tally.
    final dx = dRaHours * 15.0 * scale;
    final dy = -(decDeg - frame.centerDecDeg) * scale;
    final px = cx + dx;
    final py = cy + dy;
    return px >= 0 && px <= size.width && py >= 0 && py <= size.height;
  }

  for (final s in fixture.stars) {
    if (onScreen(s.coordinates.ra, s.coordinates.dec)) count++;
  }
  for (final d in fixture.dsos) {
    if (onScreen(d.coordinates.ra, d.coordinates.dec)) count++;
  }
  return count;
}

/// Nearest-rank percentile of an already-sorted ascending list of timings.
double _percentile(List<double> sortedMs, double q) {
  if (sortedMs.isEmpty) return 0;
  if (sortedMs.length == 1) return sortedMs.first;
  final rank = (q * (sortedMs.length - 1)).round();
  return sortedMs[rank.clamp(0, sortedMs.length - 1)];
}

/// Persist [result] to benchmark/results/latest.json (pretty-printed). The
/// results dir is gitignored; this file is a fresh artifact each run.
void writeResults(BenchmarkResult result, {String? path}) {
  final out = File(path ?? 'benchmark/results/latest.json');
  out.parent.createSync(recursive: true);
  // Hand-roll a stable, indented encoding (avoids importing dart:convert just
  // for one call site; keeps key order identical to toJson()).
  final json = result.toJson();
  final buf = StringBuffer('{\n');
  final entries = json.entries.toList();
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    final v = e.value;
    final encoded = v is String ? _jsonString(v) : '$v';
    buf.write('  ${_jsonString(e.key)}: $encoded');
    buf.write(i == entries.length - 1 ? '\n' : ',\n');
  }
  buf.write('}\n');
  out.writeAsStringSync(buf.toString());
}

String _jsonString(String s) {
  final escaped = s
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return '"$escaped"';
}
