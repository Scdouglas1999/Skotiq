import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Insert the row a process killed mid-session leaves behind, as the boot sweep
/// leaves it: `interrupted`, with an end time.
///
/// That residue is what `findIncompleteSessionsForRecovery` exists to offer
/// back to the operator. It reads `interrupted` rather than `active` because
/// the sweep in `beforeOpen` closes an abandoned row at every open — it has to,
/// or the row refuses every later `startSession` and detaches every later
/// night's frames — so `active` now only ever means a session a live executor
/// is driving.
///
/// Constructed directly, because calling `startSession` twice reproduces
/// something that never happens.
Future<int> _insertInterruptedSession(
  SessionsDao dao, {
  required String name,
  int? targetId,
}) {
  return dao.createSession(
    ImagingSessionsCompanion.insert(
      startTime: DateTime.now(),
      name: Value(name),
      targetId: Value(targetId),
      status: const Value(kInterruptedSessionStatus),
    ),
  );
}

/// Insert the row as a DEAD PROCESS left it — still `active`, never swept.
///
/// The state the sweep and the start-path close both exist to resolve: a
/// database opened before either existed, or a run in this process that failed
/// after opening its session and could not finalize it.
Future<int> _insertStaleActiveSession(
  SessionsDao dao, {
  required String name,
  int? targetId,
}) {
  return dao.createSession(
    ImagingSessionsCompanion.insert(
      startTime: DateTime.now(),
      name: Value(name),
      targetId: Value(targetId),
      status: const Value('active'),
    ),
  );
}

