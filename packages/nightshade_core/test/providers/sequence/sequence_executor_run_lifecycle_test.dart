// The SequenceExecutor run-lifecycle transaction.
//
// These pin the contract that SequenceExecutor owns its run lifecycle
// transactionally:
//
//   * start() serialization — two concurrent starts create exactly one
//     session / run / native start (second is rejected).
//   * transactional start — a pre-native setup failure AND a
//     backend.sequencerStart() failure both roll back to a truthful,
//     non-running state with no active session, stale run id, or stranded
//     native subscription.
//   * natural terminal events (Completed / SequenceFailed / Stopped) end the
//     durable session with the correct status EXACTLY ONCE; duplicate /
//     aliased terminal events do not finalize/end twice.
//   * explicit stop() exposes `stopping` while the native stop is pending,
//     commands backend.sequencerStop() even when session/report cleanup
//     fails, and coalesces duplicate stop() calls.
//   * Smart Night / mosaic editor ownership is restored on completion,
//     failure, stop, and start failure; autopilot ownership is NOT generically
//     released (SchedulerEngine owns that lifecycle).
//
// The tests await deterministic quiescence hooks
// (`terminalCleanupSettledForTest`, the stop future, a zero-duration event
// pump) — never a wall-clock sleep.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_core/src/backend/nightshade_backend.dart'
    as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, NightshadeBackend backend) {
    state = backend;
  }
}

class _TestAppSettingsNotifier extends AppSettingsNotifier {
  final Future<AppSettingsState> Function() _load;

  _TestAppSettingsNotifier(this._load);

  @override
  Future<AppSettingsState> build() => _load();
}

/// Session-state notifier seam that records every start/end call and can be
/// told to throw from [endSession] — so we can prove stop() still commands the
/// native executor even when durable-session cleanup fails, and prove terminal
/// events end the session exactly once. Subclasses the real notifier and only
/// overrides the two DB-backed methods so the rest of the executor's session
/// interactions (setTotalExposures, etc.) keep working.
class _RecordingSessionNotifier extends SessionStateNotifier {
  _RecordingSessionNotifier(super.ref);

  int startCount = 0;
  final List<String> endedStatuses = [];
  bool throwOnEnd = false;

  /// The `dbSessionId` the most recent [startSession] handed out — the id a
  /// terminal result must carry for the night that just ended.
  int get lastSessionId => 1000 + startCount;

  /// When set, [endSession] awaits this before recording — so a test can hold
  /// the finalization drive parked in the busy `finalizing` state (durable
  /// cleanup in flight) and assert on admission/report while it is suspended.
  Completer<void>? endGate;

  @override
  Future<void> startSession({
    String? targetName,
    double? targetRa,
    double? targetDec,
    int? targetId,
    int? profileId,
    int? sequenceId,
  }) async {
    startCount++;
    state = SessionState(
      isActive: true,
      dbSessionId: 1000 + startCount,
      startTime: DateTime.now(),
      targetName: targetName,
    );
  }

  @override
  Future<void> endSession({String status = 'completed'}) async {
    final gate = endGate;
    if (gate != null) {
      await gate.future;
    }
    // Preserve the real notifier's idempotency: a no-op when nothing is
    // active. Only a genuine finalization is recorded, so `endedStatuses`
    // proves exactly-once.
    if (!state.isActive || state.dbSessionId == null) return;
    endedStatuses.add(status);
    if (throwOnEnd) {
      throw StateError('endSession failed (injected)');
    }
    state = const SessionState();
  }
}

/// A [SequenceRunsDao] test double so a test can force a `finishRun` failure (to
/// prove the finishRun-vs-endSession ordering guarantee) or gate/inspect
/// `updateStats` (to prove the incremental-stats drain). Only the methods the
/// device-less run lifecycle actually calls are stubbed.
class _MockRunsDao extends Mock implements SequenceRunsDao {}

/// Validator seam: no rules => `validate()` returns zero issues => start()
/// passes its pre-flight gate deterministically without dragging in the real
/// equipment/disk/dark-library checks.
SequenceValidatorService _passingValidator(Ref ref) => SequenceValidatorService(
  ref: ref,
  syncRules: const [],
  refAwareRules: const [],
  asyncRules: const [],
);

Sequence _buildSequence({String name = 'test sequence'}) {
  final root = InstructionSetNode(id: 'root-$name', name: 'Sequence');
  return Sequence.create(
    name: name,
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
}

bridge_event.NightshadeEvent _sequencerEvent(
  String eventType, {
  Map<String, Object?> data = const {},
}) {
  return bridge_event.NightshadeEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.info,
    category: bridge_event.EventCategory.sequencer,
    eventType: eventType,
    data: data,
  );
}

/// Stub `sequencerStop()` the way the REAL backend answers it.
///
/// `sequencerStop()` is a COMMAND, not the release boundary. The native
/// executor acknowledges the command and then drives itself to a terminal
/// state, which arrives back on the event stream; `_driveFinalization` waits on
/// that authoritative terminal (`_RunFinalization.nativeStopConfirmation`)
/// before tearing anything down, precisely so cleanup can never run while the
/// hardware might still be exposing.
///
/// A mock that merely returns therefore models a backend that ACCEPTS the stop
/// and then goes silent forever — and every `await executor.stop()` blocks. The
/// tests that genuinely want that unconfirmed case (the `stopFailed` ladder)
/// stub `sequencerStop` themselves with an explicit gate; every other test must
/// use this so the mock matches the real contract.
void _stubConfirmingStop(
  MockBackend backend,
  StreamController<bridge_event.NightshadeEvent> eventController,
) {
  when(() => backend.sequencerStop(origin: any(named: 'origin'))).thenAnswer((
    _,
  ) async {
    scheduleMicrotask(() {
      if (!eventController.isClosed) {
        eventController.add(_sequencerEvent('Stopped'));
      }
    });
  });
}

