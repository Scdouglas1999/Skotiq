// A RESUMED run must record the same identity a fresh run records.
//
// The Continue Session handoff dialog builds its context out of
// `imaging_sessions` (QuickStartService._buildQuickStartContext), so a session
// row with profile_id / sequence_id NULL is what makes it print "Equipment
// Profile: Unknown Profile" and "Sequence: No Sequence" — and what leaves its
// primary action, "Load Previous Setup", with nothing to load.
//
// The fresh-start path was fixed to stamp both ids. The resume path was not:
// it called `startSession(targetName:)` and dropped the profile and the
// sequence, even though the tree had just been recovered into
// `currentSequenceProvider` (the very next line reads its `databaseId` for the
// run row) and the active profile never left memory. That is the one path
// where the dialog matters most — the dialog exists for an interrupted night,
// and an interrupted night is resumed.
//
// The same gap orphaned the resumed run's frames: `_bindCatalogTargets` gives
// every builder-authored Target node a `targets` row so the frames it produces
// carry `captured_images.target_id`, and only `start()` called it. Frames
// captured after a resume registered with target_id NULL and the night split
// between the target and "Untargeted".

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`,
/// so the resume path's deep runtime-config push runs end to end without
/// stubbing thirty calls.
class _PermissiveBackend extends MockBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) {
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

/// The frame registration is fire-and-forget; poll for the row it writes.
Future<DbCapturedImage> _awaitFrameRow(ImagesDao dao, String nodeId) async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final rows = await dao.getImagesByProducingNode(producingNodeId: nodeId);
    if (rows.isNotEmpty) {
      final row = await dao.getImageById(rows.single.id);
      if (row != null) return row;
    }
  }
  fail('captured_images row for $nodeId was never written');
}

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late SessionsDao sessionsDao;
  late ImagesDao imagesDao;
  late TargetsDao targetsDao;
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
    eventController =
        StreamController<bridge_event.SkotiqEvent>.broadcast();
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
    imagesDao = ImagesDao(db);
    targetsDao = TargetsDao(db);
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

  test('a resumed run records its profile and its sequence', () async {
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

    await c.read(sequenceExecutorProvider).resumeFromCheckpoint();

    final active = await sessionsDao.getActiveSessions();
    expect(active, hasLength(1));
    expect(
      active.single.profileId,
      profileId,
      reason: 'the dialog printed "Unknown Profile" from a null here',
    );
    expect(
      active.single.sequenceId,
      sequenceRowId,
      reason: 'the dialog printed "No Sequence" from a null here',
    );
  });

  test(
    'running a never-saved sequence still records which sequence ran',
    () async {
      final profileId = await EquipmentProfilesDao(
        db,
      ).createProfile(EquipmentProfilesCompanion.insert(name: 'Backyard Rig'));

      final c = buildContainer(profileId: profileId);
      // No `databaseId`: the tree the operator built in the sequencer and
      // started without saving. This is the state the live repro was in — the
      // `sequences` table was empty after three complete runs, so the Continue
      // Session dialog offered a night it could only call "No Sequence".
      c
          .read(currentSequenceProvider.notifier)
          .loadSequence(
            Sequence.create(
              name: 'New Sequence',
              rootNodeId: 'target1',
              nodes: {
                'target1': TargetHeaderNode(
                  id: 'target1',
                  targetName: 'M31',
                  raHours: 0.712,
                  decDegrees: 41.269,
                  childIds: const ['exp1'],
                ),
                'exp1': ExposureNode(
                  id: 'exp1',
                  durationSecs: 180.0,
                  count: 10,
                ),
              },
            ),
          );

      await c.read(sequenceExecutorProvider).start();

      final saved = await SequencesDao(db).getAllSequences();
      expect(saved, hasLength(1), reason: 'the run must leave a row to reload');
      final active = await sessionsDao.getActiveSessions();
      expect(active.single.sequenceId, saved.single.id);
      expect(
        c.read(currentSequenceProvider)?.databaseId,
        saved.single.id,
        reason:
            'the editor must adopt the id, or the next run of the same document '
            'writes a second row',
      );
    },
  );

  test(
    'an autopilot-generated run does not file itself in the library',
    () async {
      final profileId = await EquipmentProfilesDao(
        db,
      ).createProfile(EquipmentProfilesCompanion.insert(name: 'Backyard Rig'));

      final c = buildContainer(profileId: profileId);
      c
          .read(currentSequenceProvider.notifier)
          .takeOwnership(
            Sequence.create(
              name: 'Autopilot: NGC 7000',
              rootNodeId: 'exp1',
              nodes: {'exp1': ExposureNode(id: 'exp1', durationSecs: 60.0)},
            ),
            ActivePlanOwner.autopilot,
          );

      await c.read(sequenceExecutorProvider).start();

      expect(
        await SequencesDao(db).getAllSequences(),
        isEmpty,
        reason:
            'the scheduler builds a fresh tree per candidate; saving each one '
            'would bury the operator\'s own sequences under a night of machine '
            'output',
      );
    },
  );

  test('a fresh run binds its builder-authored target too', () async {
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
    await executor.start();

    executor.handleSequencerEventForTest(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'FrameAccepted',
        data: const {
          'node_id': 'exp1',
          'frame': 1,
          'total': 10,
          'save_path': '/captures/m31/L_0001.fits',
        },
      ),
    );

    final row = await _awaitFrameRow(imagesDao, 'exp1');
    final target = await targetsDao.getTargetById(row.targetId ?? -1);
    expect(
      target?.name,
      'M31',
      reason:
          'a Target typed into the builder carries no catalogTargetId, so '
          'without the run-start binding its frames are filed as Untargeted '
          'while their own FITS OBJECT card names the target',
    );
  });

  test(
    'frames captured after a resume are attributed to their target',
    () async {
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
      await executor.resumeFromCheckpoint();

      executor.handleSequencerEventForTest(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'FrameAccepted',
          data: const {
            'node_id': 'exp1',
            'frame': 5,
            'total': 10,
            'save_path': '/captures/m31/L_0005.fits',
          },
        ),
      );

      final row = await _awaitFrameRow(imagesDao, 'exp1');
      final target = await targetsDao.getTargetById(row.targetId ?? -1);
      expect(
        target?.name,
        'M31',
        reason:
            'a resumed run left target_id NULL, so its frames were filed as '
            'Untargeted while the same night\'s pre-crash frames were not',
      );
    },
  );
}
