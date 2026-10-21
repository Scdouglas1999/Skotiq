// Restoring an interrupted run from its checkpoint loads it and waits: no
// instruction and no device command runs until Start, which then continues the
// run from the checkpoint rather than starting the sequence over.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`,
/// so the resume path's deep runtime-config push runs end to end without
/// stubbing thirty calls.
class _PermissiveBackend extends MockBackend {
  /// Every backend member the code under test touched, in order.
  final calls = <Symbol>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    final result = super.noSuchMethod(invocation);
    return result ?? Future<void>.value();
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._state);
  final AppSettingsState _state;

  @override
  Future<AppSettingsState> build() async => _state;
}

SequenceValidatorService _passingValidator(Ref ref) => SequenceValidatorService(
  ref: ref,
  syncRules: const [],
  refAwareRules: const [],
  asyncRules: const [],
);

/// A sequence as the builder produces one: a Target the operator typed in (no
/// `catalogTargetId`) with a single exposure under it.
Sequence _builderSequence(int databaseId) {
  return Sequence.create(
    name: 'M31 LRGB',
    rootNodeId: 'target1',
    nodes: {
      'target1': TargetHeaderNode(
        id: 'target1',
        targetName: 'M31',
        raHours: 0.712,
        decDegrees: 41.269,
        childIds: const ['exp1'],
      ),
      'exp1': ExposureNode(id: 'exp1', durationSecs: 180.0, count: 10),
    },
  ).copyWith(databaseId: databaseId);
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late SessionsDao sessionsDao;
  ProviderContainer? container;

  ProviderContainer buildContainer({required int profileId}) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        activeEquipmentProfileProvider.overrideWithValue(
          EquipmentProfileModel(id: profileId, name: 'Backyard Rig'),
        ),
        appSettingsProvider.overrideWith(
          () => _FixedSettingsNotifier(const AppSettingsState()),
        ),
        sequenceValidatorProvider.overrideWith(_passingValidator),
      ],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    backend = _PermissiveBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.getCheckpointInfo()).thenAnswer(
      (_) async => CheckpointInfo(
        sequenceName: 'M31 LRGB',
        timestamp: DateTime.now(),
        completedExposures: 4,
        completedIntegrationSecs: 720.0,
        canResume: true,
        ageSeconds: 30,
      ),
    );
    when(() => backend.resumeFromCheckpoint()).thenAnswer((_) async {});
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    sessionsDao = SessionsDao(db);
  });

  tearDown(() async {
    // Let the run lifecycle's fire-and-forget DB work settle against the
    // still-open database before the container (and the DB) go away.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    container?.dispose();
    if (!eventController.isClosed) {
      await eventController.close();
    }
    await db.close();
  });

  test('restoring a checkpoint loads the run and runs nothing', () async {
    final profileId = await EquipmentProfilesDao(
      db,
    ).createProfile(EquipmentProfilesCompanion.insert(name: 'Backyard Rig'));
    final sequenceRowId = await SequencesDao(
      db,
    ).createSequence(SequencesCompanion.insert(name: 'M31 LRGB'));
    final c = buildContainer(profileId: profileId);
    c
        .read(currentSequenceProvider.notifier)
        .loadSequence(_builderSequence(sequenceRowId));
    backend.calls.clear();

    await c.read(sequenceExecutorProvider).restoreFromCheckpoint();

    // Only reads and the native prepare step: no start, no device command.
    const allowed = {
      #getCheckpointInfo,
      #resumeFromCheckpoint,
      #eventStream,
      #polarAlignmentEvents,
    };
    expect(
      backend.calls.toSet().difference(allowed),
      isEmpty,
      reason: 'restoring sent ${backend.calls}',
    );
    expect(backend.calls, contains(#resumeFromCheckpoint));
    expect(c.read(sequenceExecutionStateProvider), SequenceExecutionState.idle);
    expect(await sessionsDao.getActiveSessions(), isEmpty);
    expect(c.read(sequenceProgressProvider).completedExposures, 4);
    expect(c.read(restoredCheckpointProvider)?.sequenceName, 'M31 LRGB');
    expect(c.read(currentSequenceProvider)?.name, 'M31 LRGB');
  });

  test('Start after a restore continues from the checkpoint', () async {
    final profileId = await EquipmentProfilesDao(
      db,
    ).createProfile(EquipmentProfilesCompanion.insert(name: 'Backyard Rig'));
    final sequenceRowId = await SequencesDao(
      db,
    ).createSequence(SequencesCompanion.insert(name: 'M31 LRGB'));
    final c = buildContainer(profileId: profileId);
    c
        .read(currentSequenceProvider.notifier)
        .loadSequence(_builderSequence(sequenceRowId));
    final executor = c.read(sequenceExecutorProvider);
    await executor.restoreFromCheckpoint();
    backend.calls.clear();

    await executor.start();

    expect(backend.calls.where((m) => m == #sequencerStart), hasLength(1));
    expect(
      backend.calls,
      isNot(contains(#sequencerLoadJson)),
      reason: 'loading the tree again would throw away the prepared resume',
    );
    expect(backend.calls, isNot(contains(#resumeFromCheckpoint)));
    expect(
      c.read(sequenceExecutionStateProvider),
      SequenceExecutionState.running,
    );
    expect(await sessionsDao.getActiveSessions(), hasLength(1));
    expect(c.read(restoredCheckpointProvider), isNull);
    expect(executor.hasRestoredCheckpoint, isFalse);
  });

  test('Start after editing the restored sequence starts it fresh', () async {
    final profileId = await EquipmentProfilesDao(
      db,
    ).createProfile(EquipmentProfilesCompanion.insert(name: 'Backyard Rig'));
    final sequenceRowId = await SequencesDao(
      db,
    ).createSequence(SequencesCompanion.insert(name: 'M31 LRGB'));
    final c = buildContainer(profileId: profileId);
    c
        .read(currentSequenceProvider.notifier)
        .loadSequence(_builderSequence(sequenceRowId));
    final executor = c.read(sequenceExecutorProvider);
    await executor.restoreFromCheckpoint();
    final restored = c.read(currentSequenceProvider)!;
    c
        .read(currentSequenceProvider.notifier)
        .loadSequence(
          restored.copyWith(
            nodes: {
              ...restored.nodes,
              'exp1': ExposureNode(id: 'exp1', durationSecs: 120.0, count: 5),
            },
          ),
          discardUnsaved: true,
        );
    backend.calls.clear();

    await executor.start();

    expect(backend.calls, contains(#sequencerLoadJson));
    expect(c.read(restoredCheckpointProvider), isNull);
  });

  test('resumeFromCheckpoint is a restore followed by a start', () async {
    final profileId = await EquipmentProfilesDao(
      db,
    ).createProfile(EquipmentProfilesCompanion.insert(name: 'Backyard Rig'));
    final sequenceRowId = await SequencesDao(
      db,
    ).createSequence(SequencesCompanion.insert(name: 'M31 LRGB'));
    final c = buildContainer(profileId: profileId);
    c
        .read(currentSequenceProvider.notifier)
        .loadSequence(_builderSequence(sequenceRowId));
    backend.calls.clear();

    await c.read(sequenceExecutorProvider).resumeFromCheckpoint();

    expect(backend.calls, isNot(contains(#sequencerLoadJson)));
    expect(backend.calls.where((m) => m == #sequencerStart), hasLength(1));
  });
}
