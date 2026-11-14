import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

/// A reading of `PaintingBinding.instance.imageCache` at report time.
///
/// Reported alongside the frame rate because a decode-bound stall shows up
/// here before it shows up in the frame count: images decoded far larger than
/// the box that displays them blow through the cache's byte budget, so the
/// cache evicts and re-decodes them on every scroll, and the frame rate only
/// says "slow" without saying why.
class ImageCacheReading {
  /// Bytes of decoded image data the cache is holding.
  final int sizeBytes;

  /// Images in the cache, whether or not anything is displaying them.
  final int imageCount;

  /// Images the cache is holding that something on screen still references.
  final int liveImageCount;

  const ImageCacheReading({
    required this.sizeBytes,
    required this.imageCount,
    required this.liveImageCount,
  });

  /// Reads the binding's live cache. Requires an initialised binding.
  factory ImageCacheReading.now() {
    final cache = PaintingBinding.instance.imageCache;
    return ImageCacheReading(
      sizeBytes: cache.currentSizeBytes,
      imageCount: cache.currentSize,
      liveImageCount: cache.liveImageCount,
    );
  }

  String get _megabytes => (sizeBytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  String toString() =>
      'imgCacheMB=$_megabytes imgCacheImages=$imageCount '
      'imgCacheLive=$liveImageCount';
}

/// Opt-in frame-rate probe, armed by `SKOTIQ_FRAME_TIMING=1`.
///
/// Reports engine [FrameTiming] counts and image-cache occupancy to stdout.
/// `SKOTIQ_FRAME_TARGET_HZ` adds an explicit refresh target beside the engine's
/// reported rate. `SKOTIQ_FRAME_TIMING_JSONL` optionally appends raw batches to
/// a file. It is inert unless enabled; await cleanup to flush that file.
Future<void> Function() startFrameTimingProbe({
  Duration window = const Duration(seconds: 5),
  void Function(String line) emit = _stdout,
  bool? enabled,
  String? rawTimingsPath,
}) {
  final armed = enabled ?? Platform.environment['SKOTIQ_FRAME_TIMING'] == '1';
  if (!armed) {
    return () async {};
  }

  final clock = Stopwatch()..start();
  final targetHz = _validHz(
    double.tryParse(Platform.environment['SKOTIQ_FRAME_TARGET_HZ'] ?? ''),
  );
  final rawPath =
      rawTimingsPath ?? Platform.environment['SKOTIQ_FRAME_TIMING_JSONL'];
  final rawOutput = rawPath == null || rawPath.isEmpty
      ? null
      : _RawTimingOutput(rawPath, emit);
  final frames = <FrameTiming>[];
  void collect(List<FrameTiming> timings) {
    frames.addAll(timings);
    rawOutput?.add(
      frameTimingBatch(
        timings,
        wallUtc: DateTime.now().toUtc(),
        elapsed: clock.elapsed,
        displayRefreshHz: _displayRefreshHz(),
        targetRefreshHz: targetHz,
      ),
    );
  }

  SchedulerBinding.instance.addTimingsCallback(collect);

  // A periodic timer, not a frame callback: the whole point is to report the
  // windows in which NO frame was produced, and a frame-driven report cannot
  // observe its own absence.
  //
  // The timer doubles as the isolate-responsiveness probe. It is scheduled on
  // the UI isolate's event loop, so it cannot fire while something is holding
  // that isolate: the gap between one report and the next, minus the window,
  // measures timer lateness. OS scheduling, suspension and CPU throttling can
  // also delay it; this is not by itself proof of synchronous Dart work.
  var previous = Duration.zero;
  final timer = Timer.periodic(window, (_) {
    final elapsed = clock.elapsed;
    final elapsedWindow = elapsed - previous;
    final overrun = elapsedWindow - window;
    previous = elapsed;
    emit(
      frameTimingLine(
        frames,
        window,
        elapsedWindow: elapsedWindow,
        displayRefreshHz: _displayRefreshHz(),
        targetRefreshHz: targetHz,
        imageCache: ImageCacheReading.now(),
        isolateOverrun: overrun.isNegative ? Duration.zero : overrun,
      ),
    );
    frames.clear();
  });

  var stopped = false;
  return () async {
    if (stopped) return;
    stopped = true;
    timer.cancel();
    SchedulerBinding.instance.removeTimingsCallback(collect);
    await rawOutput?.close();
  };
}

double? _displayRefreshHz() =>
    _validHz(ui.PlatformDispatcher.instance.implicitView?.display.refreshRate);

double? _validHz(double? hz) => hz != null && hz.isFinite && hz > 0 ? hz : null;

/// Render one window's worth of [frames] as a single log line.
///
/// ```text
/// [frame-timing] window=5.0s frames=0 fps=0.0 blockedMs=0.0 imgCacheMB=0.0 imgCacheImages=0 imgCacheLive=0
/// [frame-timing] window=5.0s frames=312 fps=62.4 buildAvgMs=0.8 rasterAvgMs=6.1 buildP95Ms=1.9 rasterP95Ms=11.4 blockedMs=0.0 imgCacheMB=3.4 imgCacheImages=118 imgCacheLive=24
/// ```
///
/// The zero case prints deliberately rather than staying silent: "the app
/// produced no frames for five seconds" is the finding, and a silent probe is
/// indistinguishable from a probe that failed to start.
///
/// [elapsedWindow] is the actual interval between timer callbacks; [window]
/// is their requested period. Engine timing batches can cross window boundaries,
/// so the frame count is a production rate, not a presentation or dropped-frame
/// count. [isolateOverrun] is timer lateness, retained as `blockedMs` for log
/// compatibility; scheduling and CPU throttling can also cause lateness.
/// [imageCache] is
/// appended to both cases when supplied, so a window in which nothing painted
/// still says what the cache was holding.
String frameTimingLine(
  List<FrameTiming> frames,
  Duration window, {
  ImageCacheReading? imageCache,
  Duration? isolateOverrun,
  Duration? elapsedWindow,
  double? displayRefreshHz,
  double? targetRefreshHz,
}) {
  final actualWindow = elapsedWindow ?? window;
  final seconds = actualWindow.inMicroseconds / Duration.microsecondsPerSecond;
  if (seconds <= 0) {
    throw ArgumentError.value(
      actualWindow,
      'elapsedWindow',
      'must be positive',
    );
  }
  final fps = (frames.length / seconds).toStringAsFixed(1);
  final head = '[frame-timing] window=${seconds}s frames=${frames.length}';
  final displayHz = _validHz(displayRefreshHz);
  final targetHz = _validHz(targetRefreshHz);
  final context = [
    if (elapsedWindow != null)
      'nominalWindow=${window.inMicroseconds / Duration.microsecondsPerSecond}s',
    if (displayHz != null) 'displayHz=${displayHz.toStringAsFixed(3)}',
    if (displayHz != null)
      'displayBudgetMs=${(1000 / displayHz).toStringAsFixed(3)}',
    if (targetHz != null) 'targetHz=${targetHz.toStringAsFixed(3)}',
    if (targetHz != null)
      'targetBudgetMs=${(1000 / targetHz).toStringAsFixed(3)}',
  ];
  final blocked = isolateOverrun == null
      ? ''
      : ' blockedMs=${_ms(isolateOverrun.inMicroseconds.toDouble())}';
  final tail =
      '${context.isEmpty ? '' : ' ${context.join(' ')}'}'
      '$blocked${imageCache == null ? '' : ' $imageCache'}';

  if (frames.isEmpty) {
    return '$head fps=0.0$tail';
  }

  final build = _Summary.of([
    for (final frame in frames) frame.buildDuration.inMicroseconds,
  ]);
  final raster = _Summary.of([
    for (final frame in frames) frame.rasterDuration.inMicroseconds,
  ]);
  final latency = _Summary.of([
    for (final frame in frames) frame.totalSpan.inMicroseconds,
  ]);
  final budgets = [
    if (displayHz != null) ...[
      'buildOverDisplayBudget=${build.overBudget(displayHz)}',
      'rasterOverDisplayBudget=${raster.overBudget(displayHz)}',
    ],
    if (targetHz != null) ...[
      'buildOverTargetBudget=${build.overBudget(targetHz)}',
      'rasterOverTargetBudget=${raster.overBudget(targetHz)}',
    ],
  ];
  return '$head fps=$fps '
      'buildAvgMs=${build.averageMs} rasterAvgMs=${raster.averageMs} '
      'buildP95Ms=${build.p95Ms} rasterP95Ms=${raster.p95Ms} '
      'buildP99Ms=${build.p99Ms} rasterP99Ms=${raster.p99Ms} '
      'buildMaxMs=${build.maxMs} rasterMaxMs=${raster.maxMs} '
      'latencyP95Ms=${latency.p95Ms} latencyP99Ms=${latency.p99Ms} '
      'latencyMaxMs=${latency.maxMs}'
      '${budgets.isEmpty ? '' : ' ${budgets.join(' ')}'}$tail';
}

/// Raw engine timestamps retain cadence and pipeline latency without treating
/// the gap between two intentionally idle frames as dropped frames. Wall time
/// and elapsed time describe callback receipt, not the engine's clock origin.
Map<String, Object?> frameTimingBatch(
  List<FrameTiming> frames, {
  required DateTime wallUtc,
  required Duration elapsed,
  double? displayRefreshHz,
  double? targetRefreshHz,
}) => {
  'type': 'frame-timing-batch',
  'wallUtc': wallUtc.toUtc().toIso8601String(),
  'elapsedUs': elapsed.inMicroseconds,
  'displayHz': _validHz(displayRefreshHz),
  'targetHz': _validHz(targetRefreshHz),
  'frames': [
    for (final frame in frames)
      {
        'frameNumber': frame.frameNumber,
        'vsyncStartUs': frame.timestampInMicroseconds(ui.FramePhase.vsyncStart),
        'buildStartUs': frame.timestampInMicroseconds(ui.FramePhase.buildStart),
        'buildFinishUs': frame.timestampInMicroseconds(
          ui.FramePhase.buildFinish,
        ),
        'rasterStartUs': frame.timestampInMicroseconds(
          ui.FramePhase.rasterStart,
        ),
        'rasterFinishUs': frame.timestampInMicroseconds(
          ui.FramePhase.rasterFinish,
        ),
        'rasterFinishWallTimeUs': frame.timestampInMicroseconds(
          ui.FramePhase.rasterFinishWallTime,
        ),
        'buildUs': frame.buildDuration.inMicroseconds,
        'rasterUs': frame.rasterDuration.inMicroseconds,
        'totalSpanUs': frame.totalSpan.inMicroseconds,
      },
  ],
};

class _RawTimingOutput {
  _RawTimingOutput(String path, this._emit)
    : _sink = File(path).openWrite(mode: FileMode.append) {
    unawaited(_sink.done.then<void>((_) {}, onError: _reportError));
  }

