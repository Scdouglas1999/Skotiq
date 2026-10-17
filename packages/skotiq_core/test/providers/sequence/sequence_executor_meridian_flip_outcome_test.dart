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

/// The meridian-flip run record states what the flip actually did.
///
/// Without the verdict crossing the bridge, a flip trigger fires, the executor
/// logs an 8-step flip including a 15.0 s mount slew, its post-flip plate-solve
/// recentre FAILS, and the run still persists
/// `{"meridianFlips":0, "errorMessages":[], "warningMessages":[]}` with
/// `status = completed`.
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

  /// Builds a container with a live run-stats object in place, mirroring what
  /// `start()` does, so the counters the event handler mutates are observable.
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
    return (container, container.read(sequenceExecutorProvider));
  }

  backend_events.SkotiqEvent flipEvent({
    required String outcome,
    int attempts = 1,
    List<String> failedSteps = const [],
    String? error,
    String? actionTaken,
    double durationSecs = 41.2,
  }) {
    return backend_events.SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: outcome == 'success'
          ? backend_events.EventSeverity.info
          : backend_events.EventSeverity.critical,
      category: backend_events.EventCategory.sequencer,
      eventType: 'MeridianFlipOutcome',
      data: {
        'outcome': outcome,
        'target_name': 'MeridianTarget',
        'new_pier_side': 'West',
        'duration_secs': durationSecs,
        'attempts': attempts,
        'failed_steps': failedSteps,
        'error': error,
        'action_taken': actionTaken,
      },
    );
  }

  test('a clean flip increments meridianFlips and records nothing else', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(flipEvent(outcome: 'success'));

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(
      stats.meridianFlips,
      1,
      reason:
          'the counter stayed at 0 for a flip that physically swapped pier '
          'sides — this is the defect being regressed',
    );
    expect(stats.errorMessages, isEmpty);
    expect(stats.warningMessages, isEmpty);
  });

  test('a flip that needed retries counts AND warns', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      flipEvent(
        outcome: 'success',
        attempts: 2,
        failedSteps: const ['Plate solving and centering: Plate solve failed'],
      ),
    );

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(
      stats.meridianFlips,
      1,
      reason: 'the flip did complete, so it must still be counted',
    );
    expect(
      stats.errorMessages,
      isEmpty,
      reason: 'a recovered flip is degraded, not a run error',
    );
    expect(stats.warningMessages, hasLength(1));
    expect(
      stats.warningMessages.single,
      allOf(
        contains('succeeded only on attempt 2'),
        contains('Plate solve failed'),
        contains('Verify framing'),
      ),
    );
  });

  test('a failed flip records an error and does NOT count as a flip', () {
    final (container, executor) = build();
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    executor.handleSequencerEventForTest(
      flipEvent(
        outcome: 'failed',
        attempts: 4,
        failedSteps: const [
          'Plate solving and centering: Plate solve failed',
          'Plate solving and centering: Plate solve failed',
          'Plate solving and centering: Plate solve failed',
          'Plate solving and centering: Plate solve failed',
        ],
        error: 'Plate solving and centering: Plate solve failed',
        actionTaken: 'PauseAndAlert',
      ),
    );

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(
      stats.meridianFlips,
      0,
      reason: 'no flip completed, so nothing may be counted',
    );
    expect(
      stats.errorMessages,
      hasLength(1),
      reason:
          'the run persisted errorMessages: [] after a total flip failure — '
          'silent data loss reported as success',
    );
    expect(
      stats.errorMessages.single,
      allOf(
        contains('FAILED after 4 attempts'),
        contains('Plate solve failed'),
        contains('PauseAndAlert'),
      ),
    );
    expect(
      container.read(sequenceExecutionStateProvider),
      SequenceExecutionState.recovering,
      reason:
          'a run whose flip failed must not keep claiming a healthy running '
          'state',
    );
  });

  test('an aborted flip warns and does not count', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      flipEvent(outcome: 'aborted', attempts: 1, error: 'User requested abort'),
    );

    final stats = container.read(liveSequenceStatsProvider)!;
    expect(stats.meridianFlips, 0);
    expect(stats.errorMessages, isEmpty);
    expect(stats.warningMessages.single, contains('was aborted'));
  });

  test('the flip verdict survives the stats JSON round-trip', () {
    final (container, executor) = build();

    executor.handleSequencerEventForTest(
      flipEvent(
        outcome: 'success',
        attempts: 3,
        failedSteps: const ['Plate solving and centering: Plate solve failed'],
      ),
    );

    // The persisted `sequence_runs.stats_json` blob is what the session report
    // and history read, so the counter and the degradation warning have to
    // survive serialisation, not just live in memory.
    final restored = SequenceRunStats.fromJson(
      container.read(liveSequenceStatsProvider)!.toJson(),
    );
    expect(restored.meridianFlips, 1);
    expect(restored.warningMessages.single, contains('succeeded only on'));
  });

  test('a terminal SequenceFailed actually finalizes the run', () async {
    // A terminal `SequenceFailed` reaches the terminal handler, not
    // `SequencerEvent::Error`, which Dart treats as a NON-terminal mid-run
    // error. Flattened, `sequence_runs.status` stays `'running'` with a null
    // `ended_at` forever and the still-active imaging session refuses the next
    // start with `active_session_exists`.
    final (container, executor) = build();
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    executor.handleSequencerEventForTest(
      backend_events.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: backend_events.EventSeverity.error,
        category: backend_events.EventCategory.sequencer,
        eventType: 'SequenceFailed',
        data: const {'error': 'Sequence failed'},
      ),
    );

    // `_onTerminalEvent` claims the run synchronously (before its first await)
    // by entering `finalizing`, so observing anything other than `running`
    // proves the terminal path ran rather than the mid-run error path.
    expect(
      container.read(sequenceExecutionStateProvider),
      isNot(SequenceExecutionState.running),
      reason:
          'SequenceFailed must drive terminal finalization, not be swallowed '
          'as a recoverable mid-run error',
    );
    await executor.terminalCleanupSettledForTest;
    expect(
      container.read(liveSequenceStatsProvider)!.errorMessages,
      contains('Sequence failed'),
    );
  });

  test('run vitals carry errorMessages over the remote wire', () {
    // The `/api/sequencer/status` mirror used to expose warnings only, so a
    // remote operator could not see that the flip had failed.
    final vitals = SequencerRunVitals(
      startTime: DateTime.utc(2026, 7, 25, 20, 46, 50),
      framesCaptured: 8,
      framesRejected: 0,
      integrationSecs: 24,
      triggerFires: 1,
      autofocusRuns: 0,
      meridianFlips: 0,
      ditherCount: 0,
      warningMessages: const ['degraded'],
      errorMessages: const ['Meridian flip for "MeridianTarget" FAILED'],
    );
    final round = SequencerRunVitals.fromJson(vitals.toJson());
    expect(round.errorMessages, ['Meridian flip for "MeridianTarget" FAILED']);
    expect(round.warningMessages, ['degraded']);

    final stats = SequenceRunStats.fromRemoteVitals(round);
    expect(stats.errorMessages, hasLength(1));
    expect(stats.warningMessages, hasLength(1));
  });
}
