import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as backend_events;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// The native executor publishes one node's failure reason TWICE by
/// construction: the instruction emits `InstructionFailed`, the bridge delivers
/// it as a mid-run `Error` event carrying `"<node>: <message>"`, and the
/// terminal handler then drains the broadcast buffer for that same
/// `InstructionFailed` and re-formats it byte-for-byte as
/// `SequenceFailed.error` (`executor/mod.rs: last_instruction_failure`). Dart
/// must record it once, or the report's error count cannot match the number of
/// failed nodes.
const _reason = 'Open Cover: No cover calibrator (flat panel) connected';

void main() {
  late MockBackend backend;
  late StreamController<backend_events.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<backend_events.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  (ProviderContainer, SequenceExecutor) build() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveSequenceStatsProvider.notifier).state =
        SequenceRunStats();
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;
    return (container, container.read(sequenceExecutorProvider));
  }

  backend_events.SkotiqEvent midRunError(String message) =>
      backend_events.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: backend_events.EventSeverity.error,
        category: backend_events.EventCategory.sequencer,
        eventType: 'Error',
        data: {'message': message},
      );

  backend_events.SkotiqEvent terminalFailure(String error) =>
      backend_events.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: backend_events.EventSeverity.error,
        category: backend_events.EventCategory.sequencer,
        eventType: 'SequenceFailed',
        data: {'error': error},
      );

  test('one failed node produces one error entry, not two', () async {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(midRunError(_reason));
    executor.handleSequencerEventForTest(terminalFailure(_reason));
    await executor.terminalCleanupSettledForTest;

    expect(
      container.read(liveSequenceStatsProvider)!.errorMessages,
      [_reason],
      reason:
          'the terminal event restates the mid-run reason; the Session Report '
          'must not list the same failed node twice',
    );
  });

  test('a terminal reason the run never announced is still recorded', () async {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(midRunError(_reason));
    executor.handleSequencerEventForTest(
      terminalFailure('Sequence aborted by weather safety'),
    );
    await executor.terminalCleanupSettledForTest;

    expect(container.read(liveSequenceStatsProvider)!.errorMessages, [
      _reason,
      'Sequence aborted by weather safety',
    ]);
  });

  test('two genuinely different mid-run failures are both recorded', () async {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(midRunError(_reason));
    executor.handleSequencerEventForTest(
      midRunError('Start Guiding: No active guider configured'),
    );

    expect(container.read(liveSequenceStatsProvider)!.errorMessages, [
      _reason,
      'Start Guiding: No active guider configured',
    ]);
  });
}
