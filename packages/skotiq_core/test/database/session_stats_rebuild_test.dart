import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

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
    tempDir = await Directory.systemTemp.createTemp('ns_session_stats_');
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
    int n,
  ) async {
    await db.imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/tmp/frame_${sessionId}_$n.fits',
        fileName: 'frame_${sessionId}_$n.fits',
        exposureDuration: seconds,
        capturedAt: DateTime.now(),
        sessionId: Value(sessionId),
      ),
    );
  }

  test(
    'an interrupted session recovers its stats from the frames on record',
    () async {
      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
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

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
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
    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
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

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await (second.select(
      second.imagingSessions,
    )..where((s) => s.id.equals(sessionId))).getSingle();

    expect(after.totalExposures, 5, reason: 'must not clobber a real count');
    expect(after.totalIntegrationSecs, 150.0);
    expect(after.successfulExposures, 3, reason: 'real success count kept');
  });

  test('a session that genuinely captured nothing stays at zero', () async {
    final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final sessionId = await addSession(first);
    await first.close();

    final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    final after = await (second.select(
      second.imagingSessions,
    )..where((s) => s.id.equals(sessionId))).getSingle();

    expect(after.totalExposures, 0);
    expect(after.totalIntegrationSecs, 0);
  });
}