void main() {
  late SkotiqDatabase database;
  late SessionsDao sessionsDao;
  late SequenceCheckpointsDao checkpointsDao;
  late TargetsDao targetsDao;
  late EquipmentProfilesDao profilesDao;
  late SessionService sessionService;
  late LoggingService logger;

  setUp(() async {
    // Create in-memory database for testing
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    sessionsDao = SessionsDao(database);
    checkpointsDao = SequenceCheckpointsDao(database);
    targetsDao = TargetsDao(database);
    profilesDao = EquipmentProfilesDao(database);

    // Seed FK dependencies used by session tests
    await targetsDao.createTarget(
      TargetsCompanion.insert(name: 'Target 1', ra: 5.0, dec: 25.0),
    );
    await targetsDao.createTarget(
      TargetsCompanion.insert(name: 'Target 2', ra: 10.0, dec: -15.0),
    );
    await targetsDao.createTarget(
      TargetsCompanion.insert(name: 'Target 3', ra: 15.0, dec: 35.0),
    );

    await profilesDao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Profile 1'),
    );
    await profilesDao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Profile 2'),
    );

    logger = LoggingService();
    sessionService = SessionService(
      records: ImagingRecordsRepository.local(
        sessionsDao: sessionsDao,
        imagesDao: ImagesDao(database),
      ),
      checkpointsDao: checkpointsDao,
      logger: logger,
    );
  });

  tearDown(() async {
    // A test may deliberately close the DB to force a write failure; a second
    // close would throw, so guard it.
    try {
      await database.close();
    } catch (_) {
      // Already closed by the test.
    }
  });

  group('SessionService - Lifecycle Management', () {
    test('startSession creates a new session with active status', () async {
      final sessionId = await sessionService.startSession(
        name: 'Test Session',
        targetId: 1,
        profileId: 2,
      );

      expect(sessionId, isPositive);
      expect(sessionService.hasActiveSession, isTrue);
      expect(sessionService.currentSessionId, equals(sessionId));

      // Verify session in database
      final session = await sessionsDao.getSessionById(sessionId);
      expect(session, isNotNull);
      expect(session!.name, equals('Test Session'));
      expect(session.targetId, equals(1));
      expect(session.profileId, equals(2));
      expect(session.status, equals('active'));
      expect(session.endTime, isNull);
    });

    test('startSession throws when session already active', () async {
      await sessionService.startSession(name: 'First Session');

      expect(
        () => sessionService.startSession(name: 'Second Session'),
        throwsException,
      );
    });

    // The half of the fix that does not wait for a relaunch. A run that failed
    // after opening its row, or a database opened before the boot sweep
    // existed, leaves an `active` row with nothing driving it — and
    // `SessionsDao.startSession` refuses while one stands. Both start paths
    // (the executor's `_startSessionRow`, the headless `load -> start`
    // pre-flight) treat that refusal as "this run has no session row" and
    // capture the whole night with `session_id` NULL, so the session-end hooks
    // never fire. Tonight's session opens instead, and last night's is closed
    // by the same rule the boot sweep uses.
    test(
      'startSession closes a row nothing is driving and opens its own',
      () async {
        final stranded = await _insertStaleActiveSession(
          sessionsDao,
          name: 'Night the daemon was killed during',
        );

        final tonight = await sessionService.startSession(name: 'Tonight');

        expect(tonight, isNot(stranded));
        expect(sessionService.currentSessionId, equals(tonight));
        final opened = await sessionsDao.getSessionById(tonight);
        expect(opened!.status, equals('active'));

        final closed = await sessionsDao.getSessionById(stranded);
        expect(closed!.status, equals(kInterruptedSessionStatus));
        expect(closed.endTime, isNotNull);
        expect(closed.notes, contains('a new sequence started'));
        // One live row, so `GET /api/sessions/active` cannot answer with the
        // dead run's frozen counters while this one captures.
        expect(await sessionsDao.getActiveSessions(), hasLength(1));
      },
    );

    test('endSession finalizes session with completed status', () async {
      final sessionId = await sessionService.startSession(name: 'Test Session');

      // Update some stats
      final stats = SessionStats(
        completedExposures: 10,
        failedExposures: 2,
        totalIntegrationSecs: 300.0,
        avgHfr: 2.5,
        avgGuidingRms: 0.8,
        autofocusCount: 3,
        lastUpdated: DateTime.now(),
      );
      await sessionService.updateSessionProgress(stats);

      await sessionService.endSession(status: 'completed');

      expect(sessionService.hasActiveSession, isFalse);
      expect(sessionService.currentSessionId, isNull);

      // Verify session in database
      final session = await sessionsDao.getSessionById(sessionId);
      expect(session, isNotNull);
      expect(session!.status, equals('completed'));
      expect(session.endTime, isNotNull);
      expect(session.successfulExposures, equals(10));
      expect(session.failedExposures, equals(2));
      expect(session.totalIntegrationSecs, equals(300.0));
      expect(session.avgHfr, equals(2.5));
      expect(session.avgGuidingRms, equals(0.8));
      expect(session.autofocusCount, equals(3));
    });

    test('endSession retains the active session on a durable-write failure '
        '(retryable — not cleared in a finally)', () async {
      final sessionId = await sessionService.startSession(name: 'Test Session');
      await sessionService.updateSessionProgress(
        SessionStats(completedExposures: 3, lastUpdated: DateTime.now()),
      );
      expect(sessionService.hasActiveSession, isTrue);

      // Force the durable finalize to fail by closing the DB out from under
      // it. Clearing identity unconditionally would leave the row stuck
      // 'active' forever, with every retry a no-op.
      await database.close();

      await expectLater(
        sessionService.endSession(status: 'completed'),
        throwsA(anything),
      );

      // Identity retained so a caller (SequenceExecutor's cleanupFailed retry,
      // or a later endSession) can actually finalize the row.
      expect(sessionService.hasActiveSession, isTrue);
      expect(sessionService.currentSessionId, equals(sessionId));
    });

    test('abortSession marks session as aborted', () async {
      final sessionId = await sessionService.startSession(name: 'Test Session');
      await sessionService.abortSession();

      final session = await sessionsDao.getSessionById(sessionId);
      expect(session!.status, equals('aborted'));
    });

    test('errorSession marks session as error with message', () async {
      final sessionId = await sessionService.startSession(name: 'Test Session');
      await sessionService.errorSession('Camera disconnected');

      final session = await sessionsDao.getSessionById(sessionId);
      expect(session!.status, equals('error'));
      expect(session.notes, contains('Camera disconnected'));
    });
  });

  group('SessionService - Checkpointing', () {
    test('checkpoint saves current statistics', () async {
      final sessionId = await sessionService.startSession(name: 'Test Session');

      final stats = SessionStats(
        completedExposures: 5,
        failedExposures: 1,
        totalIntegrationSecs: 150.0,
        avgHfr: 2.3,
        lastUpdated: DateTime.now(),
      );
      await sessionService.updateSessionProgress(stats);

      // Manually trigger checkpoint
      await sessionService.checkpoint();

      // Verify stats are saved
      final session = await sessionsDao.getSessionById(sessionId);
      expect(session!.successfulExposures, equals(5));
      expect(session.failedExposures, equals(1));
      expect(session.totalIntegrationSecs, equals(150.0));
      expect(session.avgHfr, equals(2.3));
    });

    // The row is what `GET /api/sessions/active` serves, and the same endpoint
    // counts accepted/rejected live off `captured_images`. Holding the
    // exposure counters back until a five-image threshold published a session
    // that claimed nothing had been captured beside a grading pair that said
    // four frames had — so every frame writes.
    test('every progress update advances the durable counters', () async {
      // A time interval far longer than the test can run, so nothing here
      // passes because a timer happened to fire.
      sessionService.updateConfig(
        const SessionCheckpointConfig(
          checkpointTimeInterval: Duration(hours: 1),
          enabled: true,
        ),
      );

      final sessionId = await sessionService.startSession(name: 'Test Session');

      for (var frame = 1; frame <= 3; frame++) {
        await sessionService.updateSessionProgress(
          SessionStats(
            completedExposures: frame,
            failedExposures: 0,
            totalIntegrationSecs: 30.0 * frame,
            lastUpdated: DateTime.now(),
          ),
        );

        final session = await sessionsDao.getSessionById(sessionId);
        expect(session!.successfulExposures, equals(frame));
        expect(session.totalExposures, equals(frame));
        expect(session.totalIntegrationSecs, equals(30.0 * frame));
      }
    });

    test('a failed exposure is persisted the moment it is reported', () async {
      final sessionId = await sessionService.startSession(name: 'Test Session');

      await sessionService.updateSessionProgress(
        SessionStats(
          completedExposures: 1,
          failedExposures: 1,
          totalIntegrationSecs: 30.0,
          lastUpdated: DateTime.now(),
        ),
      );

      final session = await sessionsDao.getSessionById(sessionId);
      expect(session!.failedExposures, equals(1));
      expect(session.successfulExposures, equals(1));
      expect(session.totalExposures, equals(2));
    });

    test(
      'disabled checkpointing leaves the row untouched until the end',
      () async {
        sessionService.updateConfig(
          const SessionCheckpointConfig(enabled: false),
        );

        final sessionId = await sessionService.startSession(
          name: 'Test Session',
        );
        await sessionService.updateSessionProgress(
          SessionStats(
            completedExposures: 2,
            failedExposures: 0,
            totalIntegrationSecs: 60.0,
            lastUpdated: DateTime.now(),
          ),
        );

        var session = await sessionsDao.getSessionById(sessionId);
        expect(session!.successfulExposures, equals(0));

        await sessionService.endSession();

        session = await sessionsDao.getSessionById(sessionId);
        expect(session!.successfulExposures, equals(2));
        expect(session.totalIntegrationSecs, equals(60.0));
      },
    );

    test('checkpoint configuration can be updated', () async {
      expect(
        sessionService.config.checkpointTimeInterval,
        equals(const Duration(minutes: 5)),
      );

      const newConfig = SessionCheckpointConfig(
        checkpointTimeInterval: Duration(minutes: 10),
        enabled: true,
      );
      sessionService.updateConfig(newConfig);

      expect(
        sessionService.config.checkpointTimeInterval,
        equals(const Duration(minutes: 10)),
      );
    });
  });

  group('SessionService - Recovery', () {
    test('recovery scan propagates database failures', () async {
      await database.close();

      await expectLater(
        sessionService.findIncompleteSessionsForRecovery(),
        throwsA(anything),
      );
    });

    test(
      'findIncompleteSessionsForRecovery finds the interrupted night',
      () async {
        final completedId = await sessionsDao.startSession(
          name: 'Completed Session',
          targetId: 2,
        );
        await sessionsDao.updateSessionStats(
          completedId,
          successfulExposures: 10,
        );
        await sessionsDao.endSession(completedId, status: 'completed');

        // The night a process abandoned, as the boot sweep leaves it. A row that
        // still read `active` would be a live run, and a live run is not
        // something to offer a recovery from.
        final interruptedId = await _insertInterruptedSession(
          sessionsDao,
          name: 'Interrupted Session',
          targetId: 1,
        );

        final incompleteSessions = await sessionService
            .findIncompleteSessionsForRecovery();

        expect(incompleteSessions.length, equals(1));
        expect(incompleteSessions[0].sessionId, equals(interruptedId));
        expect(
          incompleteSessions[0].sessionName,
          equals('Interrupted Session'),
        );
      },
    );

    test('recoverSession restores session state', () async {
      final sessionId = await _insertInterruptedSession(
        sessionsDao,
        name: 'Recoverable Session',
      );
      await sessionsDao.updateSessionStats(
        sessionId,
        successfulExposures: 15,
        failedExposures: 3,
        totalIntegrationSecs: 450.0,
        avgHfr: 2.8,
        avgGuidingRms: 0.9,
        autofocusCount: 2,
      );

      // Simulate crash/restart - create new service instance
      final newService = SessionService(
        records: ImagingRecordsRepository.local(
          sessionsDao: sessionsDao,
          imagesDao: ImagesDao(database),
        ),
        checkpointsDao: checkpointsDao,
        logger: logger,
      );

      expect(newService.hasActiveSession, isFalse);

      // Recover the session
      await newService.recoverSession(sessionId);

      expect(newService.hasActiveSession, isTrue);
      expect(newService.currentSessionId, equals(sessionId));
      // The row it is about to take frames for must stop saying it ended.
      final resumed = await sessionsDao.getSessionById(sessionId);
      expect(resumed!.status, equals('active'));
      expect(resumed.endTime, isNull);

      final stats = newService.currentStats;
      expect(stats, isNotNull);
      expect(stats!.completedExposures, equals(15));
      expect(stats.failedExposures, equals(3));
      expect(stats.totalIntegrationSecs, equals(450.0));
      expect(stats.avgHfr, equals(2.8));
      expect(stats.avgGuidingRms, equals(0.9));
      expect(stats.autofocusCount, equals(2));
    });

    test('recoverSession throws when session not found', () async {
      expect(() => sessionService.recoverSession(999), throwsException);
    });

    test('recoverSession throws when session is not active', () async {
      final sessionId = await sessionsDao.startSession(name: 'Test');
      await sessionsDao.endSession(sessionId, status: 'completed');

      expect(() => sessionService.recoverSession(sessionId), throwsException);
    });

    test('recoverSession throws when another session is active', () async {
      await sessionService.startSession(name: 'Active Session');

      // Residue from an earlier process that died mid-session.
      final oldSessionId = await _insertStaleActiveSession(
        sessionsDao,
        name: 'Old Session',
      );

      expect(
        () => sessionService.recoverSession(oldSessionId),
        throwsException,
      );
    });

    test(
      'markSessionAborted marks session as aborted without active session',
      () async {
        final sessionId = await sessionsDao.startSession(name: 'Test Session');

        // Mark as aborted without making it active
        await sessionService.markSessionAborted(sessionId);

        final session = await sessionsDao.getSessionById(sessionId);
        expect(session!.status, equals('aborted'));
        expect(session.endTime, isNotNull);
      },
    );

    // Observed defect: a session abandoned on Wednesday and recovered on
    // Friday was stamped end_time = the recovery clock, so its History card,
    // its wall-clock duration and every efficiency figure derived from it
    // reported a 46-hour night. One crash permanently corrupted the duration.
    test(
      'markSessionAborted back-dates end_time to the last captured frame',
      () async {
        final startedAt = DateTime.now().subtract(const Duration(days: 3));
        final lastFrameAt = startedAt.add(const Duration(hours: 4));
        final sessionId = await sessionsDao.createSession(
          ImagingSessionsCompanion.insert(
            name: const Value('Night C - M31'),
            startTime: startedAt,
            status: const Value('active'),
          ),
        );
        final imagesDao = ImagesDao(database);
        for (var i = 0; i < 3; i++) {
          await imagesDao.createImage(
            CapturedImagesCompanion.insert(
              filePath: '/lights/c$i.fits',
              fileName: 'c$i.fits',
              sessionId: Value(sessionId),
              exposureDuration: 300.0,
              frameType: const Value('light'),
              capturedAt: lastFrameAt.subtract(Duration(minutes: 10 * (2 - i))),
            ),
          );
        }

        await sessionService.markSessionAborted(sessionId);

        final session = await sessionsDao.getSessionById(sessionId);
        expect(session!.status, equals('aborted'));
        expect(
          session.endTime!.difference(lastFrameAt).inSeconds.abs(),
          lessThanOrEqualTo(1),
          reason: 'end_time must be the last frame, not the recovery clock',
        );
        // The night was four hours long, not three days.
        final durationHours =
            session.endTime!.difference(session.startTime).inMinutes / 60.0;
        expect(durationHours, closeTo(4.0, 0.02));
      },
    );

    test(
      'markSessionAborted collapses a frameless session to zero duration',
      () async {
        final startedAt = DateTime.now().subtract(const Duration(days: 2));
        final sessionId = await sessionsDao.createSession(
          ImagingSessionsCompanion.insert(
            name: const Value('Nothing captured'),
            startTime: startedAt,
            status: const Value('active'),
          ),
        );

        await sessionService.markSessionAborted(sessionId);

        final session = await sessionsDao.getSessionById(sessionId);
        expect(
          session!.endTime!.difference(session.startTime).inSeconds,
          lessThanOrEqualTo(1),
          reason: 'a session that produced nothing has no measurable duration',
        );
      },
    );
  });

  group('SessionService - Statistics Tracking', () {
    test('updateSessionProgress updates current stats', () async {
      await sessionService.startSession(name: 'Test Session');

      final stats = SessionStats(
        completedExposures: 20,
        failedExposures: 4,
        totalIntegrationSecs: 600.0,
        avgHfr: 3.1,
        avgGuidingRms: 1.2,
        autofocusCount: 5,
        lastImageId: 42,
        lastUpdated: DateTime.now(),
      );

      await sessionService.updateSessionProgress(stats);

      final currentStats = sessionService.currentStats;
      expect(currentStats, isNotNull);
      expect(currentStats!.completedExposures, equals(20));
      expect(currentStats.failedExposures, equals(4));
      expect(currentStats.totalIntegrationSecs, equals(600.0));
      expect(currentStats.avgHfr, equals(3.1));
      expect(currentStats.avgGuidingRms, equals(1.2));
      expect(currentStats.autofocusCount, equals(5));
      expect(currentStats.lastImageId, equals(42));
    });

    test('SessionStats calculates success rate correctly', () {
      final stats = SessionStats(
        completedExposures: 18,
        failedExposures: 2,
        totalIntegrationSecs: 0,
        lastUpdated: DateTime.now(),
      );

      expect(stats.successRate, equals(0.9)); // 18/20 = 0.9
    });

    test('SessionStats success rate handles zero exposures', () {
      final stats = SessionStats(
        completedExposures: 0,
        failedExposures: 0,
        totalIntegrationSecs: 0,
        lastUpdated: DateTime.now(),
      );

      expect(
        stats.successRate,
        equals(1.0),
      ); // Default to 1.0 when no exposures
    });
  });

  group('SessionService - Status Stream', () {
    test('status stream emits events', () async {
      final statusEvents = <String>[];
      final subscription = sessionService.statusStream.listen((status) {
        statusEvents.add(status);
      });

      await sessionService.startSession(name: 'Test Session');
      await sessionService.endSession();

      await Future.delayed(const Duration(milliseconds: 100));

      expect(statusEvents.length, greaterThanOrEqualTo(2));
      expect(statusEvents.any((s) => s.contains('started')), isTrue);
      expect(statusEvents.any((s) => s.contains('ended')), isTrue);

      await subscription.cancel();
    });
  });

  group('SessionService - Edge Cases', () {
    test('endSession with no active session does nothing', () async {
      expect(sessionService.hasActiveSession, isFalse);

      await sessionService.endSession();

      expect(sessionService.hasActiveSession, isFalse);
    });

    test('checkpoint with no active session does nothing', () async {
      expect(sessionService.hasActiveSession, isFalse);

      await sessionService.checkpoint();

      expect(sessionService.hasActiveSession, isFalse);
    });

    test('updateSessionProgress with no active session does nothing', () async {
      expect(sessionService.hasActiveSession, isFalse);

      final stats = SessionStats(
        completedExposures: 5,
        failedExposures: 0,
        totalIntegrationSecs: 150.0,
        lastUpdated: DateTime.now(),
      );
      await sessionService.updateSessionProgress(stats);

      expect(sessionService.currentStats, isNull);
    });

    test('service can be disposed safely', () {
      expect(() => sessionService.dispose(), returnsNormally);
    });

    test('service can be disposed with active session', () async {
      await sessionService.startSession(name: 'Test Session');
      expect(sessionService.hasActiveSession, isTrue);

      expect(() => sessionService.dispose(), returnsNormally);
    });
  });

  group('SessionService - Multiple Sessions', () {
    test('can start new session after ending previous one', () async {
      final sessionId1 = await sessionService.startSession(name: 'Session 1');
      await sessionService.endSession();

      final sessionId2 = await sessionService.startSession(name: 'Session 2');
      expect(sessionId2, isNot(equals(sessionId1)));
      expect(sessionService.currentSessionId, equals(sessionId2));
    });

    test('multiple incomplete sessions can be recovered', () async {
      // Three nights three processes each died in, as the boot sweep left
      // them: three opens, three closes, nothing overwritten.
      await _insertInterruptedSession(
        sessionsDao,
        name: 'Session 1',
        targetId: 1,
      );
      await _insertInterruptedSession(
        sessionsDao,
        name: 'Session 2',
        targetId: 2,
      );
      await _insertInterruptedSession(
        sessionsDao,
        name: 'Session 3',
        targetId: 3,
      );

      final incompleteSessions = await sessionService
          .findIncompleteSessionsForRecovery();

      expect(incompleteSessions.length, equals(3));
      final names = incompleteSessions
          .map((session) => session.sessionName)
          .whereType<String>()
          .toSet();
      expect(
        names,
        containsAll(<String>['Session 1', 'Session 2', 'Session 3']),
      );
    });
  });

  group('SessionRecoveryInfo', () {
    test('calculates duration correctly', () {
      final startTime = DateTime.now().subtract(
        const Duration(hours: 2, minutes: 30),
      );
      final recoveryInfo = SessionRecoveryInfo(
        sessionId: 1,
        startTime: startTime,
        stats: SessionStats(
          completedExposures: 10,
          failedExposures: 0,
          totalIntegrationSecs: 300.0,
          lastUpdated: DateTime.now(),
        ),
      );

      expect(recoveryInfo.duration.inHours, equals(2));
      expect(recoveryInfo.duration.inMinutes, greaterThanOrEqualTo(150));
    });
  });
}
