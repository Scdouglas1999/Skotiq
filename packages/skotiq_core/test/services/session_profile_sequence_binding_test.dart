import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The Continue Session handoff dialog said "Unknown Profile" and "No Sequence"
/// while naming the sequence in its own header and with a real profile active.
/// The nulls were real: imaging_sessions rows were written with profile_id and
/// sequence_id NULL because SessionStateNotifier.startSession (called by the
/// sequence executor) never carried them, and QuickStartService builds its
/// context out of that row.
void main() {
  late SkotiqDatabase db;
  late SessionsDao sessionsDao;
  late EquipmentProfilesDao profilesDao;
  late SequencesDao sequencesDao;
  late SequenceCheckpointsDao checkpointsDao;
  late SessionService sessionService;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    sessionsDao = SessionsDao(db);
    profilesDao = EquipmentProfilesDao(db);
    sequencesDao = SequencesDao(db);
    checkpointsDao = SequenceCheckpointsDao(db);
    sessionService = SessionService(
      records: ImagingRecordsRepository.local(
        sessionsDao: sessionsDao,
        imagesDao: ImagesDao(db),
      ),
      checkpointsDao: checkpointsDao,
      logger: LoggingService(),
    );
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {
      // A test may have closed it already.
    }
  });

  test('a session started under a sequence records that sequence', () async {
    final profileId = await profilesDao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Backyard Rig'),
    );
    final sequenceId = await sequencesDao.createSequence(
      SequencesCompanion.insert(name: 'M31 LRGB'),
    );

    final sessionId = await sessionService.startSession(
      name: 'M31 LRGB',
      profileId: profileId,
      sequenceId: sequenceId,
    );

    final row = await sessionsDao.getSessionById(sessionId);
    expect(row!.profileId, profileId);
    expect(
      row.sequenceId,
      sequenceId,
      reason: 'the run knew its sequence; the row must too',
    );
  });

  test('the handoff context names the profile and the sequence', () async {
    final profileId = await profilesDao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Backyard Rig'),
    );
    final sequenceId = await sequencesDao.createSequence(
      SequencesCompanion.insert(name: 'M31 LRGB'),
    );

    final sessionId = await sessionService.startSession(
      name: 'M31 LRGB',
      profileId: profileId,
      sequenceId: sequenceId,
    );
    expect(sessionId, isPositive);
    // Then the process died and the next open swept the row — the state the
    // Continue Session dialog exists for. Closed by the boot sweep's own rule,
    // because `active` now means a run something is driving.
    await sessionsDao.closeOrphanedSessions(
      cause: kInterruptedBySessionShutdownCause,
    );

    final quickStart = QuickStartService(
      sessionsDao: sessionsDao,
      profilesDao: profilesDao,
      targetsDao: TargetsDao(db),
      sequencesDao: sequencesDao,
      checkpointsDao: checkpointsDao,
    );
    final context = await quickStart.getQuickStartContext();

    expect(context, isNotNull);
    expect(
      context!.profileName,
      'Backyard Rig',
      reason: 'the dialog rendered "Unknown Profile" from a null here',
    );
    expect(
      context.sequenceName,
      'M31 LRGB',
      reason: 'the dialog rendered "No Sequence" from a null here',
    );
  });

  test('the executor binds the run to its profile and sequence', () async {
    final profileId = await profilesDao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Backyard Rig'),
    );
    final sequenceRowId = await sequencesDao.createSequence(
      SequencesCompanion.insert(name: 'M31 LRGB'),
    );
    final sequence = Sequence.create(
      name: 'M31 LRGB',
      rootNodeId: 'target1',
      nodes: {
        'target1': TargetHeaderNode(
          id: 'target1',
          name: 'M31',
          targetName: 'M31',
          raHours: 0.712,
          decDegrees: 41.269,
        ),
      },
    ).copyWith(databaseId: sequenceRowId);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        activeEquipmentProfileProvider.overrideWithValue(
          EquipmentProfileModel(id: profileId, name: 'Backyard Rig'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(sequenceExecutorProvider)
        .startSessionRowForTest(sequence);

    final active = await sessionsDao.getActiveSessions();
    expect(active, hasLength(1));
    expect(active.single.profileId, profileId);
    expect(active.single.sequenceId, sequenceRowId);
  });
}
