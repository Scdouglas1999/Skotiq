import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
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
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, FfiBackend(database: db)),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  group('building masters at night end', () {
    test('is on for an install that never set it', () async {
      expect(
        await db.settingsDao.getSetting(NightEndAutomationSettings.buildKey),
        isNull,
      );
      final settings = await NightEndAutomationSettings.load(db.settingsDao);
      expect(settings.build, isTrue);
      expect(settings.stepsOn, contains('build'));
    });

    test('stays off when the operator turned it off', () async {
      await container.read(nightEndAutomationActionsProvider).setBuild(false);
      expect(
        await db.settingsDao.getSetting(NightEndAutomationSettings.buildKey),
        'false',
      );
      final settings = await NightEndAutomationSettings.load(db.settingsDao);
      expect(settings.build, isFalse);
    });

    test('an explicit on reads as on', () async {
      await db.settingsDao.setSetting(
        NightEndAutomationSettings.buildKey,
        'true',
      );
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

    coordinatorContainer.read(nightEndCoordinatorProvider);
    coordinatorContainer
        .read(runRecordProvider.notifier)
        .publishTerminal(
          const SequenceTerminalRunResult(
            generation: 1,
            outcome: SequenceExecutionState.completed,
            runStatus: 'completed',
            runId: 10,
            dbSessionId: 20,
          ),
        );
    await settleCoordinator();

    expect(recording.calls, [20]);
    expect(recording.reasons, ['the plan completed']);
    final toast = coordinatorContainer.read(nightEndCompletionProvider);
    expect(toast?.generation, 1);
    expect(toast?.toast.message, 'NGC891: masters ready from 3 nights.');

    coordinatorContainer
        .read(runRecordProvider.notifier)
        .publishTerminal(
          const SequenceTerminalRunResult(
            generation: 2,
            outcome: SequenceExecutionState.idle,
            runStatus: 'stopped',
            runId: 11,
            dbSessionId: 21,
          ),
        );
    await settleCoordinator();
    expect(recording.calls, [
      20,
    ], reason: 'a stopped run does not end the night');

    // The dawn park files the run as aborted; it ended the night, so the
    // night is handled.
    coordinatorContainer
        .read(runRecordProvider.notifier)
        .setStopEvidence(
          const SequenceStopDecision(
            SequenceStopAuthor.system,
            origin: 'dawn_approaching',
            parked: true,
          ),
        );
    coordinatorContainer
        .read(runRecordProvider.notifier)
        .publishTerminal(
          const SequenceTerminalRunResult(
            generation: 3,
            outcome: SequenceExecutionState.idle,
            runStatus: 'aborted',
            runId: 12,
            dbSessionId: 22,
          ),
        );
    await settleCoordinator();
    expect(recording.calls, [
      20,
      22,
    ], reason: 'a night ended by the dawn park is handled');
    expect(recording.reasons.last, 'dawn ended imaging');

    // An obstruction park ends the night the same way.
    coordinatorContainer
        .read(runRecordProvider.notifier)
        .setStopEvidence(
          const SequenceStopDecision(
            SequenceStopAuthor.system,
            origin: 'obstruction',
            parked: true,
          ),
        );
    coordinatorContainer
        .read(runRecordProvider.notifier)
        .publishTerminal(
          const SequenceTerminalRunResult(
            generation: 4,
            outcome: SequenceExecutionState.idle,
            runStatus: 'aborted',
            runId: 13,
            dbSessionId: 24,
          ),
        );
    await settleCoordinator();
    expect(recording.calls, [
      20,
      22,
      24,
    ], reason: 'a night ended by an obstruction is handled');

    // The operator stopped a night and ended it with a manual end-of-night
    // calibration: that night is handled too.
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

  test('a linked client runs no night end over its own data', () async {
    final backend = _MockNetworkBackend();

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
    remoteContainer.read(nightEndCoordinatorProvider);
    remoteContainer
        .read(runRecordProvider.notifier)
        .publishTerminal(
          const SequenceTerminalRunResult(
            generation: 1,
            outcome: SequenceExecutionState.completed,
            runStatus: 'completed',
            runId: 1,
            dbSessionId: 2,
          ),
        );
    await Future<void>.delayed(Duration.zero);
    expect(recording, isNull, reason: 'a remote client runs no night end');
  });
}
