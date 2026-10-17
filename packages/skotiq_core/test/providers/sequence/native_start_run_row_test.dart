// The headless `POST /api/sequencer/load` -> `POST /api/sequencer/start` path
// must leave a `sequence_runs` row behind, like every other launch path.
//
// Measured against the release bundle (2026-08-17): a complete sim night —
// state completed, 12 frames, 4 masters — left `sequence_runs` EMPTY, so
// `GET /api/sequence-runs` answered `{"items":[],"total":0}` for a night that
// had just happened. Only `imaging_sessions` got a row.
//
// The bare path does not call `SequenceExecutor.start()`, so it opened neither
// the run row nor the live stats that finalization writes its outcome onto.
// These pin the replacement entry point: the row exists while the run is live,
// a natural terminal finishes it with the right status, a REPEAT run in the
// same process gets its own finished row (the finalization latch is released
// per run), and a start the native executor refuses does not leave a run
// sitting in the history as `running`.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

bridge_event.SkotiqEvent _sequencerEvent(String eventType) {
  return bridge_event.SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.info,
    category: bridge_event.EventCategory.sequencer,
    eventType: eventType,
    data: const {},
  );
}

void main() {
  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  ProviderContainer? container;

  ProviderContainer buildContainer() {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    backend = MockBackend();
    eventController =
        StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.sequencerSetActiveSequenceRunId(any()),
    ).thenAnswer((_) async {});
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    // Let the run lifecycle's fire-and-forget database work settle against the
    // still-open DB before the container (and then the DB) goes away.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    container?.dispose();
    if (!eventController.isClosed) {
      await eventController.close();
    }
    await db.close();
  });

  Future<void> pumpEvents() => Future<void>.delayed(Duration.zero);

  /// What the headless start handler does for a natively-loaded sequence:
  /// open the run records, then subscribe to the native event stream.
  Future<int> startNativeRun(
    ProviderContainer container,
    SequenceExecutor executor, {
    String name = 'D1 sim night',
  }) async {
    final runId = await executor.openRunRecordsForNativeStart(
      sequenceName: name,
    );
    await executor.attachHostListenersForNativeRun();
    return runId;
  }

  test('a native start opens a run row that the run history can see', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);

    final runId = await startNativeRun(container, executor);

    final run = await container.read(sequenceRunsDaoProvider).getRunById(runId);
    expect(run, isNotNull);
    expect(run!.sequenceName, 'D1 sim night');
    expect(run.status, 'running');
    expect(run.endedAt, isNull);
    expect(container.read(currentRunIdProvider), runId);
    // The wire JSON is not the editor's snapshot shape, so no snapshot is
    // claimed for this path.
    expect(run.sequenceSnapshotJson, isNull);
  });

  test('the run row is finished when the native run completes', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);
    final runId = await startNativeRun(container, executor);

    eventController.add(_sequencerEvent('Completed'));
    await pumpEvents();
    await executor.terminalCleanupSettledForTest;

    final run = await container.read(sequenceRunsDaoProvider).getRunById(runId);
    expect(run!.status, 'completed');
    expect(run.endedAt, isNotNull);
    expect(container.read(currentRunIdProvider), isNull);
  });

  test(
    'a second native run in the same process gets its own finished row',
    () async {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      final first = await startNativeRun(
        container,
        executor,
        name: 'night one',
      );
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      final second = await startNativeRun(
        container,
        executor,
        name: 'night two',
      );
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      expect(second, isNot(first));
      final dao = container.read(sequenceRunsDaoProvider);
      // Both nights are on record, and neither is left claiming to be running —
      // the second run's finish is what the once-per-run finalization latch used
      // to swallow.
      expect((await dao.getRunById(first))!.status, 'completed');
      expect((await dao.getRunById(second))!.status, 'completed');
    },
  );

  test('a refused start leaves no run claiming to be running', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);
    final runId = await startNativeRun(container, executor);

    await executor.discardRunRecordsForRefusedNativeStart(runId);

    final run = await container.read(sequenceRunsDaoProvider).getRunById(runId);
    expect(run!.status, 'failed');
    expect(run.endedAt, isNotNull);
    expect(container.read(currentRunIdProvider), isNull);
  });

  test('a native start never opens a second row over a live run', () async {
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);
    final runId = await startNativeRun(container, executor);

    final again = await executor.openRunRecordsForNativeStart(
      sequenceName: 'a second load while the first is live',
    );

    expect(again, runId);
    expect(
      (await container.read(sequenceRunsDaoProvider).getAllRuns()).length,
      1,
    );
  });

  test('a second native run reports only its own integration time', () async {
    // Measured on the run-watch page against the release bundle: four runs in
    // one process read "FRAMES 4 / 4" beside "INTEGRATION 2m 36s" for a run of
    // 4 x 4.0 s. The frame count re-zeroed itself because every producer writes
    // it as the event's ABSOLUTE index; the integration seconds accumulate, and
    // nothing on this path cleared them between runs.
    final container = buildContainer();
    final executor = container.read(sequenceExecutorProvider);
    var clock = DateTime.now().millisecondsSinceEpoch;

    Future<void> runThreeFrames(String name) async {
      await startNativeRun(container, executor, name: name);
      for (var frame = 1; frame <= 3; frame++) {
        clock += 1000;
        applySequencerEventToSequenceProviders(
          container.read,
          bridge_event.SkotiqEvent(
            timestamp: clock,
            severity: bridge_event.EventSeverity.info,
            category: bridge_event.EventCategory.sequencer,
            eventType: 'ExposureCompleted',
            data: {'frame': frame, 'total': 3, 'duration_secs': 4.0},
          ),
        );
      }
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
    }

    await runThreeFrames('night one');
    expect(
      container.read(sequenceProgressProvider).completedIntegrationSecs,
      12.0,
    );

    await runThreeFrames('night two');
    final progress = container.read(sequenceProgressProvider);
    expect(progress.completedExposures, 3);
    expect(
      progress.completedIntegrationSecs,
      12.0,
      reason:
          'the second run of 3 x 4.0 s reported '
          '${progress.completedIntegrationSecs}s of integration',
    );
  });
}
