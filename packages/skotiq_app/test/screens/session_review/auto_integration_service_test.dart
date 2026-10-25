// The night-end coordinator and the host setting that decides whether the
// night end builds masters.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/auto_integration_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// The night-end runner, recording the nights it is handed.
class _RecordingRunner extends NightEndRunner {
  _RecordingRunner(super.ref);

  final calls = <int>[];
  final reasons = <String>[];

  @override
  Future<void> start() async {}

  @override
  Future<NightEndRun?> nightEnded({
    required int sessionId,
    required String reason,
    EonReport? calibration,
  }) async {
    calls.add(sessionId);
    reasons.add(reason);
    return NightEndRun(
      id: 'n$sessionId',
      startedAt: DateTime(2026, 10, 24, 6),
      reason: reason,
      targets: const [
        NightEndTarget(
          target: 'NGC891',
          build: NightEndStep(NightEndStepState.done),
          nights: 3,
        ),
      ],
    );
  }
}

void main() {
  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, FfiBackend(database: db)),
      ),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('building masters at night end', () {
    test('is on for an install that never set it', () async {
      expect(await db.settingsDao.getSetting(kAutoIntegrateSettingKey), isNull);
      expect(
          await container.read(autoIntegrationEnabledProvider.future), isTrue);
      final settings = await NightEndAutomationSettings.load(db.settingsDao);
      expect(settings.build, isTrue);
      expect(settings.stepsOn, contains('build'));
    });

    test('stays off when the operator turned it off', () async {
      await container
          .read(autoIntegrationSettingsActionsProvider)
          .setEnabled(false);
      expect(
          await db.settingsDao.getSetting(kAutoIntegrateSettingKey), 'false');
      expect(
          await container.read(autoIntegrationEnabledProvider.future), isFalse);
      final settings = await NightEndAutomationSettings.load(db.settingsDao);
      expect(settings.build, isFalse);
    });

    test('an explicit on reads as on', () async {
      await db.settingsDao.setSetting(kAutoIntegrateSettingKey, 'true');
      final settings = await NightEndAutomationSettings.load(db.settingsDao);
      expect(settings.build, isTrue);
    });
  });

  Future<void> settleCoordinator() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('host coordinator runs independently of the sequencer screen', () async {
    late _RecordingRunner recording;
    final coordinatorContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, FfiBackend(database: db)),
        ),
        nightEndRunnerProvider.overrideWith((ref) {
          recording = _RecordingRunner(ref);
          return recording;
        }),
      ],
    );
    addTearDown(coordinatorContainer.dispose);

    coordinatorContainer.read(autoIntegrationCoordinatorProvider);
    coordinatorContainer
        .read(sequenceTerminalRunResultProvider.notifier)
        .state = const SequenceTerminalRunResult(
      generation: 1,
      outcome: SequenceExecutionState.completed,
      runStatus: 'completed',
      runId: 10,
      dbSessionId: 20,
    );
    await settleCoordinator();

    expect(recording.calls, [20]);
    expect(recording.reasons, ['the plan completed']);
    final toast = coordinatorContainer.read(autoIntegrationCompletionProvider);
    expect(toast?.generation, 1);
    expect(toast?.result.message, 'NGC891: masters ready from 3 nights.');

    coordinatorContainer
        .read(sequenceTerminalRunResultProvider.notifier)
        .state = const SequenceTerminalRunResult(
      generation: 2,
      outcome: SequenceExecutionState.idle,
      runStatus: 'stopped',
      runId: 11,
      dbSessionId: 21,
    );
    await settleCoordinator();
    expect(recording.calls, [20],
        reason: 'Stopped runs must not auto-integrate');

    // The dawn park files the run as aborted; it ended the night, so the
    // night's subs are integrated.
    coordinatorContainer.read(sequenceStopEvidenceProvider.notifier).state =
        const SequenceStopDecision(
      SequenceStopAuthor.system,
      origin: 'dawn_approaching',
      parked: true,
    );
    coordinatorContainer
        .read(sequenceTerminalRunResultProvider.notifier)
        .state = const SequenceTerminalRunResult(
      generation: 3,
      outcome: SequenceExecutionState.idle,
      runStatus: 'aborted',
      runId: 12,
      dbSessionId: 22,
    );
    await settleCoordinator();
    expect(recording.calls, [20, 22],
        reason: 'a night ended by the dawn park must integrate');
    expect(recording.reasons.last, 'dawn ended imaging');

    // An obstruction park ends the night the same way.
    coordinatorContainer.read(sequenceStopEvidenceProvider.notifier).state =
        const SequenceStopDecision(
      SequenceStopAuthor.system,
      origin: 'obstruction',
      parked: true,
    );
    coordinatorContainer
        .read(sequenceTerminalRunResultProvider.notifier)
        .state = const SequenceTerminalRunResult(
      generation: 4,
      outcome: SequenceExecutionState.idle,
      runStatus: 'aborted',
      runId: 13,
      dbSessionId: 24,
    );
    await settleCoordinator();
    expect(recording.calls, [20, 22, 24],
        reason: 'a night ended by an obstruction must integrate');

    // The operator stopped a night and ended it with a manual end-of-night
    // calibration: that night is integrated too.
    coordinatorContainer.read(nightIntegrationRequestProvider.notifier).state =
        const NightIntegrationRequest(generation: 1, sessionId: 23);
    await settleCoordinator();
    expect(recording.calls, [20, 22, 24, 23]);

    // The same request seen again is not a second build.
    coordinatorContainer.read(nightIntegrationRequestProvider.notifier).state =
        const NightIntegrationRequest(generation: 1, sessionId: 23);
    await settleCoordinator();
    expect(recording.calls, [20, 22, 24, 23]);
  });

  test('remote clients neither process local data nor store the host setting',
      () async {
    final backend = _MockNetworkBackend();
    when(backend.getAutoIntegrationEnabled).thenAnswer((_) async => true);
    when(
      () => backend.setAutoIntegrationEnabled(any()),
    ).thenAnswer((_) async {});

    _RecordingRunner? recording;
    final remoteContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        nightEndRunnerProvider.overrideWith((ref) {
          return recording = _RecordingRunner(ref);
        }),
      ],
    );
    addTearDown(remoteContainer.dispose);
    remoteContainer.read(autoIntegrationServiceProvider);

    expect(await remoteContainer.read(autoIntegrationEnabledProvider.future),
        isTrue);
    await remoteContainer
        .read(autoIntegrationSettingsActionsProvider)
        .setEnabled(false);
    verify(() => backend.setAutoIntegrationEnabled(false)).called(1);
    expect(
      await db.settingsDao.getSetting(kAutoIntegrateSettingKey),
      isNull,
    );

    remoteContainer.read(autoIntegrationCoordinatorProvider);
    remoteContainer.read(sequenceTerminalRunResultProvider.notifier).state =
        const SequenceTerminalRunResult(
      generation: 1,
      outcome: SequenceExecutionState.completed,
      runStatus: 'completed',
      runId: 1,
      dbSessionId: 2,
    );
    await Future<void>.delayed(Duration.zero);
    expect(recording, isNull, reason: 'a remote client runs no night end');
  });
}
