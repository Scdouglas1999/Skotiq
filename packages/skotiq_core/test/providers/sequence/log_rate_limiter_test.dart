// One line can consume the whole in-app log ring.
//
// `SequenceExecutor._handleSequencerEvent` traces EVERY backend event at debug
// level ("Received event: type=…, category=…"). At ~5 lines/s that fills
// LoggingService's 1000-entry ring in ~3 minutes, leaving Settings > Advanced >
// Logs showing nothing but `SequenceExecutor` DBG rows with no other producer
// in its source dropdown, and any diagnostic worth reading — the scheduler's
// reconcile line included — gone before the operator looks.
//
// The trace is kept (it is genuinely useful when an event goes missing) but
// rate-limited PER EVENT TYPE, so a burst of one chatty type collapses while a
// type that has not been seen recently is never hidden behind it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/sequence/log_rate_limiter.dart';

void main() {
  late DateTime now;
  LogRateLimiter build() =>
      LogRateLimiter(window: const Duration(seconds: 5), clock: () => now);

  setUp(() => now = DateTime(2026, 8, 14, 0, 6, 0));

  test('the first line of a key is always admitted', () {
    final limiter = build();
    expect(limiter.admit('InstructionProgress', 'a'), 'a');
  });

  test('a burst inside the window collapses to one line', () {
    final limiter = build();
    expect(limiter.admit('InstructionProgress', 'a'), isNotNull);
    for (var i = 0; i < 100; i++) {
      now = now.add(const Duration(milliseconds: 20));
      expect(limiter.admit('InstructionProgress', 'a'), isNull);
    }
  });

  test('the suppressed count is reported, never silently dropped', () {
    final limiter = build();
    limiter.admit('InstructionProgress', 'first');
    for (var i = 0; i < 9; i++) {
      now = now.add(const Duration(milliseconds: 100));
      limiter.admit('InstructionProgress', 'skipped');
    }
    now = now.add(const Duration(seconds: 6));

    expect(
      limiter.admit('InstructionProgress', 'next'),
      'next (+9 suppressed in the last 5s)',
    );
  });

  test('a quiet window admits with no suffix', () {
    final limiter = build();
    limiter.admit('Stopped', 'first');
    now = now.add(const Duration(seconds: 6));
    expect(limiter.admit('Stopped', 'second'), 'second');
  });

  test('a rare event type is never hidden behind a chatty one', () {
    // The whole point: `Stopped` arrives once, in the middle of an
    // InstructionProgress flood, and must still be logged.
    final limiter = build();
    limiter.admit('InstructionProgress', 'progress');
    for (var i = 0; i < 50; i++) {
      now = now.add(const Duration(milliseconds: 20));
      limiter.admit('InstructionProgress', 'progress');
    }
    expect(limiter.admit('Stopped', 'the operator stopped the run'), isNotNull);
  });

  test('keys are pruned so a long night cannot grow the map without bound', () {
    final limiter = build();
    for (var i = 0; i < 500; i++) {
      now = now.add(const Duration(seconds: 30));
      limiter.admit('type-$i', 'x');
    }
    expect(limiter.trackedKeys, lessThan(50));
  });

  // The unit above is only worth having if the executor actually uses it. This
  // is the guard against the trace being restored to an unconditional
  // `_logger.debug` — the shape that made the log unreadable in the first
  // place.
  test('the executor traces backend events THROUGH the limiter', () {
    final source = File(
      'lib/src/providers/sequence/sequence_executor/run_event_handler.dart',
    ).readAsStringSync();
    final handler = source.substring(
      source.indexOf('void handle(SkotiqEvent raw)'),
      source.indexOf('SequencerRunEvent.fromSkotiqEvent('),
    );
    expect(handler, contains('_eventTraceLimiter.admit('));
    expect(
      handler,
      isNot(contains("_logger.debug(\n      'Received event")),
      reason: 'the per-event trace must not be logged unconditionally again',
    );
  });
}
