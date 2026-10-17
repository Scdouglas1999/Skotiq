import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A daemon stopped mid-run — a cloud call at 2am, the updater, a power blip —
/// left its `imaging_sessions` row `active` with nothing to close it, and
/// `SessionsDao.startSession` refuses to open a second row while one stands.
/// Both start paths treat that refusal as "this run has no session row", so
/// EVERY frame of EVERY later night registered with `session_id` NULL, the
/// session-end hooks that key on the session id never fired, and
/// `GET /api/sessions/active` kept serving the dead run's counters.
///
/// Reproduced against the release bundle before this sweep existed: night two's
/// twelve frames all landed NULL and session 1 still read `active`.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_orphan_session_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<int> addActiveSession(
    SkotiqDatabase db, {
    required DateTime startTime,
    String name = 'orphan night',
    String? notes,
  }) {
    return db.sessionsDao.createSession(
      ImagingSessionsCompanion.insert(
        startTime: startTime,
        name: Value(name),
        notes: Value(notes),
        status: const Value('active'),
      ),
    );
  }

  Future<void> addFrame(
    SkotiqDatabase db,
    int sessionId,
    DateTime capturedAt,
    int n,
  ) {
    return db.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/frame_${sessionId}_$n.fits',
        fileName: 'frame_${sessionId}_$n.fits',
        exposureDuration: 30.0,
        capturedAt: capturedAt,
        sessionId: Value(sessionId),
      ),
    );
  }

  Future<ImagingSession> readSession(SkotiqDatabase db, int id) {
    return (db.select(
      db.imagingSessions,
    )..where((s) => s.id.equals(id))).getSingle();
  }

  test(
    'the boot sweep closes a session left active, back-dated to its last frame',
    () async {
      final start = DateTime.now().subtract(const Duration(hours: 6));
      final lastFrame = start.add(const Duration(hours: 2));

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final sessionId = await addActiveSession(first, startTime: start);
      await addFrame(first, sessionId, start.add(const Duration(hours: 1)), 0);
      await addFrame(first, sessionId, lastFrame, 1);
      expect((await readSession(first, sessionId)).status, 'active');
      await first.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      final after = await readSession(second, sessionId);

      expect(after.status, kInterruptedSessionStatus);
      // Back-dated to the last frame, NOT to the recovery clock: a night
      // abandoned on Wednesday and found on Friday used to report a 60-hour
      // duration on its History card and in every efficiency figure built on
      // it. Whole seconds, because that is the column's resolution.
      expect(
        after.endTime!.millisecondsSinceEpoch ~/ 1000,
        lastFrame.millisecondsSinceEpoch ~/ 1000,
      );
      expect(after.notes, contains('interrupted rather than completed'));
    },
  );

  test('a session that captured nothing collapses to its start time', () async {
    final start = DateTime.now().subtract(const Duration(hours: 3));

    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final sessionId = await addActiveSession(first, startTime: start);
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await readSession(second, sessionId);

    expect(after.status, kInterruptedSessionStatus);
    // Zero duration rather than an invented end: the session produced nothing,
    // and stamping "now" would report three hours of imaging that never
    // happened.
    expect(
      after.endTime!.millisecondsSinceEpoch ~/ 1000,
      start.millisecondsSinceEpoch ~/ 1000,
    );
  });

  test('a frame dated after the recovery cannot stretch the night', () async {
    final start = DateTime.now().subtract(const Duration(hours: 2));

    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final sessionId = await addActiveSession(first, startTime: start);
    // A rig whose clock jumped forward mid-night, or a frame carrying a header
    // time from the future. Clamped, so the row cannot report a night that is
    // still growing.
    await addFrame(
      first,
      sessionId,
      DateTime.now().add(const Duration(days: 2)),
      0,
    );
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await readSession(second, sessionId);

    expect(after.endTime!.isAfter(DateTime.now()), isFalse);
    expect(after.endTime!.isBefore(start), isFalse);
  });

  test('the sweep appends to notes rather than replacing them', () async {
    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final sessionId = await addActiveSession(
      first,
      startTime: DateTime.now().subtract(const Duration(hours: 1)),
      notes: 'Guiding was rough after midnight.',
    );
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await readSession(second, sessionId);

    // The interrupted-integration report writes into this same column, and an
    // operator's own note is the last thing a recovery may throw away.
    expect(after.notes, contains('Guiding was rough after midnight.'));
    expect(after.notes, contains('interrupted rather than completed'));
  });

  test('a completed session is left exactly as it was', () async {
    final start = DateTime.now().subtract(const Duration(hours: 4));
    final end = start.add(const Duration(hours: 3));

    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final sessionId = await first.sessionsDao.createSession(
      ImagingSessionsCompanion.insert(
        startTime: start,
        endTime: Value(end),
        status: const Value('completed'),
      ),
    );
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await readSession(second, sessionId);

    expect(after.status, 'completed');
    expect(
      after.endTime!.millisecondsSinceEpoch ~/ 1000,
      end.millisecondsSinceEpoch ~/ 1000,
    );
    expect(after.notes, isNull);
  });

  test(
    'after the sweep a new session opens and the next night attaches',
    () async {
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final orphan = await addActiveSession(
        first,
        startTime: DateTime.now().subtract(const Duration(hours: 5)),
      );
      await addFrame(
        first,
        orphan,
        DateTime.now().subtract(const Duration(hours: 4)),
        0,
      );
      await first.close();

      // The whole point of the sweep: the NEXT night's start must succeed.
      // Before it, `startSession` threw ActiveImagingSessionException here and
      // every caller carried on with no session id, so every frame of this
      // night would have been written with `session_id` NULL.
      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      final tonight = await second.sessionsDao.startSession(name: 'night two');
      expect(tonight, isNot(orphan));
      await addFrame(second, tonight, DateTime.now(), 1);

      final stranded = await second
          .customSelect(
            'SELECT count(*) AS n FROM captured_images WHERE session_id IS NULL',
          )
          .getSingle();
      expect(stranded.read<int>('n'), 0);
      expect((await readSession(second, tonight)).status, 'active');
    },
  );

  test(
    'frames the old bug already stranded are left unattached, and stay listed '
    'as sessionless',
    () async {
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final orphan = await addActiveSession(
        first,
        startTime: DateTime.now().subtract(const Duration(hours: 30)),
      );
      await addFrame(
        first,
        orphan,
        DateTime.now().subtract(const Duration(hours: 29)),
        0,
      );
      // What the old code wrote for every night after the row got stuck: a
      // frame with no session at all, captured well inside the stuck row's
      // window.
      await first.imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/tmp/legacy_night_two.fits',
          fileName: 'legacy_night_two.fits',
          exposureDuration: 30.0,
          capturedAt: DateTime.now().subtract(const Duration(hours: 5)),
        ),
      );
      await first.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);

      // The sweep does not adopt it. Every later night landed inside the stuck
      // row's window, so filing this frame there would put three nights under
      // one card and let every per-night figure inherit the guess.
      final stranded = await second
          .customSelect(
            'SELECT count(*) AS n FROM captured_images WHERE session_id IS NULL',
          )
          .getSingle();
      expect(stranded.read<int>('n'), 1);
      expect(
        (await readSession(second, orphan)).status,
        kInterruptedSessionStatus,
      );
      expect(
        (await second.imagesDao.getImagesForSession(orphan)).length,
        1,
        reason:
            'the swept night keeps only the frames that were really its own',
      );

      // Not lost, though: this is the list Analytics' Session tab shows as
      // sessionless captures, and the row keeps its path and its timestamp.
      final listed = await second.imagesDao.watchStandaloneImages().first;
      expect(listed.map((i) => i.fileName), ['legacy_night_two.fits']);
    },
  );

  test('the interrupted night is what Continue Session offers, and resuming it '
      're-opens the row', () async {
    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final orphan = await addActiveSession(
      first,
      startTime: DateTime.now().subtract(const Duration(hours: 5)),
    );
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    // The handoff dialog read `active` because nothing ever closed an
    // abandoned row; the sweep moved that set to `interrupted`, and the
    // dialog has to move with it or the sweep would simply delete the
    // recovery feature.
    final offered = await second.sessionsDao.getInterruptedSessions();
    expect(offered.map((s) => s.id), [orphan]);
    expect(await second.sessionsDao.hasIncompleteSessions(), isTrue);
    // A live session is not something to hand off FROM.
    expect(await second.sessionsDao.getActiveSessions(), isEmpty);

    await second.sessionsDao.reopenSession(orphan);
    final resumed = await readSession(second, orphan);
    expect(resumed.status, 'active');
    expect(resumed.endTime, isNull);
    // The gap really happened; the record keeps both lines in order.
    expect(resumed.notes, contains('interrupted rather than completed'));
    expect(resumed.notes, contains('Resumed at'));
  });

  test(
    'closeOrphanedSessions closes every stranded row and names them',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final a = await addActiveSession(
        db,
        startTime: DateTime.now().subtract(const Duration(hours: 9)),
        name: 'first',
      );
      final b = await addActiveSession(
        db,
        startTime: DateTime.now().subtract(const Duration(hours: 5)),
        name: 'second',
      );

      final closed = await db.sessionsDao.closeOrphanedSessions(
        cause: kInterruptedByNewSequenceCause,
      );

      expect(closed, [a, b]);
      expect((await readSession(db, a)).status, kInterruptedSessionStatus);
      expect((await readSession(db, b)).status, kInterruptedSessionStatus);
      expect(
        (await readSession(db, b)).notes,
        contains('a new sequence started'),
      );
      // Idempotent: nothing is left to close, and a second pass writes no
      // second note onto a row it already closed.
      expect(
        await db.sessionsDao.closeOrphanedSessions(
          cause: kInterruptedByNewSequenceCause,
        ),
        isEmpty,
      );
    },
  );
}
