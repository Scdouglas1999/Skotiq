import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/frame_timing_probe.dart';

/// [FrameTiming] wants the full vsync phase vector; only the build and raster
/// spans are read back, so the rest are pinned at a fixed origin.
FrameTiming _frame({required int buildMicros, required int rasterMicros}) {
  const start = 1000000;
  final buildEnd = start + buildMicros;
  final rasterEnd = buildEnd + rasterMicros;
  return FrameTiming(
    vsyncStart: start,
    buildStart: start,
    buildFinish: buildEnd,
    rasterStart: buildEnd,
    rasterFinish: rasterEnd,
    rasterFinishWallTime: rasterEnd,
  );
}

void main() {
  group('frameTimingLine', () {
    // The zero case is the whole reason the probe exists: an idle app that
    // produces NO frames must say so out loud. A silent probe reads exactly
    // like a probe that failed to start, which is how the idle-CPU finding got
    // its severity wrong twice.
    test('an idle window reports zero frames rather than staying silent', () {
      expect(
        frameTimingLine(const [], const Duration(seconds: 5)),
        '[frame-timing] window=5.0s frames=0 fps=0.0',
      );
    });

    test('fps is frames divided by the window, not a frame count', () {
      final frames = List.generate(
        300,
        (_) => _frame(buildMicros: 1000, rasterMicros: 2000),
      );
      expect(
        frameTimingLine(frames, const Duration(seconds: 5)),
        contains('frames=300 fps=60.0'),
      );
      // Same frames, longer window -> lower rate. Pins that the divisor is the
      // window and not a hard-coded 60.
      expect(
        frameTimingLine(frames, const Duration(seconds: 10)),
        contains('frames=300 fps=30.0'),
      );
    });

    test('reports build and raster averages separately', () {
      // Averages 2.0 ms build / 8.0 ms raster. Keeping the two apart is what
      // distinguishes "the UI thread is rebuilding constantly" from "the
      // rasteriser is slow", which have different causes and different fixes.
      final frames = [
        _frame(buildMicros: 1000, rasterMicros: 6000),
        _frame(buildMicros: 3000, rasterMicros: 10000),
      ];
      final line = frameTimingLine(frames, const Duration(seconds: 1));
      expect(line, contains('buildAvgMs=2.0'));
      expect(line, contains('rasterAvgMs=8.0'));
    });

    test('p95 reports a tail frame, not the mean', () {
      // 94 frames at 1 ms and 6 at 100 ms: the mean lands at a comfortable
      // ~7 ms and hides the fact that six frames in a hundred blew a 16 ms
      // budget by 6x. The percentile is the number that makes that visible.
      final frames = [
        for (var i = 0; i < 94; i++)
          _frame(buildMicros: 1000, rasterMicros: 1000),
        for (var i = 0; i < 6; i++)
          _frame(buildMicros: 1000, rasterMicros: 100000),
      ];
      final line = frameTimingLine(frames, const Duration(seconds: 1));
      expect(line, contains('rasterAvgMs=6.9'));
      expect(line, contains('rasterP95Ms=100.0'));
    });

    test('a single-frame window does not run off the end of the samples', () {
      final line = frameTimingLine([
        _frame(buildMicros: 4000, rasterMicros: 7000),
      ], const Duration(seconds: 1));
      expect(line, contains('buildP95Ms=4.0'));
      expect(line, contains('rasterP95Ms=7.0'));
    });
  });

  group('startFrameTimingProbe', () {
    testWidgets('stays inert when it has not been armed', (tester) async {
      final lines = <String>[];

      final stop = startFrameTimingProbe(
        window: const Duration(seconds: 1),
        emit: lines.add,
        enabled: false,
      );

      // Long enough for thirty windows to have fired. An unarmed probe must
      // register no timer at all, so a shipping build pays nothing for it —
      // and the binding's own pending-timer invariant is what proves it, since
      // this test never cancels anything.
      await tester.pump(const Duration(seconds: 30));

      expect(lines, isEmpty);
      stop();
    });

    testWidgets('armed, it reports the window it observed', (tester) async {
      final lines = <String>[];
      final stop = startFrameTimingProbe(
        window: const Duration(seconds: 5),
        emit: lines.add,
        enabled: true,
      );

      // No frames are produced here, so this pins the idle path end to end:
      // timer fires, line is emitted, and it says zero.
      await tester.pump(const Duration(seconds: 5));

      // The live probe always attaches an image-cache reading, so the idle
      // line carries the cache too — that is the pairing the thumbnail work
      // needs: "nothing painted, and here is what the cache was holding".
      expect(lines, hasLength(1));
      expect(
        lines.single,
        startsWith('[frame-timing] window=5.0s frames=0 fps=0.0 blockedMs='),
      );
      expect(lines.single, contains('imgCacheMB='));
      expect(lines.single, contains('imgCacheImages='));
      expect(lines.single, contains('imgCacheLive='));
      // Inside the body, not addTearDown: the binding checks for pending
      // timers before tear-downs run.
      stop();
    });
  });

  group('ImageCacheReading', () {
    test('renders bytes as megabytes alongside both counts', () {
      const reading = ImageCacheReading(
        sizeBytes: 3670016, // 3.5 MiB
        imageCount: 118,
        liveImageCount: 24,
      );
      expect(
        reading.toString(),
        'imgCacheMB=3.5 imgCacheImages=118 imgCacheLive=24',
      );
    });

    // The distinction is the diagnosis. `imageCount` far above `liveImageCount`
    // with a large `sizeBytes` is the signature of thumbnails decoded at full
    // resolution: the cache is full of frames nothing is showing any more, and
    // it is about to evict the ones that are.
    test('carries live and total counts separately', () {
      const reading = ImageCacheReading(
        sizeBytes: 104857600,
        imageCount: 1000,
        liveImageCount: 8,
      );
      expect(reading.imageCount, 1000);
      expect(reading.liveImageCount, 8);
      expect(reading.toString(), contains('imgCacheMB=100.0'));
    });

    testWidgets('reads the binding it is given', (tester) async {
      final reading = ImageCacheReading.now();
      final cache = PaintingBinding.instance.imageCache;
      expect(reading.sizeBytes, cache.currentSizeBytes);
      expect(reading.imageCount, cache.currentSize);
      expect(reading.liveImageCount, cache.liveImageCount);
    });
  });

  group('frameTimingLine isolate overrun', () {
    // This is the number the thumbnail freeze needed and nothing had: a
    // blocked UI isolate produces no frames, and neither does an idle one, so
    // `frames=0` cannot tell them apart. A late report can only mean the
    // isolate could not run the probe's own timer.
    test('reports how far past the window the report arrived', () {
      final line = frameTimingLine(
        const [],
        const Duration(seconds: 5),
        isolateOverrun: const Duration(milliseconds: 8420),
      );
      expect(
        line,
        '[frame-timing] window=5.0s frames=0 fps=0.0 blockedMs=8420.0',
      );
    });

    test('a punctual report says zero rather than omitting the field', () {
      final line = frameTimingLine(
        const [],
        const Duration(seconds: 5),
        isolateOverrun: Duration.zero,
      );
      expect(line, endsWith('blockedMs=0.0'));
    });

    test('omits the field entirely when no overrun is supplied', () {
      final line = frameTimingLine(const [], const Duration(seconds: 5));
      expect(line, isNot(contains('blockedMs')));
    });

    test('orders blockedMs before the cache section', () {
      final line = frameTimingLine(
        const [],
        const Duration(seconds: 5),
        isolateOverrun: const Duration(milliseconds: 120),
        imageCache: const ImageCacheReading(
          sizeBytes: 0,
          imageCount: 0,
          liveImageCount: 0,
        ),
      );
      expect(
        line,
        '[frame-timing] window=5.0s frames=0 fps=0.0 blockedMs=120.0 '
        'imgCacheMB=0.0 imgCacheImages=0 imgCacheLive=0',
      );
    });

    testWidgets('the live probe always reports the field', (tester) async {
      final lines = <String>[];
      final stop = startFrameTimingProbe(
        window: const Duration(seconds: 1),
        emit: lines.add,
        enabled: true,
      );

      await tester.pump(const Duration(seconds: 1));

      expect(lines, hasLength(1));
      final blocked = RegExp(r'blockedMs=([0-9.]+)').firstMatch(lines.single);
      expect(blocked, isNotNull);
      expect(double.parse(blocked!.group(1)!), isNonNegative);
      stop();
    });
  });

  group('frameTimingLine image cache', () {
    test('omits the cache section when no reading is supplied', () {
      final line = frameTimingLine(const [], const Duration(seconds: 5));
      expect(line, '[frame-timing] window=5.0s frames=0 fps=0.0');
    });

    test('appends the cache section to a window that did produce frames', () {
      final line = frameTimingLine(
        [_frame(buildMicros: 1000, rasterMicros: 2000)],
        const Duration(seconds: 1),
        imageCache: const ImageCacheReading(
          sizeBytes: 1048576,
          imageCount: 4,
          liveImageCount: 2,
        ),
      );
      expect(line, endsWith('imgCacheMB=1.0 imgCacheImages=4 imgCacheLive=2'));
      expect(line, contains('buildAvgMs=1.0'));
    });
  });
}
