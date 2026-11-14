import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/frame_timing_probe.dart';

/// Synthetic engine phases with an optional queue delay before the build.
FrameTiming _frame({
  required int buildMicros,
  required int rasterMicros,
  int queueMicros = 0,
}) {
  const start = 1000000;
  final buildStart = start + queueMicros;
  final buildEnd = buildStart + buildMicros;
  final rasterEnd = buildEnd + rasterMicros;
  return FrameTiming(
    vsyncStart: start,
    buildStart: buildStart,
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

    test('late reports divide frame count by actual elapsed time', () {
      final line = frameTimingLine(
        List.generate(300, (_) => _frame(buildMicros: 100, rasterMicros: 200)),
        const Duration(seconds: 5),
        elapsedWindow: const Duration(seconds: 10),
      );
      expect(line, contains('window=10.0s frames=300 fps=30.0'));
      expect(line, contains('nominalWindow=5.0s'));
    });

    test('p99 and maximum preserve rare long frames separately', () {
      final line = frameTimingLine([
        for (var i = 0; i < 98; i++)
          _frame(buildMicros: 1000, rasterMicros: 2000),
        _frame(buildMicros: 20000, rasterMicros: 30000),
        _frame(buildMicros: 100000, rasterMicros: 200000),
      ], const Duration(seconds: 5));
      expect(line, contains('buildP95Ms=1.0 rasterP95Ms=2.0'));
      expect(line, contains('buildP99Ms=20.0 rasterP99Ms=30.0'));
      expect(line, contains('buildMaxMs=100.0 rasterMaxMs=200.0'));
    });

    test('display and target budgets count strictly over-budget stages', () {
      final line = frameTimingLine(
        [
          _frame(buildMicros: 4000, rasterMicros: 4001),
          _frame(buildMicros: 4001, rasterMicros: 4000),
          _frame(buildMicros: 17000, rasterMicros: 17000),
        ],
        const Duration(seconds: 1),
        displayRefreshHz: 60,
        targetRefreshHz: 250,
      );
      expect(line, contains('displayHz=60.000'));
      expect(line, contains('targetHz=250.000'));
      expect(line, contains('buildOverDisplayBudget=1'));
      expect(line, contains('rasterOverDisplayBudget=1'));
      expect(line, contains('buildOverTargetBudget=2'));
      expect(line, contains('rasterOverTargetBudget=2'));
    });

    test('240 Hz count uses the unrounded 4.1667 millisecond budget', () {
      final line = frameTimingLine(
        [_frame(buildMicros: 4166, rasterMicros: 4167)],
        const Duration(seconds: 1),
        displayRefreshHz: 240,
      );
      expect(line, contains('buildOverDisplayBudget=0'));
      expect(line, contains('rasterOverDisplayBudget=1'));
    });

    test('pipeline latency is distinct from per-stage budget overruns', () {
      final line = frameTimingLine(
        [_frame(buildMicros: 2000, rasterMicros: 2000, queueMicros: 3000)],
        const Duration(seconds: 1),
        displayRefreshHz: 240,
      );
      expect(line, contains('latencyP95Ms=7.0'));
      expect(line, contains('buildOverDisplayBudget=0'));
      expect(line, contains('rasterOverDisplayBudget=0'));
      expect(line.toLowerCase(), isNot(contains('dropped')));
    });

    test('unknown or invalid refresh rates do not invent a budget', () {
      for (final rate in [null, 0.0, -1.0, double.nan, double.infinity]) {
        final line = frameTimingLine(
          [_frame(buildMicros: 1000, rasterMicros: 2000)],
          const Duration(seconds: 1),
          displayRefreshHz: rate,
          targetRefreshHz: rate,
        );
        expect(line, isNot(contains('Budget')));
        expect(line, isNot(contains('Hz=')));
      }
    });
  });

  group('startFrameTimingProbe', () {
    testWidgets('stays inert when it has not been armed', (tester) async {
      final lines = <String>[];

      final stop = startFrameTimingProbe(
        window: const Duration(seconds: 1),
        emit: lines.add,
        enabled: false,
        rawTimingsPath: '/this/path/must/not/be/opened/frame-timing.jsonl',
      );

      // Long enough for thirty windows to have fired. An unarmed probe must
      // register no timer at all, so a shipping build pays nothing for it —
      // and the binding's own pending-timer invariant is what proves it, since
      // this test never cancels anything.
      await tester.pump(const Duration(seconds: 30));

      expect(lines, isEmpty);
      await stop();
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
      expect(lines.single, startsWith('[frame-timing] window='));
      expect(lines.single, contains('frames=0 fps=0.0 nominalWindow=5.0s'));
      expect(lines.single, contains('blockedMs='));
      expect(lines.single, contains('imgCacheMB='));
      expect(lines.single, contains('imgCacheImages='));
      expect(lines.single, contains('imgCacheLive='));
      // Inside the body, not addTearDown: the binding checks for pending
      // timers before tear-downs run.
      await stop();
    });

    testWidgets('raw batches append and cleanup flushes the final batch', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('frame-probe-');
        final output = File('${directory.path}/timings.jsonl');
        await output.writeAsString('{"prior":true}\n');
        final stop = startFrameTimingProbe(
          enabled: true,
          rawTimingsPath: output.path,
        );
        try {
          tester.binding.platformDispatcher.onReportTimings!([
            _frame(buildMicros: 1000, rasterMicros: 2000, queueMicros: 500),
          ]);
          await stop();
          final lines = await output.readAsLines();
          expect(lines, hasLength(2));
          expect(jsonDecode(lines.first), {'prior': true});
          final batch = jsonDecode(lines.last) as Map<String, dynamic>;
          expect(batch['type'], 'frame-timing-batch');
          expect(DateTime.parse(batch['wallUtc'] as String).isUtc, isTrue);
          expect(batch['elapsedUs'], isNonNegative);
          final frame = (batch['frames'] as List).single as Map;
          expect(frame['vsyncStartUs'], 1000000);
          expect(frame['rasterFinishUs'], 1003500);
          expect(frame['buildUs'], 1000);
          expect(frame['rasterUs'], 2000);
          expect(frame['totalSpanUs'], 3500);
        } finally {
          await stop();
          await directory.delete(recursive: true);
        }
      });
    });

    testWidgets('raw output failure reports once and leaves probe stoppable', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('frame-probe-');
        final lines = <String>[];
        final stop = startFrameTimingProbe(
          enabled: true,
          emit: lines.add,
          rawTimingsPath: directory.path,
        );
        try {
          tester.binding.platformDispatcher.onReportTimings!([
            _frame(buildMicros: 1000, rasterMicros: 2000),
          ]);
          await stop();
          expect(
            lines.where((line) => line.contains('rawOutputError=')),
            hasLength(1),
          );
        } finally {
          await stop();
          await directory.delete();
        }
      });
    });
  });

  test('raw batch keeps receive clocks separate from engine timestamps', () {
    final batch = frameTimingBatch(
      [_frame(buildMicros: 1000, rasterMicros: 2000)],
      wallUtc: DateTime.parse('2026-11-13T20:00:00-05:00'),
      elapsed: const Duration(seconds: 9),
      displayRefreshHz: 60,
      targetRefreshHz: 240,
    );
    expect(batch['wallUtc'], '2026-11-14T01:00:00.000Z');
    expect(batch['elapsedUs'], 9000000);
    expect(batch['displayHz'], 60);
    expect(batch['targetHz'], 240);
    final frames = batch['frames'] as List;
    expect((frames.single as Map)['vsyncStartUs'], 1000000);
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
      await stop();
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
