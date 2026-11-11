import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'recovered_database.dart';

/// `imaging_sessions.total_exposures` / `total_integration_secs` are
/// denormalised counters that SessionService accumulates in memory and flushes
/// when the session ends. A session that never ends cleanly — a crash, a power
/// cut — keeps zeros forever, even though every frame it captured is safely in
/// `captured_images`. Analytics sums those counters, so the loss shows up as
/// under-reported total integration time, which is the headline number of the
/// entire hobby.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_session_stats_');
    dbFile = File('${tempDir.path}/skotiq.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<int> addSession(
    SkotiqDatabase db, {
    int exposures = 0,
    int successful = 0,
    double integration = 0,
  }) {
    return db.sessionsDao.createSession(
      ImagingSessionsCompanion.insert(
        startTime: DateTime.now(),
        totalExposures: Value(exposures),
        successfulExposures: Value(successful),
        totalIntegrationSecs: Value(integration),
      ),
    );
  }

  Future<void> addFrame(
    SkotiqDatabase db,
    int sessionId,
    double seconds,
    int n, {
    bool accepted = true,
  }) async {
    await db.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/frame_${sessionId}_$n.fits',
        fileName: 'frame_${sessionId}_$n.fits',
        exposureDuration: seconds,
        capturedAt: DateTime.now(),
        sessionId: Value(sessionId),
        isAccepted: Value(accepted),
        rejectionReason: Value(accepted ? null : 'no stars detected'),
      ),
    );
  }

  test(
    'an interrupted session recovers its stats from the frames on record',
    () async {
      final first = RecoveredDatabase(NativeDatabase(dbFile));
      // A session that captured six 30s frames and then died before ending.
      final sessionId = await addSession(first);
      for (var i = 0; i < 6; i++) {
        await addFrame(first, sessionId, 30.0, i);
      }
      final before = await (first.select(
        first.imagingSessions,
      )..where((s) => s.id.equals(sessionId))).getSingle();
      // Precondition: the counters really are the zeros the crash left behind.
      expect(before.totalExposures, 0);
      expect(before.totalIntegrationSecs, 0);
      await first.close();

      final second = RecoveredDatabase(NativeDatabase(dbFile));
      addTearDown(second.close);
      final after = await (second.select(
        second.imagingSessions,
      )..where((s) => s.id.equals(sessionId))).getSingle();

      expect(after.totalExposures, 6);
      expect(after.totalIntegrationSecs, 180.0);
      // The Analytics HISTORY view counts successfulExposures, so rebuilding
      // only the total left every historical night reading "0 frames" there.
      expect(after.successfulExposures, 6);
    },
  );

  test('a cleanly-ended session keeps its own richer counters', () async {
    final first = RecoveredDatabase(NativeDatabase(dbFile));
    // 5 exposures recorded, of which only 3 produced an image row: the other
    // two FAILED. A failed exposure leaves no frame behind, so recomputing
    // from `captured_images` would silently erase it.
    final sessionId = await addSession(
      first,
      exposures: 5,
      successful: 3,
      integration: 150.0,
    );
    for (var i = 0; i < 3; i++) {
      await addFrame(first, sessionId, 30.0, i);
    }
    await first.close();

    final second = RecoveredDatabase(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await (second.select(
      second.imagingSessions,
    )..where((s) => s.id.equals(sessionId))).getSingle();

    expect(after.totalExposures, 5, reason: 'must not clobber a real count');
    expect(after.totalIntegrationSecs, 150.0);
    expect(after.successfulExposures, 3, reason: 'real success count kept');
  });

  test('a session that genuinely captured nothing stays at zero', () async {
    final first = RecoveredDatabase(NativeDatabase(dbFile));
    final sessionId = await addSession(first);
    await first.close();

    final second = RecoveredDatabase(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await (second.select(
      second.imagingSessions,
    )..where((s) => s.id.equals(sessionId))).getSingle();

    expect(after.totalExposures, 0);
    expect(after.totalIntegrationSecs, 0);
  });

  test('a session whose frames were all rejected is not recounted as '
      'integration', () async {
    final first = RecoveredDatabase(NativeDatabase(dbFile));
    // Ended cleanly: three exposures taken, every one rejected.
    final sessionId = await addSession(first, exposures: 3);
    for (var i = 0; i < 3; i++) {
      await addFrame(first, sessionId, 30.0, i, accepted: false);
    }
    await first.close();

    // Every later start reads the same row.
    for (var start = 0; start < 2; start++) {
      final next = RecoveredDatabase(NativeDatabase(dbFile));
      final after = await (next.select(
        next.imagingSessions,
      )..where((s) => s.id.equals(sessionId))).getSingle();
      await next.close();

      expect(after.totalExposures, 3);
      expect(after.successfulExposures, 0);
      expect(after.totalIntegrationSecs, 0);
    }
  });

  test('an interrupted session counts its accepted frames only', () async {
    final first = RecoveredDatabase(NativeDatabase(dbFile));
    final sessionId = await addSession(first);
    for (var i = 0; i < 4; i++) {
      await addFrame(first, sessionId, 30.0, i);
    }
    for (var i = 4; i < 6; i++) {
      await addFrame(first, sessionId, 30.0, i, accepted: false);
    }
    await first.close();

    final second = RecoveredDatabase(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await (second.select(
      second.imagingSessions,
    )..where((s) => s.id.equals(sessionId))).getSingle();

    expect(after.totalExposures, 6);
    expect(after.successfulExposures, 4);
    expect(after.totalIntegrationSecs, 120.0);
  });

  test('a session an earlier start had recounted from rejected frames is '
      'put back', () async {
    final first = RecoveredDatabase(NativeDatabase(dbFile));
    // What the old rebuild left: three rejected 30 s frames read as three
    // successful exposures and 90 s.
    final recounted = await addSession(
      first,
      exposures: 3,
      successful: 3,
      integration: 90.0,
    );
    for (var i = 0; i < 3; i++) {
      await addFrame(first, recounted, 30.0, i, accepted: false);
    }
    // A night with real integration and one frame rejected is not that.
    final real = await addSession(
      first,
      exposures: 3,
      successful: 2,
      integration: 60.0,
    );
    await addFrame(first, real, 30.0, 10);
    await addFrame(first, real, 30.0, 11);
    await addFrame(first, real, 30.0, 12, accepted: false);
    await first.close();

    final second = RecoveredDatabase(NativeDatabase(dbFile));
    addTearDown(second.close);
    Future<ImagingSession> read(int id) => (second.select(
      second.imagingSessions,
    )..where((s) => s.id.equals(id))).getSingle();

    final fixed = await read(recounted);
    expect(fixed.totalExposures, 3);
    expect(fixed.successfulExposures, 0);
    expect(fixed.totalIntegrationSecs, 0);

    final kept = await read(real);
    expect(kept.successfulExposures, 2);
    expect(kept.totalIntegrationSecs, 60.0);
  });
}
