import 'dart:async';
import 'dart:io';

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
/// Reports engine [FrameTiming] counts and the image cache's occupancy per
/// window to stdout. It is inert unless enabled and returns a cleanup callback
/// for tests.
void Function() startFrameTimingProbe({
  Duration window = const Duration(seconds: 5),
  void Function(String line) emit = _stdout,
  bool? enabled,
}) {
  final armed =
      enabled ?? Platform.environment['SKOTIQ_FRAME_TIMING'] == '1';
  if (!armed) {
    return () {};
  }

  final frames = <FrameTiming>[];
  void collect(List<FrameTiming> timings) => frames.addAll(timings);
  SchedulerBinding.instance.addTimingsCallback(collect);

  // A periodic timer, not a frame callback: the whole point is to report the
  // windows in which NO frame was produced, and a frame-driven report cannot
  // observe its own absence.
  //
  // The timer doubles as the isolate-responsiveness probe. It is scheduled on
  // the UI isolate's event loop, so it cannot fire while something is holding
  // that isolate: the gap between one report and the next, minus the window,
  // IS the time the isolate spent unable to run anything at all.
  final clock = Stopwatch()..start();
  var previous = Duration.zero;
  final timer = Timer.periodic(window, (_) {
    final elapsed = clock.elapsed;
    final overrun = elapsed - previous - window;
    previous = elapsed;
    emit(
      frameTimingLine(
        frames,
        window,
        imageCache: ImageCacheReading.now(),
        isolateOverrun: overrun.isNegative ? Duration.zero : overrun,
      ),
    );
    frames.clear();
  });

  return () {
    timer.cancel();
    SchedulerBinding.instance.removeTimingsCallback(collect);
  };
}

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
/// [isolateOverrun] is how much longer than [window] the report actually took
/// to arrive, reported as `blockedMs`. The probe's timer lives on the UI
/// isolate, so a late report is that isolate having been unable to run — the
/// one number a frame count cannot give, because a blocked isolate produces no
/// frames to count and an idle one produces none either. [imageCache] is
/// appended to both cases when supplied, so a window in which nothing painted
/// still says what the cache was holding.
String frameTimingLine(
  List<FrameTiming> frames,
  Duration window, {
  ImageCacheReading? imageCache,
  Duration? isolateOverrun,
}) {
  final seconds = window.inMicroseconds / Duration.microsecondsPerSecond;
  final fps = (frames.length / seconds).toStringAsFixed(1);
  final head = '[frame-timing] window=${seconds}s frames=${frames.length}';
  final blocked = isolateOverrun == null
      ? ''
      : ' blockedMs=${_ms(isolateOverrun.inMicroseconds.toDouble())}';
  final tail = '$blocked${imageCache == null ? '' : ' $imageCache'}';

  if (frames.isEmpty) {
    return '$head fps=0.0$tail';
  }

  final build = _Summary.of([
    for (final frame in frames) frame.buildDuration.inMicroseconds,
  ]);
  final raster = _Summary.of([
    for (final frame in frames) frame.rasterDuration.inMicroseconds,
  ]);
  return '$head fps=$fps '
      'buildAvgMs=${build.averageMs} rasterAvgMs=${raster.averageMs} '
      'buildP95Ms=${build.p95Ms} rasterP95Ms=${raster.p95Ms}$tail';
}

void _stdout(String line) => stdout.writeln(line);

String _ms(double micros) =>
    (micros / Duration.microsecondsPerMillisecond).toStringAsFixed(1);

class _Summary {
  final String averageMs;
  final String p95Ms;

  const _Summary(this.averageMs, this.p95Ms);

  factory _Summary.of(List<int> micros) {
    final sorted = List<int>.from(micros)..sort();
    final total = sorted.fold<int>(0, (sum, value) => sum + value);
    // Nearest-rank p95, clamped so a single-sample window reports that sample
    // rather than running off the end of the list.
    final rank = ((sorted.length * 95) / 100).ceil().clamp(1, sorted.length);
    return _Summary(
      _ms(total / sorted.length),
      _ms(sorted[rank - 1].toDouble()),
    );
  }
}
