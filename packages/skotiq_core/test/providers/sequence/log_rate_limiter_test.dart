// One line can consume the whole in-app log ring.
//
// The executor (`RunEventHandler.handle`) traces EVERY backend event at debug
// level ("Received event: type=…, category=…"). At ~5 lines/s that fills
// LoggingService's 1000-entry ring in ~3 minutes, leaving Settings > Advanced >
// Logs showing nothing but `SequenceExecutor` DBG rows with no other producer
// in its source dropdown, and any diagnostic worth reading — the scheduler's
// reconcile line included — gone before the operator looks.
//
// The trace is kept (it is genuinely useful when an event goes missing) but
// rate-limited PER EVENT TYPE, so a burst of one chatty type collapses while a
// type that has not been seen recently is never hidden behind it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/sequence/log_rate_limiter.dart';
import 'package:skotiq_core/utils.dart';

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _CapturingLogger extends LoggingService {
  final List<String> lines = [];

  @override
  void log(
    LogLevel level,
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) {
    lines.add(message);
  }
}

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

  // The limiter is only worth having if the executor's event trace goes
  // through it: an unconditional per-event debug line is what filled the ring.
  group('the executor\'s event trace', () {
    late MockBackend backend;
    late StreamController<SkotiqEvent> events;
    late _CapturingLogger logger;
    late ProviderContainer container;

    setUp(() {
      backend = MockBackend();
      events = StreamController<SkotiqEvent>.broadcast();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      logger = _CapturingLogger();
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(logger),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await events.close();
    });

    SkotiqEvent cameraEvent(String type) => SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.equipment,
      eventType: type,
      data: const {},
    );

    test('a burst of one event type leaves one trace line', () {
      final executor = container.read(sequenceExecutorProvider);
      for (var i = 0; i < 200; i++) {
        executor.handleSequencerEventForTest(cameraEvent('CoolerStatus'));
      }

      expect(
        logger.lines.where((l) => l.contains('CoolerStatus')),
        hasLength(1),
      );
    });

    test('another event type is traced the moment it arrives', () {
      final executor = container.read(sequenceExecutorProvider);
      for (var i = 0; i < 50; i++) {
        executor.handleSequencerEventForTest(cameraEvent('CoolerStatus'));
      }
      executor.handleSequencerEventForTest(cameraEvent('FilterChanged'));

      expect(
        logger.lines.where((l) => l.contains('FilterChanged')),
        hasLength(1),
      );
    });
  });
}
