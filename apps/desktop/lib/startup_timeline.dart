import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:skotiq_core/services.dart';

/// Where the time from launch to a usable app goes, logged once per start.
///
/// Marks are milliseconds since `main` began. Pre-main time (engine and VM
/// start) is not in them; `mainAtEpochMs` lets a launcher that noted when it
/// spawned the process work it out.
final StartupTimeline startupTimeline = StartupTimeline();

class StartupTimeline {
  StartupTimeline() : mainAt = DateTime.now(), _clock = Stopwatch()..start();

  final DateTime mainAt;
  final Stopwatch _clock;
  final List<(String, int)> _marks = [];

  void mark(String name) => _marks.add((name, _clock.elapsedMilliseconds));

  Map<String, Object?> _fields() => {
    'mainAtEpochMs': mainAt.millisecondsSinceEpoch,
    for (final (name, ms) in _marks) name: ms,
  };

  /// Logs the marks so far as one line.
  void log(LoggingService logger, String source, String message) {
    logger.info(message, source: source, fields: _fields());
  }

  /// Once the first frame is on screen, waits until the UI isolate stops
  /// stalling and logs the whole timeline.
  ///
  /// Settled means [quiet] passed in which no 16 ms tick ran more than
  /// [stall] late: clicks and frames are answered from there on. The longest
  /// stall before that is what the user felt as a frozen window.
  Future<void> reportWhenSettled(
    LoggingService logger,
    String source, {
    Duration quiet = const Duration(milliseconds: 500),
    Duration stall = const Duration(milliseconds: 50),
    Duration giveUp = const Duration(seconds: 30),
  }) async {
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    mark('first frame rasterized');
    const tick = Duration(milliseconds: 16);
    final settled = Completer<void>();
    var last = _clock.elapsedMicroseconds;
    var quietSince = last;
    var longestStallMs = 0;
    final timer = Timer.periodic(tick, (timer) {
      final now = _clock.elapsedMicroseconds;
      final lateMs = (now - last - tick.inMicroseconds) ~/ 1000;
      last = now;
      if (lateMs > stall.inMilliseconds) {
        quietSince = now;
        if (lateMs > longestStallMs) longestStallMs = lateMs;
      } else if (now - quietSince >= quiet.inMicroseconds) {
        settled.complete();
        timer.cancel();
      }
    });
    final settledInTime = await settled.future
        .then((_) => true)
        .timeout(giveUp, onTimeout: () => false);
    timer.cancel();
    _marks.add((
      settledInTime ? 'ui settled' : 'ui not settled after',
      quietSince ~/ 1000,
    ));
    _marks.add(('longest stall before settled', longestStallMs));
    log(logger, source, 'Start-up timeline');
  }
}