/// Stub every backend call a full, device-less start makes so start() runs end
/// to end. `sequencerStart` / `sequencerStop` are stubbed by the caller when a
/// specific gating/failure is required.
void _stubBackendForStart(MockBackend backend) {
  when(
    () => backend.sequencerSetActiveSequenceRunId(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerSetSimulationMode(any()),
  ).thenAnswer((_) async {});
  when(() => backend.sequencerSetSavePath(any())).thenAnswer((_) async {});
  when(
    () => backend.sequencerSetDevices(
      cameraId: any(named: 'cameraId'),
      mountId: any(named: 'mountId'),
      focuserId: any(named: 'focuserId'),
      filterwheelId: any(named: 'filterwheelId'),
      rotatorId: any(named: 'rotatorId'),
    ),
  ).thenAnswer((_) async {});
  when(() => backend.sequencerLoadJson(any())).thenAnswer((_) async {});
  when(
    () => backend.sequencerSetSafetyFailMode(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerSetParkPolicy(
      parkOnUnsafeWeather: any(named: 'parkOnUnsafeWeather'),
      parkBeforeDawn: any(named: 'parkBeforeDawn'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerSetDeviceRetries(
      cameraRetries: any(named: 'cameraRetries'),
      filterWheelRetries: any(named: 'filterWheelRetries'),
    ),
  ).thenAnswer((_) async {});
  when(() => backend.setLocation(any())).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateLocation(
      latitude: any(named: 'latitude'),
      longitude: any(named: 'longitude'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateDefaultQualityCheck(
      hfrThreshold: any(named: 'hfrThreshold'),
      hfrBaselinePercent: any(named: 'hfrBaselinePercent'),
      eccentricityThreshold: any(named: 'eccentricityThreshold'),
      starCountMin: any(named: 'starCountMin'),
      maxConsecutiveRejects: any(named: 'maxConsecutiveRejects'),
      enabled: any(named: 'enabled'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateRejectFolderPath(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerClearDefaultAdaptiveExposure(),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateDefaultAdaptiveExposure(
      enabled: any(named: 'enabled'),
      targetSnr: any(named: 'targetSnr'),
      referenceSkyBrightnessMag: any(named: 'referenceSkyBrightnessMag'),
      minExposureSecs: any(named: 'minExposureSecs'),
      maxExposureSecs: any(named: 'maxExposureSecs'),
      perFilterEnabled: any(named: 'perFilterEnabled'),
      perFilterMinSecs: any(named: 'perFilterMinSecs'),
      perFilterMaxSecs: any(named: 'perFilterMaxSecs'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateAutofocusInterval(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateAutofocusConfig(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateDitherConfig(
      pixels: any(named: 'pixels'),
      settlePixels: any(named: 'settlePixels'),
      settleTime: any(named: 'settleTime'),
      settleTimeout: any(named: 'settleTimeout'),
      raOnly: any(named: 'raOnly'),
    ),
  ).thenAnswer((_) async {});
  // The start path seeds the meridian-flip trigger from the operator's
  // settings; without it the Rust trigger keeps `MeridianFlipConfig::default()`
  // and the whole Settings -> Meridian Flip panel is inert on the flip that
  // actually fires unattended.
  when(
    () => backend.sequencerUpdateMeridianFlipConfig(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateFilterOffsets(any()),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerUpdateObserverProfile(
      observerName: any(named: 'observerName'),
      siteElevationM: any(named: 'siteElevationM'),
      cameraMake: any(named: 'cameraMake'),
      cameraModel: any(named: 'cameraModel'),
      telescopeName: any(named: 'telescopeName'),
      telescopeFocalLengthMm: any(named: 'telescopeFocalLengthMm'),
      telescopeApertureMm: any(named: 'telescopeApertureMm'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => backend.sequencerSetDecisionLoggingEnabled(any()),
  ).thenAnswer((_) async {});
}

void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
  });

  late MockBackend backend;
  late StreamController<bridge_event.NightshadeEvent> eventController;
  late NightshadeDatabase db;
  late _RecordingSessionNotifier session;
  ProviderContainer? container;

  ProviderContainer buildContainer({
    AppSettingsNotifier Function()? settingsNotifier,
  }) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        sessionStateProvider.overrideWith((ref) {
          session = _RecordingSessionNotifier(ref);
          return session;
        }),
        sequenceValidatorProvider.overrideWith(_passingValidator),
        if (settingsNotifier != null)
          appSettingsProvider.overrideWith(settingsNotifier),
      ],
    );
    container = c;
    // Materialize the recording session notifier eagerly so `session` is bound
    // even for tests where start() is rejected before it reads the provider.
    c.read(sessionStateProvider.notifier);
    return c;
  }

  /// Like [buildContainer] but with an injected [SequenceRunsDao] test double,
  /// so a test can force a `finishRun` failure or gate/inspect the incremental
  /// `updateStats` writes.
  ProviderContainer buildContainerWithDao(SequenceRunsDao dao) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        sessionStateProvider.overrideWith((ref) {
          session = _RecordingSessionNotifier(ref);
          return session;
        }),
        sequenceValidatorProvider.overrideWith(_passingValidator),
        sequenceRunsDaoProvider.overrideWithValue(dao),
      ],
    );
    container = c;
    c.read(sessionStateProvider.notifier);
    return c;
  }

  setUp(() {
    container = null;
    backend = MockBackend();
    eventController =
        StreamController<bridge_event.NightshadeEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = NightshadeDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    // Let fire-and-forget DB work queued by the run lifecycle (run-row
    // finalize, live-stats persist, sequencer-defaults load, per-session
    // diagnostics upsert) settle against the still-open DB, then dispose the
    // container (cancelling every provider subscription/timer) BEFORE closing
    // the DB. Without this ordering a straggling in-memory SQLite read/write
    // races db.close() and throws "Can't re-open a database" after the test.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    container?.dispose();
    if (!eventController.isClosed) {
      await eventController.close();
    }
    await db.close();
  });

  // Pump the broadcast event queue so a just-added event reaches the
  // executor's listener. A zero-duration yield, not a wall-clock sleep.
  Future<void> pumpEvents() => Future<void>.delayed(Duration.zero);

  group('A. start serialization', () {
    test('two concurrent starts create/start exactly once', () async {
      final container = buildContainer();
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());

      final executor = container.read(sequenceExecutorProvider);

      // Fire two starts back to back. The first holds the in-flight latch
      // before yielding at its first await, so the second is rejected.
      final first = executor.start();
      final second = executor.start();

      await expectLater(second, throwsA(isA<StateError>()));
      await first;

      expect(
        session.startCount,
        1,
        reason: 'exactly one session row for two concurrent starts',
      );
      verify(() => backend.sequencerStart()).called(1);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );

      // Tear down the successful run so no timers/watchers leak.
      await executor.stop();
    });

    test('start is rejected while already running', () async {
      final container = buildContainer();
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      await expectLater(executor.start(), throwsA(isA<StateError>()));
      // The second rejection must not have created a second run/session.
      expect(session.startCount, 1);
      verify(() => backend.sequencerStart()).called(1);

      await executor.stop();
    });
  });

  group('B. transactional start rollback', () {
    Future<void> expectCleanRollback(
      ProviderContainer container,
      _RecordingSessionNotifier session,
    ) async {
      // No stale run id.
      expect(
        container.read(currentRunIdProvider),
        isNull,
        reason: 'currentRunId must be cleared on rollback',
      );
      // Truthful, non-running state.
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.failed,
      );
      // The created session was ended failed (not left active).
      expect(session.endedStatuses, ['failed']);
      // No stranded native event subscription: an event pushed after rollback
      // must NOT be processed by the executor (its subscription is cancelled),
      // so the failed state is not flipped back to running. `hasListener` is
      // avoided because other legitimate providers (notification router) also
      // subscribe to the backend event stream.
      eventController.add(_sequencerEvent('Started'));
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.failed,
        reason: 'a cancelled native subscription must not process events',
      );
    }

    test('pre-native setup failure (loadJson) rolls back cleanly', () async {
      final container = buildContainer();
      _stubBackendForStart(backend);
      // loadJson runs before the native subscription is established.
      when(
        () => backend.sequencerLoadJson(any()),
      ).thenThrow(StateError('loadJson boom'));
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);

      await expectLater(executor.start(), throwsA(isA<StateError>()));

      expect(session.startCount, 1, reason: 'session row was created');
      await expectCleanRollback(container, session);
      verifyNever(() => backend.sequencerStart());
    });

    test('backend.sequencerStart failure rolls back cleanly when the partial '
        'launch is confirmed stopped', () async {
      final container = buildContainer();
      _stubBackendForStart(backend);
      when(
        () => backend.sequencerStart(),
      ).thenThrow(StateError('native start boom'));
      // A native start throw may mean a partial launch — the rollback issues
      // a best-effort stop, which succeeds here, so the rollback is clean.
      _stubConfirmingStop(backend, eventController);
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);

      await expectLater(executor.start(), throwsA(isA<StateError>()));

      expect(session.startCount, 1);
      // The rollback commanded the (possibly partial) native launch to stop.
      // The rollback's stop must carry its own origin — nobody pressed it.
      verify(() => backend.sequencerStop(origin: 'rollback')).called(1);
      await expectCleanRollback(container, session);
    });

    test(
      'backend.sequencerStart failure whose rollback stop cannot confirm '
      'retains a controllable stopFailed instead of a blind teardown',
      () async {
        final container = buildContainer();
        _stubBackendForStart(backend);
        when(
          () => backend.sequencerStart(),
        ).thenThrow(StateError('native start boom'));
        // The partial launch may still be imaging AND the best-effort rollback
        // stop fails — so we must NOT tear down / clear / release blind.
        when(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).thenThrow(StateError('rollback stop boom'));
        container
            .read(currentSequenceProvider.notifier)
            .loadSequence(_buildSequence());
        final executor = container.read(sequenceExecutorProvider);

        await expectLater(executor.start(), throwsA(isA<StateError>()));

        // The rollback's stop must carry its own origin — nobody pressed it.
        verify(() => backend.sequencerStop(origin: 'rollback')).called(1);
        // Retained controllability: run id kept, session NOT ended, stopFailed.
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.stopFailed,
        );
        expect(container.read(currentRunIdProvider), isNotNull);
        expect(session.endedStatuses, isEmpty);
      },
    );

    test('validation rejection creates no run/session', () async {
      final container = buildContainer();
      // No sequence loaded => validation rejection before any acquisition.
      final executor = container.read(sequenceExecutorProvider);

      await expectLater(
        executor.start(),
        throwsA(isA<SequenceValidationException>()),
      );
      expect(session.startCount, 0, reason: 'no fake session on rejection');
      expect(session.endedStatuses, isEmpty);
      expect(container.read(currentRunIdProvider), isNull);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
        reason: 'validation rejection must not flash running/failed',
      );
    });

    test(
      'settings failure rejects start before any run or backend mutation',
      () async {
        final container = buildContainer(
          settingsNotifier: () => _TestAppSettingsNotifier(
            () async => throw StateError('settings database unavailable'),
          ),
        );
        _stubBackendForStart(backend);
        container
            .read(currentSequenceProvider.notifier)
            .loadSequence(_buildSequence());
        final executor = container.read(sequenceExecutorProvider);

        await expectLater(
          executor.start(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('settings database unavailable'),
            ),
          ),
        );

        expect(session.startCount, 0);
        expect(container.read(currentRunIdProvider), isNull);
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
        verifyNever(() => backend.sequencerSetSimulationMode(any()));
        verifyNever(() => backend.sequencerSetSavePath(any()));
        verifyNever(() => backend.sequencerStart());
      },
    );

    test(
      'start pushes simulation mode off, with no setting to read it from',
      () async {
        final container = buildContainer();
        _stubBackendForStart(backend);
        when(() => backend.sequencerStart()).thenAnswer((_) async {});
        _stubConfirmingStop(backend, eventController);
        when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
        container
            .read(currentSequenceProvider.notifier)
            .loadSequence(_buildSequence());
        final executor = container.read(sequenceExecutorProvider);

        await executor.start();

        verify(() => backend.sequencerSetSimulationMode(false)).called(1);
        await executor.stop();
      },
    );
  });

  group('C. natural terminal events', () {
    Future<SequenceExecutor> startRunning(ProviderContainer container) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    test('Completed ends the session completed exactly once', () async {
      final container = buildContainer();
      final executor = await startRunning(container);

      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      expect(session.endedStatuses, ['completed']);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.completed,
      );
      expect(container.read(currentRunIdProvider), isNull);

      // Duplicate + aliased terminal events must not end the session again.
      eventController.add(_sequencerEvent('Completed'));
      eventController.add(_sequencerEvent('SequenceCompleted'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
      expect(session.endedStatuses, ['completed']);
    });

    test('SequenceFailed ends the session failed exactly once', () async {
      final container = buildContainer();
      final executor = await startRunning(container);

      eventController.add(
        _sequencerEvent('SequenceFailed', data: {'error': 'guiding lost'}),
      );
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      expect(session.endedStatuses, ['failed']);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.failed,
      );

      eventController.add(
        _sequencerEvent('SequenceFailed', data: {'error': 'again'}),
      );
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
      expect(session.endedStatuses, ['failed']);
    });

    test('Stopped ends the session stopped exactly once', () async {
      final container = buildContainer();
      final executor = await startRunning(container);

      // The operator's stop decision row — the real wire carries it before
      // the terminal (`stop_with_origin`); a native-side Stopped with no
      // authorship evidence is classified 'aborted' instead (L52).
      eventController.add(
        _sequencerEvent(
          'DecisionLogged',
          data: const {
            'category': 'manual_intervention',
            'summary': 'Operator: stop requested',
          },
        ),
      );
      await pumpEvents();
      eventController.add(_sequencerEvent('Stopped'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      expect(session.endedStatuses, ['stopped']);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );

      eventController.add(_sequencerEvent('SequenceStopped'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
      expect(session.endedStatuses, ['stopped']);
    });

    test('a trigger ParkAndAbort ends the session aborted and records its '
        'cause in the run stats (L52)', () async {
      final container = buildContainer();
      final executor = await startRunning(container);

      eventController.add(
        _sequencerEvent(
          'TriggerFired',
          data: const {
            'trigger_id': 'dawn_approaching',
            'trigger_name': 'Dawn Approaching',
            'action': 'ParkAndAbort',
          },
        ),
      );
      await pumpEvents();
      eventController.add(_sequencerEvent('Stopped'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      // 'aborted' separates a safety/trigger end from the operator's own
      // press — the Execution History chip already exists for it.
      expect(session.endedStatuses, ['aborted']);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );

      // The run row carries WHY it ended, not just that it did.
      final runs = await db.select(db.sequenceRuns).get();
      expect(runs.single.status, 'aborted');
      final stats = jsonDecode(runs.single.statsJson) as Map<String, dynamic>;
      expect(
        (stats['warningMessages'] as List).join('\n'),
        contains('Dawn Approaching'),
      );
    });

    test('a depth goal that ends a plan early is recorded on the run', () async {
      final container = buildContainer();
      await startRunning(container);

      eventController.add(
        _sequencerEvent(
          'DepthGoalCompleted',
          data: const {
            'node_id': 'smart-1',
            'filter_name': 'Ha',
            'goal_id': 'm42-ha',
            'revision': 3,
            'evidence_frames': 18,
            'confirmation_frames': 3,
            'score': 13.4,
            'threshold': 12.0,
          },
        ),
      );
      await pumpEvents();
      // The write is fire-and-forget so the event loop keeps pumping; one more
      // turn of the microtask queue is all it needs, never a sleep.
      await pumpEvents();

      final runId = container.read(currentRunIdProvider)!;
      final decisions = await container
          .read(replayDebugServiceProvider)
          .listByRun(runId);
      final decision = decisions.single;
      // Filed as a budget decision: a depth goal IS the budget for a plan
      // bound to one, and the replay feed already reads that bucket as "the
      // plan stopped because it had enough".
      expect(decision.category, DecisionCategory.budgetMet);
      expect(decision.nodeId, 'smart-1');
      expect(decision.summary, contains('Ha reached its depth goal'));
      expect(decision.summary, contains('13.4'));
      // The whole justification survives, so the Session Report can explain
      // the short frame count without reopening the goal store.
      final details = decision.details;
      expect(details['goal_id'], 'm42-ha');
      expect(details['revision'], 3);
      expect(details['score'], 13.4);
      expect(details['threshold'], 12.0);
      expect(details['evidence_frames'], 18);
      expect(details['confirmation_frames'], 3);
    });
  });

  group('D. explicit stop safety', () {
    Future<SequenceExecutor> startRunning(ProviderContainer container) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    test('exposes stopping while native stop is pending', () async {
      final container = buildContainer();
      final gate = Completer<void>();
      final executor = await startRunning(container);
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenAnswer((_) => gate.future);

      final stopFuture = executor.stop();
      // The stopping transition happens synchronously before the first await
      // inside stop(), so it is already visible here.
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.stopping,
      );

      gate.complete();
      // The stop COMMAND completing is not the release boundary: the real
      // backend then drives the native executor to a terminal state, which
      // arrives on the event stream and is what `_driveFinalization` waits for.
      // A gated stub has to deliver that terminal too, or the stop never
      // settles.
      await pumpEvents();
      eventController.add(_sequencerEvent('Stopped'));
      await stopFuture;

      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );
      expect(session.endedStatuses, ['stopped']);
      verify(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).called(1);
    });

    test(
      'confirmed native stop + cleanup failure becomes retryable cleanupFailed '
      'that blocks start; a Stop retry finalizes to idle',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);
        _stubConfirmingStop(backend, eventController);
        session.throwOnEnd = true;

        // The native stop SUCCEEDS (hardware is safe) but endSession throws:
        // the durable session record is incomplete. This is NOT a clean idle —
        // it is a retryable cleanupFailed state that surfaces the error, retains
        // identity, and blocks a fresh start (which would collide with the
        // dangling session).
        await expectLater(executor.stop(), throwsA(isA<StateError>()));

        verify(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).called(1);
        expect(session.endedStatuses, [
          'stopped',
        ], reason: 'endSession was attempted');
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.cleanupFailed,
        );
        // Identity retained for the retry.
        expect(container.read(currentRunIdProvider), isNotNull);
        // Start is blocked while cleanup is pending.
        expect(
          container.read(sequenceExecutionStateProvider).canStart,
          isFalse,
        );
        await expectLater(
          executor.start(),
          throwsA(isA<StateError>()),
          reason: 'start is rejected from cleanupFailed',
        );

        // Retry the stop once the DB write can succeed — the run finalizes and
        // the executor settles idle. A cleanup failure is NOT a permanent latch.
        session.throwOnEnd = false;
        await executor.stop();
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
        expect(session.endedStatuses, ['stopped', 'stopped']);
        expect(container.read(currentRunIdProvider), isNull);
      },
    );

    test(
      'native stop failure exposes stopFailed, retains ids/session/ownership, '
      'and a Stop retry succeeds',
      () async {
        final container = buildContainer();
        final plan = _buildSequence(name: 'smart night plan');
        _stubBackendForStart(backend);
        when(() => backend.sequencerStart()).thenAnswer((_) async {});
        when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
        container
            .read(currentSequenceProvider.notifier)
            .takeOwnership(plan, ActivePlanOwner.smartNight);
        final executor = container.read(sequenceExecutorProvider);
        await executor.start();
        final runId = container.read(currentRunIdProvider);
        expect(runId, isNotNull);

        // Native stop FAILS — the hardware was not confirmed stopped and may
        // still be imaging.
        when(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).thenThrow(StateError('hardware wedged'));
        await expectLater(executor.stop(), throwsA(isA<StateError>()));

        // stopFailed — NOT a terminal failed/idle. Nothing is finalized,
        // cleared, or released; the checkpoint is preserved.
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.stopFailed,
        );
        expect(
          container.read(currentRunIdProvider),
          runId,
          reason: 'run id retained after a failed stop',
        );
        expect(
          session.endedStatuses,
          isEmpty,
          reason: 'session not ended while hardware may still be imaging',
        );
        expect(
          container.read(currentSequenceProvider.notifier).activeOwner,
          ActivePlanOwner.smartNight,
          reason: 'ownership retained while the run may still be active',
        );
        verifyNever(() => backend.discardCheckpoint());

        // Retry once the hardware acknowledges the stop — full teardown to idle.
        _stubConfirmingStop(backend, eventController);
        await executor.stop();
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
        expect(session.endedStatuses, ['stopped']);
        expect(container.read(currentRunIdProvider), isNull);
        expect(
          container.read(currentSequenceProvider.notifier).activeOwner,
          ActivePlanOwner.manual,
        );
      },
    );

    test(
      'a later native terminal event confirms stop from stopFailed',
      () async {
        final container = buildContainer();
        final plan = _buildSequence(name: 'smart night plan');
        _stubBackendForStart(backend);
        when(() => backend.sequencerStart()).thenAnswer((_) async {});
        container
            .read(currentSequenceProvider.notifier)
            .takeOwnership(plan, ActivePlanOwner.smartNight);
        final executor = container.read(sequenceExecutorProvider);
        await executor.start();

        when(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).thenThrow(StateError('hardware wedged'));
        await expectLater(executor.stop(), throwsA(isA<StateError>()));
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.stopFailed,
        );
        expect(session.endedStatuses, isEmpty);

        // The native subscription stayed alive across the failed stop: a later
        // authoritative native Stopped confirms termination and drives the real
        // teardown exactly once.
        eventController.add(_sequencerEvent('Stopped'));
        await pumpEvents();
        await executor.terminalCleanupSettledForTest;

        expect(session.endedStatuses, ['stopped']);
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
        expect(container.read(currentRunIdProvider), isNull);
        expect(
          container.read(currentSequenceProvider.notifier).activeOwner,
          ActivePlanOwner.manual,
        );
      },
    );

    test(
      'stop() is a no-op from a settled idle state (idle stop guard)',
      () async {
        final container = buildContainer();
        _stubBackendForStart(backend);
        _stubConfirmingStop(backend, eventController);
        final executor = container.read(sequenceExecutorProvider);
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
        await executor.stop();
        verifyNever(() => backend.sequencerStop(origin: any(named: 'origin')));
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
      },
    );

    test('reset awaits the stop and settles idle', () async {
      final container = buildContainer();
      final executor = await startRunning(container);
      _stubConfirmingStop(backend, eventController);
      when(() => backend.sequencerReset()).thenAnswer((_) async {});

      await executor.reset();

      verify(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).called(1);
      verify(() => backend.sequencerReset()).called(1);
      expect(session.endedStatuses, ['stopped']);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );
    });

    test('reset does not force idle when the native stop fails', () async {
      final container = buildContainer();
      final executor = await startRunning(container);
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenThrow(StateError('hardware wedged'));

      await expectLater(executor.reset(), throwsA(isA<StateError>()));
      // The stop inside reset failed — stopFailed, never a lied-about idle.
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.stopFailed,
      );
      verifyNever(() => backend.sequencerReset());
    });

    test('a stop the native side accepts but never confirms settles to the '
        'controllable stopFailed instead of hanging forever', () async {
      final container = buildContainer();
      final executor = await startRunning(container);
      // The command is ACCEPTED (no throw) and then the native side goes
      // silent — the terminal event is never emitted. This is reachable in
      // production: the bridge's event receiver drops events on
      // `RecvError::Lagged`, so the one terminal finalization waits on can be
      // lost under load. Before the wait was bounded this hung forever, and
      // the operator's Stop button never returned.
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenAnswer((_) async {});

      await expectLater(
        executor.stop(),
        throwsA(isA<TimeoutException>()),
        reason: 'the unconfirmed stop must surface, not hang',
      );

      // Nothing may be torn down on a guess: the hardware was never confirmed
      // stopped, so the run keeps its identity and the session stays open.
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.stopFailed,
      );
      expect(container.read(currentRunIdProvider), isNotNull);
      expect(session.endedStatuses, isEmpty);

      // A late terminal still resumes THIS finalization rather than
      // stranding the run.
      eventController.add(_sequencerEvent('Stopped'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
      expect(session.endedStatuses, ['stopped']);
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.idle,
      );
    }, timeout: const Timeout(Duration(seconds: 90)));

    // Stop must not report a failed stop for a run that really did stop.
    //
    // The headless `load` -> `start` path runs the sequence on the NATIVE
    // executor without calling SequenceExecutor.start(), so this executor
    // installs no event subscription and no terminal event can reach
    // `_onTerminalEvent`. The device-service mirror still marks the state
    // `running`, so Stop passes `canStop` and commands the native stop —
    // leaving the status poll as the only source that can confirm the
    // terminal.
    void stubNativeStatus(String state) {
      when(
        () => backend.sequencerGetStatus(),
      ).thenAnswer((_) async => SequencerStatus(state: state, progress: 0.0));
    }

    test(
      'a stop whose terminal event can never arrive is still confirmed from '
      'the native executor own reported state, instead of a 30s false alarm',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);

        // The command is ACCEPTED and the native side never emits a terminal
        // event — exactly the headless load->start path, where this executor
        // has no subscription for one to arrive on.
        when(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).thenAnswer((_) async {});
        // ...but the native executor itself says the run is over. That is the
        // same authority the event carries, pulled instead of pushed.
        stubNativeStatus('cancelled');

        final watch = Stopwatch()..start();
        await executor.stop();
        watch.stop();

        // Confirmed and fully torn down — no TimeoutException, no false claim.
        expect(session.endedStatuses, ['stopped']);
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );
        expect(container.read(currentRunIdProvider), isNull);
        // Promptly, not after the 30 s confirmation window. Generous bound so
        // this asserts "did not wait for the timeout", not a latency budget.
        expect(
          watch.elapsed,
          lessThan(kNativeStopConfirmationTimeout ~/ 3),
          reason: 'the poll must confirm without burning the timeout',
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'stopping an already-terminal run returns promptly instead of blocking '
      'for the full confirmation window',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);
        when(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).thenAnswer((_) async {});
        stubNativeStatus('cancelled');

        // First stop settles the run.
        await executor.stop();
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.idle,
        );

        // The live rig answered a SECOND stop against the finished run with
        // another full 30 s block and the same false "NOT confirmed stopped"
        // message. Repeats must be immediate no-ops.
        for (var i = 0; i < 2; i++) {
          final watch = Stopwatch()..start();
          await executor.stop();
          watch.stop();
          expect(
            watch.elapsed,
            lessThan(kNativeStopConfirmationTimeout ~/ 3),
            reason: 'stop #${i + 2} on a finished run must not block',
          );
        }
        expect(session.endedStatuses, ['stopped']);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a native executor that reports itself still running is NOT treated as '
      'confirmation — the honest stopFailed is preserved',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);
        when(
          () => backend.sequencerStop(origin: any(named: 'origin')),
        ).thenAnswer((_) async {});
        // The poll must never manufacture a confirmation. If native still says
        // `running`, the camera may still be exposing and the operator must get
        // the truthful refusal, not a teardown on a guess.
        stubNativeStatus('running');

        await expectLater(
          executor.stop(),
          throwsA(isA<TimeoutException>()),
          reason: 'a live native executor must not confirm a stop',
        );
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.stopFailed,
        );
        expect(container.read(currentRunIdProvider), isNotNull);
        expect(session.endedStatuses, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('coalesces duplicate stop calls', () async {
      final container = buildContainer();
      final gate = Completer<void>();
      final executor = await startRunning(container);
      when(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).thenAnswer((_) => gate.future);

      final s1 = executor.stop();
      final s2 = executor.stop();

      gate.complete();
      // The stop COMMAND completing is not the release boundary: the real
      // backend then drives the native executor to a terminal state, which
      // arrives on the event stream and is what `_driveFinalization` waits for.
      // A gated stub has to deliver that terminal too, or the stop never
      // settles.
      await pumpEvents();
      eventController.add(_sequencerEvent('Stopped'));
      await Future.wait([s1, s2]);

      verify(
        () => backend.sequencerStop(origin: any(named: 'origin')),
      ).called(1);
      expect(session.endedStatuses, ['stopped']);
    });
  });

  group('E. automated editor ownership', () {
    Future<SequenceExecutor> startWithOwner(
      ProviderContainer container,
      Sequence planSequence,
      ActivePlanOwner owner,
    ) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .takeOwnership(planSequence, owner);
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    /// Load a dirty manual sequence and hand off to [owner], returning the
    /// exact stashed manual sequence that a release must restore.
    Sequence seedDirtyManualThenHandoff(
      ProviderContainer container,
      ActivePlanOwner owner,
      Sequence planSequence,
    ) {
      final notifier = container.read(currentSequenceProvider.notifier);
      notifier.loadSequence(_buildSequence(name: 'manual draft'));
      // Dirty the manual canvas so the restore must bring back a dirty flag.
      notifier.setName('manual draft (unsaved)');
      final stashed = container.read(currentSequenceProvider);
      expect(notifier.isDirty, isTrue);
      notifier.takeOwnership(planSequence, owner);
      expect(notifier.activeOwner, owner);
      return stashed!;
    }

    test('Smart Night restores stashed manual on completion', () async {
      final container = buildContainer();
      final plan = _buildSequence(name: 'smart night plan');
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      final stashed = seedDirtyManualThenHandoff(
        container,
        ActivePlanOwner.smartNight,
        plan,
      );
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      final notifier = container.read(currentSequenceProvider.notifier);
      expect(notifier.activeOwner, ActivePlanOwner.manual);
      expect(container.read(currentSequenceProvider), same(stashed));
      expect(notifier.isDirty, isTrue);
    });

    test('mosaic restores stashed manual on stop', () async {
      final container = buildContainer();
      final plan = _buildSequence(name: 'mosaic panels');
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      final stashed = seedDirtyManualThenHandoff(
        container,
        ActivePlanOwner.mosaic,
        plan,
      );
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      await executor.stop();

      final notifier = container.read(currentSequenceProvider.notifier);
      expect(notifier.activeOwner, ActivePlanOwner.manual);
      expect(container.read(currentSequenceProvider), same(stashed));
      expect(notifier.isDirty, isTrue);
    });

    test('Smart Night restores stashed manual on SequenceFailed', () async {
      final container = buildContainer();
      final plan = _buildSequence(name: 'smart night plan');
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      final stashed = seedDirtyManualThenHandoff(
        container,
        ActivePlanOwner.smartNight,
        plan,
      );
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      eventController.add(
        _sequencerEvent('SequenceFailed', data: {'error': 'mount fault'}),
      );
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      final notifier = container.read(currentSequenceProvider.notifier);
      expect(notifier.activeOwner, ActivePlanOwner.manual);
      expect(container.read(currentSequenceProvider), same(stashed));
      expect(notifier.isDirty, isTrue);
    });

    test('Smart Night restores stashed manual on start failure', () async {
      final container = buildContainer();
      final plan = _buildSequence(name: 'smart night plan');
      _stubBackendForStart(backend);
      when(
        () => backend.sequencerStart(),
      ).thenThrow(StateError('native start boom'));
      // The rollback best-effort stops the (possibly partial) native launch;
      // confirming the stop is what lets it release the editor handoff and
      // restore the stashed manual sequence.
      _stubConfirmingStop(backend, eventController);
      final stashed = seedDirtyManualThenHandoff(
        container,
        ActivePlanOwner.smartNight,
        plan,
      );
      final executor = container.read(sequenceExecutorProvider);

      await expectLater(executor.start(), throwsA(isA<StateError>()));

      final notifier = container.read(currentSequenceProvider.notifier);
      expect(notifier.activeOwner, ActivePlanOwner.manual);
      expect(container.read(currentSequenceProvider), same(stashed));
      expect(notifier.isDirty, isTrue);
    });

    test('autopilot ownership is NOT generically released', () async {
      final container = buildContainer();
      final plan = _buildSequence(name: 'autopilot target');
      final executor = await startWithOwner(
        container,
        plan,
        ActivePlanOwner.autopilot,
      );

      // Natural completion must NOT release autopilot — SchedulerEngine owns
      // that lifecycle and can redispatch on SequenceCompleted.
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
      expect(
        container.read(currentSequenceProvider.notifier).activeOwner,
        ActivePlanOwner.autopilot,
      );

      // Explicit stop must also NOT release autopilot.
      await executor.stop();
      expect(
        container.read(currentSequenceProvider.notifier).activeOwner,
        ActivePlanOwner.autopilot,
      );
    });
  });

  group('F. state capabilities', () {
    const settled = [
      SequenceExecutionState.idle,
      SequenceExecutionState.completed,
      SequenceExecutionState.failed,
    ];
    // Busy states that DO offer a Stop (active runs + the retryable failure
    // states). `finalizing` is busy too but is handled separately: it is pure
    // persistence with the hardware already stopped, so it offers no Stop.
    const stoppableBusy = [
      SequenceExecutionState.running,
      SequenceExecutionState.paused,
      SequenceExecutionState.stopping,
      SequenceExecutionState.recovering,
      SequenceExecutionState.stopFailed,
      SequenceExecutionState.cleanupFailed,
    ];
    const finalizing = SequenceExecutionState.finalizing;

    test('canStart / canReset / isSettled / isBusy split settled vs busy', () {
      for (final s in settled) {
        expect(s.canStart, isTrue, reason: '$s canStart');
        expect(s.canReset, isTrue, reason: '$s canReset');
        expect(s.isSettled, isTrue, reason: '$s isSettled');
        expect(s.isBusy, isFalse, reason: '$s isBusy');
      }
      for (final s in [...stoppableBusy, finalizing]) {
        expect(s.canStart, isFalse, reason: '$s canStart blocked');
        expect(s.canReset, isFalse, reason: '$s canReset blocked');
        expect(s.isSettled, isFalse, reason: '$s isSettled false');
        expect(s.isBusy, isTrue, reason: '$s isBusy');
      }
    });

    test('canStop is true for the stoppable busy states; false for settled AND '
        'finalizing (pure persistence offers no native Stop)', () {
      for (final s in stoppableBusy) {
        expect(s.canStop, isTrue, reason: '$s canStop');
      }
      for (final s in [...settled, finalizing]) {
        expect(s.canStop, isFalse, reason: '$s canStop blocked');
      }
    });

    test('canPause / canResume are exactly running / paused', () {
      for (final s in SequenceExecutionState.values) {
        expect(
          s.canPause,
          s == SequenceExecutionState.running,
          reason: '$s canPause',
        );
        expect(
          s.canResume,
          s == SequenceExecutionState.paused,
          reason: '$s canResume',
        );
      }
    });

    test('ownsHardware is true for live states + stopFailed, not cleanupFailed '
        'or finalizing', () {
      const owns = [
        SequenceExecutionState.running,
        SequenceExecutionState.paused,
        SequenceExecutionState.stopping,
        SequenceExecutionState.recovering,
        SequenceExecutionState.stopFailed,
      ];
      for (final s in owns) {
        expect(s.ownsHardware, isTrue, reason: '$s ownsHardware');
      }
      for (final s in [
        SequenceExecutionState.idle,
        SequenceExecutionState.completed,
        SequenceExecutionState.failed,
        SequenceExecutionState.cleanupFailed,
        finalizing,
      ]) {
        expect(s.ownsHardware, isFalse, reason: '$s ownsHardware false');
      }
    });

    test('needsAttention flags the failure surfaces; finalizing is calm', () {
      for (final s in [
        SequenceExecutionState.failed,
        SequenceExecutionState.recovering,
        SequenceExecutionState.stopFailed,
        SequenceExecutionState.cleanupFailed,
      ]) {
        expect(s.needsAttention, isTrue, reason: '$s needsAttention');
      }
      for (final s in [
        SequenceExecutionState.idle,
        SequenceExecutionState.running,
        SequenceExecutionState.paused,
        SequenceExecutionState.stopping,
        SequenceExecutionState.completed,
        finalizing,
      ]) {
        expect(s.needsAttention, isFalse, reason: '$s needsAttention false');
      }
    });
  });

  // The settled terminal state publishes only AFTER cleanup, so the live
  // run/session ids are already cleared by the time it is observable. The
  // report handoff therefore flows through the immutable one-shot
  // terminal-run result pinned below, never through the live ids.

  group('G. terminal-run result handoff', () {
    Future<SequenceExecutor> startRunning(ProviderContainer container) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    test('the one-shot terminal result is published only AFTER cleanup, '
        'carrying the finished run/session ids the live providers have since '
        'cleared', () async {
      final container = buildContainer();
      final executor = await startRunning(container);
      final runIdDuringRun = container.read(currentRunIdProvider);
      final sessionIdDuringRun = container
          .read(sessionStateProvider)
          .dbSessionId;
      expect(runIdDuringRun, isNotNull);
      expect(sessionIdDuringRun, isNotNull);
      // No terminal result while the run is live.
      expect(container.read(sequenceTerminalRunResultProvider), isNull);

      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      // The live providers are cleared by finalization...
      expect(container.read(currentRunIdProvider), isNull);
      expect(container.read(sessionStateProvider).dbSessionId, isNull);
      // ...but the immutable terminal result carries the SNAPSHOT the report and
      // its run-scoped Journal need.
      final result = container.read(sequenceTerminalRunResultProvider);
      expect(result, isNotNull);
      expect(result!.outcome, SequenceExecutionState.completed);
      expect(result.runStatus, 'completed');
      expect(
        result.runId,
        runIdDuringRun,
        reason: 'report/journal resolves against the finished run id',
      );
      expect(result.dbSessionId, sessionIdDuringRun);
    });

    test(
      'a failed run publishes a failed terminal result with its ids',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);
        final runId = container.read(currentRunIdProvider);
        final sessionId = container.read(sessionStateProvider).dbSessionId;

        eventController.add(
          _sequencerEvent('SequenceFailed', data: {'error': 'mount fault'}),
        );
        await pumpEvents();
        await executor.terminalCleanupSettledForTest;

        final result = container.read(sequenceTerminalRunResultProvider)!;
        expect(result.outcome, SequenceExecutionState.failed);
        expect(result.runStatus, 'failed');
        expect(result.runId, runId);
        expect(result.dbSessionId, sessionId);
      },
    );

    test('a fresh run start clears the previous terminal result', () async {
      final container = buildContainer();
      final executor = await startRunning(container);
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});

      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
      expect(container.read(sequenceTerminalRunResultProvider), isNotNull);

      // Starting the next run clears the stale result so the screen sees a
      // clean null -> result transition when THIS run ends (and never re-opens
      // the previous run's report).
      await executor.start();
      expect(container.read(sequenceTerminalRunResultProvider), isNull);
      await executor.stop();
    });
  });

  group('H. finalizing admission gate', () {
    Future<SequenceExecutor> startRunning(ProviderContainer container) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    test(
      'delayed durable cleanup holds a nonterminal `finalizing`; a rapid '
      'Start is rejected and the old cleanup cannot clobber a new run',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);
        final firstRunId = container.read(currentRunIdProvider);
        // Park the finalization drive in `finalizing` by gating endSession — the
        // durable cleanup is in flight but not finished.
        final gate = Completer<void>();
        session.endGate = gate;

        eventController.add(_sequencerEvent('Completed'));
        await pumpEvents();
        // Let the drive advance to the gated endSession.
        await Future<void>.delayed(Duration.zero);

        // Busy, NON-admissible finalization phase — never a settled completed.
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.finalizing,
        );
        expect(
          container.read(sequenceExecutionStateProvider).canStart,
          isFalse,
          reason: 'finalizing blocks start',
        );
        // The terminal result is NOT published until cleanup succeeds.
        expect(container.read(sequenceTerminalRunResultProvider), isNull);

        // A rapid Start is rejected and creates no second session/run, so the
        // in-flight cleanup (still holding firstRunId) cannot clear a fresh
        // run's id.
        await expectLater(executor.start(), throwsA(isA<StateError>()));
        expect(session.startCount, 1, reason: 'no second session created');
        expect(container.read(currentRunIdProvider), firstRunId);

        // Release the gate: cleanup completes, the settled state + result publish.
        gate.complete();
        await executor.terminalCleanupSettledForTest;
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.completed,
        );
        expect(container.read(currentRunIdProvider), isNull);
        expect(session.endedStatuses, ['completed']);
        final result = container.read(sequenceTerminalRunResultProvider)!;
        expect(result.runId, firstRunId);

        // A fresh Start now succeeds and gets its OWN run id; the settled old
        // cleanup cannot have clobbered it.
        session.endGate = null;
        _stubConfirmingStop(backend, eventController);
        when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
        await executor.start();
        final secondRunId = container.read(currentRunIdProvider);
        expect(secondRunId, isNotNull);
        expect(secondRunId, isNot(firstRunId));
        expect(session.startCount, 2);
        await executor.stop();
      },
    );
  });

  group('I. finishRun failure ordering', () {
    test('a finishRun failure does NOT call endSession and retains ids in a '
        'retryable cleanupFailed', () async {
      final dao = _MockRunsDao();
      when(
        () => dao.startRun(
          sequenceId: any(named: 'sequenceId'),
          sequenceName: any(named: 'sequenceName'),
          sequenceSnapshotJson: any(named: 'sequenceSnapshotJson'),
        ),
      ).thenAnswer((_) async => 4242);
      when(() => dao.updateStats(any(), any())).thenAnswer((_) async {});
      final finishCalls = <String>[];
      when(() => dao.finishRun(any(), any(), any())).thenAnswer((inv) async {
        finishCalls.add(inv.positionalArguments[1] as String);
        throw StateError('finishRun failed (injected)');
      });

      final container = buildContainerWithDao(dao);

      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      // Resolve appSettings up front: the mock DAO's instant startRun does not
      // yield enough for the AsyncNotifier's DB-backed build to complete, and
      // _startNativeExecution reads settings.valueOrNull (real DB path uses the
      // slower awaited startRun as cover).
      await container.read(appSettingsProvider.future);
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      expect(container.read(currentRunIdProvider), 4242);

      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      // finishRun was attempted and failed; endSession must NOT have been
      // called (no half-finished session end after an unpersisted run row).
      expect(finishCalls, ['completed']);
      expect(
        session.endedStatuses,
        isEmpty,
        reason: 'endSession must not run when finishRun failed',
      );
      // Retryable cleanupFailed with identity retained.
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.cleanupFailed,
      );
      expect(container.read(currentRunIdProvider), 4242);
      // No terminal result while cleanup is unfinished.
      expect(container.read(sequenceTerminalRunResultProvider), isNull);
    });
  });

  group('J. natural terminal + explicit stop race', () {
    Future<SequenceExecutor> startRunning(ProviderContainer container) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    test(
      'an explicit Stop landing during a natural finalization JOINS it: end '
      '+ report happen once, native stop is never issued, first intent wins',
      () async {
        final container = buildContainer();
        final executor = await startRunning(container);
        final gate = Completer<void>();
        session.endGate = gate;

        // Natural Completed claims the finalization first.
        eventController.add(_sequencerEvent('Completed'));
        await pumpEvents();
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.finalizing,
        );

        // An operator Stop lands now — it must JOIN the in-flight finalization,
        // not start a second one (no native stop, no second end/report).
        final stopFuture = executor.stop();
        gate.complete();
        await stopFuture;
        await executor.terminalCleanupSettledForTest;

        expect(
          session.endedStatuses,
          ['completed'],
          reason:
              'first-claimed terminal intent (completed) wins, exactly once',
        );
        verifyNever(() => backend.sequencerStop(origin: any(named: 'origin')));
        expect(
          container.read(sequenceExecutionStateProvider),
          SequenceExecutionState.completed,
        );
        expect(
          container.read(sequenceTerminalRunResultProvider)!.outcome,
          SequenceExecutionState.completed,
        );
      },
    );
  });

  group('K. live stats correctness', () {
    test('reassigning the SAME SequenceRunStats instance does NOT notify, but '
        'copy() does (why live stats must copy to notify)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final stats = SequenceRunStats();
      c.read(liveSequenceStatsProvider.notifier).state = stats;

      var notifications = 0;
      c.listen<SequenceRunStats?>(
        liveSequenceStatsProvider,
        (_, __) => notifications++,
      );

      // Mutate + re-store the SAME instance: StateProvider.updateShouldNotify is
      // !identical(prev, next), so this notifies NO consumer.
      stats.recordFrame(
        target: 'M31',
        filter: 'L',
        exposureSecs: 60,
        accepted: true,
      );
      c.read(liveSequenceStatsProvider.notifier).state = stats;
      expect(
        notifications,
        0,
        reason: 'same-instance reassign must not notify',
      );

      // Re-store a copy(): identity changes, so consumers are notified — and the
      // copy carries the mutated values.
      final snapshot = stats.copy();
      c.read(liveSequenceStatsProvider.notifier).state = snapshot;
      expect(notifications, 1, reason: 'copy() changes identity and notifies');
      expect(snapshot.framesCaptured, 1);
      expect(identical(snapshot, stats), isFalse);
    });

    test('an in-flight incremental updateStats is drained before the final '
        'finishRun, and no stale write lands after it', () async {
      final dao = _MockRunsDao();
      final ops = <String>[];
      when(
        () => dao.startRun(
          sequenceId: any(named: 'sequenceId'),
          sequenceName: any(named: 'sequenceName'),
          sequenceSnapshotJson: any(named: 'sequenceSnapshotJson'),
        ),
      ).thenAnswer((_) async => 55);
      final updateGate = Completer<void>();
      when(() => dao.updateStats(any(), any())).thenAnswer((_) async {
        ops.add('updateStats-start');
        await updateGate.future;
        ops.add('updateStats-end');
      });
      when(() => dao.finishRun(any(), any(), any())).thenAnswer((_) async {
        ops.add('finishRun');
      });

      final container = buildContainerWithDao(dao);
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      // See group I: warm the DB-backed appSettings AsyncNotifier before start()
      // since the mock DAO's instant startRun does not cover its async build.
      await container.read(appSettingsProvider.future);
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      // A real stat-producing event (TriggerFired) submits an incremental
      // updateStats through the executor's own path — held in flight by the gate.
      eventController.add(
        _sequencerEvent('TriggerFired', data: {'trigger_name': 'dusk'}),
      );
      await pumpEvents();
      expect(ops, contains('updateStats-start'));

      // The terminal finalization must DRAIN that pending write before the final
      // finishRun, so finishRun has not happened while the write is gated.
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await Future<void>.delayed(Duration.zero);
      expect(
        ops.contains('finishRun'),
        isFalse,
        reason: 'finishRun must wait for the in-flight write to drain',
      );

      // Release the write; finalization proceeds to finishRun.
      updateGate.complete();
      await executor.terminalCleanupSettledForTest;

      // Exactly one finishRun, AFTER every updateStats completed; and the seal
      // prevented any additional incremental write.
      expect(ops.where((o) => o == 'finishRun').length, 1);
      verify(() => dao.updateStats(any(), any())).called(1);
      final finishIdx = ops.indexOf('finishRun');
      for (var i = 0; i < ops.length; i++) {
        if (ops[i] == 'updateStats-end') {
          expect(
            i < finishIdx,
            isTrue,
            reason: 'no updateStats may complete after finishRun',
          );
        }
      }
    });
  });

  group('L. the run row publishes pause', () {
    // The GUI knew the run was paused; `sequence_runs.status` did not. During
    // a 52 s pause the row still read 'running', so the headless API, the web
    // dashboard and the phone — all of which read the DB, not the GUI —
    // believed the rig was still exposing while frame progress sat frozen.
    Future<SequenceExecutor> startRunning(ProviderContainer container) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      when(() => backend.sequencerPause()).thenAnswer((_) async {
        eventController.add(_sequencerEvent('Paused'));
      });
      when(() => backend.sequencerResume()).thenAnswer((_) async {
        eventController.add(_sequencerEvent('Resumed'));
      });
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    Future<String?> statusOf(ProviderContainer container) async {
      final runId = container.read(currentRunIdProvider)!;
      final row = await container
          .read(sequenceRunsDaoProvider)
          .getRunById(runId);
      return row?.status;
    }

    test('pausing writes paused, resuming writes running back', () async {
      final container = buildContainer();
      final executor = await startRunning(container);
      expect(await statusOf(container), 'running');

      await executor.pause();
      expect(
        await statusOf(container),
        'paused',
        reason: 'a remote client reading this row must not see "running"',
      );

      await executor.resume();
      expect(await statusOf(container), 'running');

      _stubConfirmingStop(backend, eventController);
      await executor.stop();
    });

    test('a row left paused by a dead process is closed out on open', () async {
      final container = buildContainer();
      final dao = container.read(sequenceRunsDaoProvider);
      final runId = await dao.startRun(
        sequenceId: null,
        sequenceName: 'interrupted night',
      );
      await dao.setLiveStatus(runId, 'paused');

      // The startup sweep runs in `beforeOpen`; re-running its statement here
      // is what a fresh process does with the same rows.
      await db.customStatement(
        "UPDATE sequence_runs SET status = 'interrupted' "
        "WHERE status IN ('running', 'paused')",
      );

      expect(
        (await dao.getRunById(runId))!.status,
        'interrupted',
        reason: 'paused is a LIVE status; it must not survive a crash forever',
      );
    });
  });

  group('M. frames are attributed to the target that produced them', () {
    // Every frame of a night whose only Target node was called "New Target"
    // was persisted with `captured_images.target_id` NULL, because
    // `TargetHeaderNode.catalogTargetId` is only populated for sequences
    // GENERATED from a library target. The Session Report filed the whole run
    // under "Untargeted" and per-target integration goals could never
    // complete, while the frames' own FITS OBJECT card named the target.
    Sequence targetSequence({String targetName = 'New Target'}) {
      final exposure = ExposureNode(
        id: 'expo-1',
        name: 'Take Exposures',
        durationSecs: 3,
        count: 4,
        parentId: 'target-1',
      );
      final target = TargetHeaderNode(
        id: 'target-1',
        name: 'Target',
        targetName: targetName,
        raHours: 5.59,
        decDegrees: -5.39,
        childIds: const ['expo-1'],
      );
      return Sequence.create(
        name: 'New Sequence',
        rootNodeId: 'target-1',
        nodes: {'target-1': target, 'expo-1': exposure},
      );
    }

    Future<SequenceExecutor> startRunning(
      ProviderContainer container,
      Sequence sequence,
    ) async {
      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      container.read(currentSequenceProvider.notifier).loadSequence(sequence);
      final executor = container.read(sequenceExecutorProvider);
      await executor.start();
      return executor;
    }

    Future<DbCapturedImage> awaitFrameRow(
      ProviderContainer container,
      String nodeId,
    ) async {
      final dao = container.read(imagesDaoProvider);
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final rows = await dao.getImagesByProducingNode(
          producingNodeId: nodeId,
        );
        if (rows.isNotEmpty) return (await dao.getImageById(rows.single.id))!;
      }
      fail('captured_images row for $nodeId was never written');
    }

    /// The recording session notifier reports a synthetic `dbSessionId` that
    /// has no row behind it, and `captured_images.session_id` is a real FK —
    /// so give it one before the frame lands.
    Future<void> materializeSessionRow(ProviderContainer container) async {
      final id = container.read(sessionStateProvider).dbSessionId!;
      await db.customStatement(
        'INSERT OR IGNORE INTO imaging_sessions (id, start_time) VALUES (?, ?)',
        [id, DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );
    }

    void emitAcceptedFrame(String nodeId) {
      eventController.add(
        _sequencerEvent(
          'FrameAccepted',
          data: {
            'node_id': nodeId,
            'frame': 1,
            'total': 4,
            'save_path': '/captures/New Target_R_0001.fits',
          },
        ),
      );
    }

    test('a builder-authored target gets a catalog row and the frame '
        'points at it', () async {
      final container = buildContainer();
      final executor = await startRunning(container, targetSequence());

      final targets = await container.read(targetsDaoProvider).getAllTargets();
      expect(
        targets.map((t) => t.name),
        contains('New Target'),
        reason: 'the target the run is imaging must exist to be counted',
      );

      await materializeSessionRow(container);
      emitAcceptedFrame('expo-1');
      final row = await awaitFrameRow(container, 'expo-1');
      expect(
        row.targetId,
        targets.firstWhere((t) => t.name == 'New Target').id,
        reason: 'a NULL here is what the Session Report renders as Untargeted',
      );

      _stubConfirmingStop(backend, eventController);
      await executor.stop();
    });

    test('re-running the same sequence reuses the one catalog row', () async {
      final container = buildContainer();
      final executor = await startRunning(container, targetSequence());
      _stubConfirmingStop(backend, eventController);
      await executor.stop();

      final executor2 = await startRunning(container, targetSequence());
      await executor2.stop();

      final named = (await container.read(targetsDaoProvider).getAllTargets())
          .where((t) => t.name == 'New Target');
      expect(
        named,
        hasLength(1),
        reason: 'a night per row would fragment integration totals',
      );
    });

    test('an unnamed target invents nothing', () async {
      final container = buildContainer();
      final executor = await startRunning(
        container,
        targetSequence(targetName: '   '),
      );

      expect(
        await container.read(targetsDaoProvider).getAllTargets(),
        isEmpty,
        reason: 'a target with no name cannot be identified later',
      );

      _stubConfirmingStop(backend, eventController);
      await executor.stop();
    });
  });

  /// Live desktop drive 2026-08-09, on a profile with no observing location —
  /// the UI said so in three places, and the executor was still told one:
  ///
  ///   INFO Updating sequencer location: lat=Some(0.0), lon=Some(0.0)
  ///   WARN Trigger fired: Altitude Limit (altitude_limit) - action: NextTarget
  ///   ... once per 60 s cooldown, all run
  ///
  /// `sequencerUpdateLocation` takes non-nullable doubles, so an unset site
  /// arrives in Rust as a real place off West Africa. Vega is below 30° from
  /// there at that hour, so the always-armed altitude trigger voted to abandon
  /// the target. With more than one target, every one would be skipped in turn.
  ///
  /// The Rust side already handles a genuinely absent location — it computes an
  /// altitude only when RA, Dec, lat and lon are all present and returns false
  /// from the condition otherwise. Withholding the push is what lets that work.
  group('F. an unset observing location is not pushed as Null Island', () {
    test('no location configured means no location pushed', () async {
      final container = buildContainer();
      // Settings must be RESOLVED, not merely absent: the defect is that a
      // loaded-but-unconfigured profile reports latitude 0 / longitude 0 and
      // that pair gets pushed as if it were a site. Without this await the
      // provider is still loading, the push is skipped for an unrelated reason,
      // and the test passes with the guard deleted — which is exactly what it
      // did the first time it was written.
      await container.read(appSettingsProvider.future);
      final loaded = container.read(appSettingsProvider).valueOrNull;
      expect(loaded, isNotNull);
      expect(loaded!.latitude, 0.0);
      expect(loaded.longitude, 0.0);

      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());

      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      verifyNever(
        () => backend.sequencerUpdateLocation(
          latitude: any(named: 'latitude'),
          longitude: any(named: 'longitude'),
        ),
      );

      await executor.stop();
    });

    test('a configured location is still pushed', () async {
      final container = buildContainer();
      await container.read(appSettingsProvider.future);
      final settings = container.read(appSettingsProvider.notifier);
      await settings.setLatitude(39.9719);
      await settings.setLongitude(-75.3576);

      _stubBackendForStart(backend);
      when(() => backend.sequencerStart()).thenAnswer((_) async {});
      _stubConfirmingStop(backend, eventController);
      when(() => backend.discardCheckpoint()).thenAnswer((_) async {});
      container
          .read(currentSequenceProvider.notifier)
          .loadSequence(_buildSequence());

      final executor = container.read(sequenceExecutorProvider);
      await executor.start();

      verify(
        () => backend.sequencerUpdateLocation(
          latitude: 39.9719,
          longitude: -75.3576,
        ),
      ).called(1);

      await executor.stop();
    });
  });

  group('N. the headless load -> start path, twice in one process', () {
    // The appliance's canonical flow is POST /api/sequencer/load ->
    // POST /api/sequencer/start, which never calls start(): the handler opens
    // the `imaging_sessions` row itself and reaches this executor only through
    // attachHostListenersForNativeRun. So nothing on that path clears the per-
    // run finalization latches, and the FIRST night leaves `_settledRunStatus`
    // behind. Reproduced on the release bundle with
    // tools/harness/d1_sim_night/two_nights.sh: night two reached `completed`
    // on the wire, its session row stayed `active` forever, and no integration
    // and no draft were ever made for it.

    /// One headless night: the handler's session row, the handler's attach,
    /// then the native `Completed` the run ends on.
    Future<void> headlessNight(
      ProviderContainer c,
      SequenceExecutor executor,
      String name,
    ) async {
      await c
          .read(sessionStateProvider.notifier)
          .startSession(targetName: name);
      await executor.attachHostListenersForNativeRun();
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;
    }

    test('the second night finalizes its own session', () async {
      final container = buildContainer();
      _stubBackendForStart(backend);
      final executor = container.read(sequenceExecutorProvider);

      await headlessNight(container, executor, 'night one');
      expect(session.endedStatuses, ['completed']);

      await headlessNight(container, executor, 'night two');
      expect(
        session.endedStatuses,
        ['completed', 'completed'],
        reason:
            'the second night ended on the wire, so its session row must be '
            'closed too — an open row is a night nothing will ever integrate',
      );
    });

    test(
      'the second night publishes ITS session for post-processing',
      () async {
        final container = buildContainer();
        _stubBackendForStart(backend);
        final executor = container.read(sequenceExecutorProvider);

        await headlessNight(container, executor, 'night one');
        final first = container.read(sequenceTerminalRunResultProvider)!;

        await headlessNight(container, executor, 'night two');
        final second = container.read(sequenceTerminalRunResultProvider)!;

        // The terminal result is what auto-integration and the dawn Darkroom
        // pass key off (autoIntegrationCoordinatorProvider reads dbSessionId).
        // A missing or stale one is a night with masters nobody makes.
        expect(second.dbSessionId, isNot(first.dbSessionId));
        expect(second.dbSessionId, session.lastSessionId);
        expect(second.generation, greaterThan(first.generation));
        expect(second.runStatus, 'completed');
      },
    );

    test('a retained cleanupFailed transaction survives a re-attach', () async {
      final container = buildContainer();
      _stubBackendForStart(backend);
      final executor = container.read(sequenceExecutorProvider);

      // Night one cannot close its session: the drive settles to the retryable
      // cleanupFailed and KEEPS its transaction for the retry.
      session.throwOnEnd = true;
      await headlessNight(container, executor, 'night one');
      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.cleanupFailed,
      );

      // A re-attach must not discard that transaction: the run's hardware
      // ending was never fully recorded, and a fresh finalization on top would
      // publish a verdict for a run whose cleanup never finished.
      await executor.attachHostListenersForNativeRun();
      eventController.add(_sequencerEvent('Completed'));
      await pumpEvents();
      await executor.terminalCleanupSettledForTest;

      expect(
        container.read(sequenceExecutionStateProvider),
        SequenceExecutionState.cleanupFailed,
      );
      expect(container.read(sequenceTerminalRunResultProvider), isNull);
    });
  });
}
