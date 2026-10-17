// `imaging_sessions.equipment_snapshot` is what the Continue Session dialog's
// "Load Previous Setup" re-applies: cooler setpoint, gain/offset, binning,
// filter slot, focuser position.
//
// It had a schema column, a reader (QuickStartService) and a restore path
// (QuickStartChecker._applyEquipmentSnapshot) — and no writer anywhere in the
// app. `captureEquipmentSnapshot` / `saveEquipmentSnapshot` existed with zero
// production callers, so every session row carried NULL, the dialog described
// the session it was offering as having no equipment, and the primary action
// restored nothing while reporting "Loaded previous setup ... from frame 1".
//
// Opening a session is the one moment every surface (sequencer run, ad-hoc
// capture) passes through, so that is where the snapshot is stamped.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase db;
  late SessionsDao sessionsDao;
  ProviderContainer? container;

  ProviderContainer buildContainer() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    sessionsDao = SessionsDao(db);
  });

  tearDown(() async {
    container?.dispose();
    await db.close();
  });

  test('starting a session records the equipment it is running with', () async {
    final c = buildContainer();
    c.read(exposureSettingsProvider.notifier).state = const ExposureSettings(
      exposureTime: 180.0,
      gain: 250,
      offset: 33,
      binningX: 2,
      binningY: 2,
    );

    await c.read(sessionStateProvider.notifier).startSession(targetName: 'M31');

    final sessionId = c.read(sessionStateProvider).dbSessionId;
    expect(sessionId, isNotNull);
    final row = await sessionsDao.getSessionById(sessionId!);
    expect(
      row!.equipmentSnapshot,
      isNotNull,
      reason: 'nothing in the app ever wrote this column',
    );

    final snapshot = EquipmentSnapshot.fromJsonString(row.equipmentSnapshot!);
    expect(snapshot.cameraGain, 250);
    expect(snapshot.cameraOffset, 33);
    expect(snapshot.cameraBinX, 2);
    expect(snapshot.cameraBinY, 2);
    expect(snapshot.exposureTime, 180.0);
  });

  test('the handoff context can offer that equipment back', () async {
    final c = buildContainer();
    c.read(exposureSettingsProvider.notifier).state = const ExposureSettings(
      exposureTime: 60.0,
      gain: 120,
      offset: 12,
    );

    await c.read(sessionStateProvider.notifier).startSession(targetName: 'M31');

    // Then the process died and the next open swept the row, which is the
    // state the Continue Session dialog exists for. Closed by the boot sweep's
    // own rule rather than by hand: `active` now means a run this process is
    // driving, and a live run is not a session to hand off from.
    await sessionsDao.closeOrphanedSessions(
      cause: kInterruptedBySessionShutdownCause,
    );

    final quickStart = QuickStartService(
      sessionsDao: sessionsDao,
      profilesDao: EquipmentProfilesDao(db),
      targetsDao: TargetsDao(db),
      sequencesDao: SequencesDao(db),
      checkpointsDao: SequenceCheckpointsDao(db),
    );
    final context = await quickStart.getQuickStartContext();

    expect(context, isNotNull);
    expect(
      context!.hasEquipmentSnapshot,
      isTrue,
      reason:
          'this is the flag the dialog gates "Load Previous Setup" on; with a '
          'NULL column the button had nothing to restore',
    );
    expect(context.equipmentSnapshot!.cameraGain, 120);
  });
}