  final IOSink _sink;
  final void Function(String) _emit;
  bool _failed = false;
  bool _closed = false;

  void _reportError(Object error, StackTrace stackTrace) {
    if (_failed) return;
    _failed = true;
    _emit('[frame-timing] rawOutputError=$error');
  }

  void add(Map<String, Object?> batch) {
    if (!_failed && !_closed) _sink.writeln(jsonEncode(batch));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.close().then<void>((_) {}, onError: _reportError);
  }
}

void _stdout(String line) => stdout.writeln(line);

String _ms(double micros) =>
    (micros / Duration.microsecondsPerMillisecond).toStringAsFixed(1);

class _Summary {
  final List<int> sorted;
  final String averageMs;

  const _Summary(this.sorted, this.averageMs);

  String get p95Ms => _percentile(95);
  String get p99Ms => _percentile(99);
  String get maxMs => _ms(sorted.last.toDouble());

  int overBudget(double hz) =>
      sorted.where((micros) => micros > 1000000 / hz).length;

  String _percentile(int percentile) {
    // Nearest rank keeps a single sample at index zero.
    final rank = ((sorted.length * percentile) / 100).ceil();
    return _ms(sorted[rank - 1].toDouble());
  }

  factory _Summary.of(List<int> micros) {
    final sorted = List<int>.from(micros)..sort();
    final total = sorted.fold<int>(0, (sum, value) => sum + value);
    return _Summary(sorted, _ms(total / sorted.length));
  }
}
