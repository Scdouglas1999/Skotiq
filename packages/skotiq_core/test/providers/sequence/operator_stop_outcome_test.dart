// The SAME Stop button records the same outcome whichever instruction is
// running.
//
// Stop pressed while a Slew is in flight cancels the slew, which comes back as
// a node FAILURE carrying "Slew: Operation cancelled", so the native run ends
// with `SequenceFailed` rather than `Stopped` — while a stop during an exposure
// ends with `Stopped`. Left there, one deliberate action gets two different
// verdicts: `Failed` plus a Critical toast for the autopilot's run,
// `Stopped (resumable)` for a hand-started one.
//
// The discriminator is deliberately NOT the message text — substring-matching
// "cancelled" swallows real faults whose text contains the word. It is the
// executor's own state: an explicit stop is IN FLIGHT, so whatever terminal the
// native reports is the outcome of that stop.
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

/// What a cancelled Slew really puts on the wire (bridge delivers
/// `InstructionFailed` as a mid-run `Error` carrying `"<node>: <message>"`, then
/// the terminal restates it).
const _slewCancelled = 'Slew: Operation cancelled';

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
    when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    if (!eventController.isClosed) await eventController.close();
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

  backend_events.SkotiqEvent event(String type, Map<String, Object?> data) =>
      backend_events.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: backend_events.EventSeverity.error,
        category: backend_events.EventCategory.sequencer,
        eventType: type,
        data: data,
      );

  test(
    'a stop during a Slew is recorded as a stop, not a failed run',
    () async {
      final (container, executor) = build();
      // The native cancels the in-flight slew and reports the run as FAILED,
      // carrying the instruction-level cancellation as the reason.
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenAnswer((_) async {
        scheduleMicrotask(() {
          executor.handleSequencerEventForTest(
            event('Error', {'message': _slewCancelled}),
          );
          executor.handleSequencerEventForTest(
            event('SequenceFailed', {'error': _slewCancelled}),
          );
        });
      });

      await executor.stop(preserveCheckpoint: true);
      await executor.terminalCleanupSettledForTest;

      final result = container.read(sequenceTerminalRunResultProvider);
      expect(result, isNotNull);
      expect(
        result!.runStatus,
        'paused-stopped',
        reason:
            'the operator pressed Stop; the instruction that happened to be in '
            'flight must not change the verdict on their action',
      );
      expect(result.outcome, SequenceExecutionState.idle);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );
    },
  );

  test('a LATE failure terminal cannot re-verdict a finished stop', () async {
    final (container, executor) = build();
    // The stop is confirmed by the native `Stopped` state change...
    when(() => backend.sequencerStop(origin: any(named: 'origin'))).thenAnswer((
      _,
    ) async {
      scheduleMicrotask(() {
        executor.handleSequencerEventForTest(
          event('SequenceStopped', const {}),
        );
      });
    });

    await executor.stop(preserveCheckpoint: true);
    await executor.terminalCleanupSettledForTest;
    expect(
      container.read(sequenceTerminalRunResultProvider)!.runStatus,
      'paused-stopped',
    );

    // ...and the node tree's own failure lands afterwards, once the stop's
    // finalization has already been dropped.
    executor.handleSequencerEventForTest(
      event('SequenceFailed', {'error': _slewCancelled}),
    );
    await executor.terminalCleanupSettledForTest;
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(sequenceTerminalRunResultProvider)!.runStatus,
      'paused-stopped',
      reason:
          'the run is over and its verdict was the operator\'s stop — a late '
          'terminal for that same run must not re-open finalization and '
          'republish it as Failed (which is what raises the Critical toast and '
          'files the run as Failed in Execution History)',
    );
    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.idle,
      reason: 'the dashboard must not flip to Failed after a clean stop',
    );
  });

  test('a genuine failure with no stop in flight is still a failure', () async {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      event('SequenceFailed', {'error': 'Camera disconnected'}),
    );
    await executor.terminalCleanupSettledForTest;

    final result = container.read(sequenceTerminalRunResultProvider);
    expect(result!.runStatus, 'failed');
    expect(result.outcome, SequenceExecutionState.failed);
    expect(
      container.read(liveSequenceStatsProvider)!.errorMessages,
      contains('Camera disconnected'),
    );
  });

  test('the stop origin reaches the native backend verbatim', () async {
    // The origin mechanism is pinned below the renderer: the scheduler's stop
    // arrives at the backend as origin='scheduler', a bare operator stop as
    // null.
    final (container, executor) = build();
    final origins = <String?>[];
    when(() => backend.sequencerStop(origin: any(named: 'origin'))).thenAnswer((
      invocation,
    ) async {
      origins.add(invocation.namedArguments[#origin] as String?);
      scheduleMicrotask(() {
        executor.handleSequencerEventForTest(event('SequenceStopped', {}));
      });
    });

    await executor.stop(origin: 'scheduler');
    await executor.terminalCleanupSettledForTest;

    expect(origins, ['scheduler']);
    // Silence the analyzer about the unused container.
    expect(container, isNotNull);
  });

  test(
    "a human's retry of a failed autopilot stop claims the episode",
    () async {
      // The retry re-drives the retained finalization, and the origin upgrades
      // toward the operator: their press is real and must be recorded. The
      // reverse never downgrades.
      final (container, executor) = build();
      final origins = <String?>[];
      var failFirst = true;
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenAnswer((invocation) async {
        origins.add(invocation.namedArguments[#origin] as String?);
        if (failFirst) {
          failFirst = false;
          throw StateError('native stop lost');
        }
        scheduleMicrotask(() {
          executor.handleSequencerEventForTest(event('SequenceStopped', {}));
        });
      });

      // Autopilot stops; the native stop throws; the drive settles stopFailed.
      await expectLater(executor.stop(origin: 'scheduler'), throwsStateError);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.stopFailed,
      );

      // The human presses Stop: the retry must carry THEIR origin.
      await executor.stop();
      await executor.terminalCleanupSettledForTest;
      expect(origins, ['scheduler', null]);
    },
  );

  test(
    'the executor remembers WHO ended the run (autopilot narrowing)',
    () async {
      // The scheduler's reconcile must not pause the autopilot for a safety
      // abort: only a human's stop expresses intent. The memo is the
      // classifier's evidence — an explicit stop records its commander, a
      // natural stopped terminal that nobody commanded records 'safety'.
      final (container, executor) = build();
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenAnswer((_) async {
        scheduleMicrotask(() {
          executor.handleSequencerEventForTest(event('SequenceStopped', {}));
        });
      });

      await executor.stop();
      await executor.terminalCleanupSettledForTest;
      expect(executor.lastRunEndOrigin, 'operator');
      expect(container, isNotNull);
    },
  );

  test('a native-side abort with no stop() commander records safety', () async {
    // A ParkAndAbort (weather/dome) terminates the run natively: Dart never
    // calls stop(), the terminal arrives on its own, and the memo must say
    // 'safety' so the autopilot keeps the night alive.
    final (container, executor) = build();

    executor.handleSequencerEventForTest(event('SequenceStopped', {}));
    await executor.terminalCleanupSettledForTest;
    expect(executor.lastRunEndOrigin, 'safety');
    expect(container, isNotNull);
  });
}
