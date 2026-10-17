import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/smart_night/guide_rms_collector.dart';

void main() {
  late SkotiqDatabase db;
  late GuideRmsCollector collector;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    collector = GuideRmsCollector(
      imagesDao: db.imagesDao,
      guideRmsHistoryDao: db.guideRmsHistoryDao,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addImage({
    required int sessionId,
    required DateTime capturedAt,
    required double exposureSeconds,
    double? guideRmsTotal,
  }) {
    return db.imagesDao
        .createImage(
          CapturedImagesCompanion(
            filePath: Value(
              'C:/frames/${capturedAt.millisecondsSinceEpoch}.fits',
            ),
            fileName: Value('${capturedAt.millisecondsSinceEpoch}.fits'),
            sessionId: Value(sessionId),
            frameType: const Value('light'),
            exposureDuration: Value(exposureSeconds),
            guidingRmsTotal: Value(guideRmsTotal),
            capturedAt: Value(capturedAt),
          ),
        )
        .then((_) {});
  }

  test('writes one guide RMS history row from valid session frames', () async {
    final now = DateTime.utc(2026, 5, 22, 4);
    final sessionId = await db.sessionsDao.startSession(name: 'Smart Night');
    await addImage(
      sessionId: sessionId,
      capturedAt: now,
      exposureSeconds: 120,
      guideRmsTotal: 0.8,
    );
    await addImage(
      sessionId: sessionId,
      capturedAt: now.add(const Duration(minutes: 3)),
      exposureSeconds: 180,
      guideRmsTotal: 1.0,
    );
    await addImage(
      sessionId: sessionId,
      capturedAt: now.add(const Duration(minutes: 6)),
      exposureSeconds: 180,
      guideRmsTotal: null,
    );

    final insertedId = await collector.collectSession(
      sessionId: sessionId,
      mountId: 'mount-a',
      recordedAt: now.add(const Duration(hours: 1)),
    );

    expect(insertedId, isNotNull);
    final history = await db.guideRmsHistoryDao.recentForMount('mount-a');
    expect(history, hasLength(1));
    expect(history.single.sessionId, sessionId.toString());
    expect(history.single.totalRmsArcsec, closeTo(0.9, 1e-9));
    expect(history.single.sampleCount, 2);
    expect(history.single.exposureSeconds, closeTo(150, 1e-9));
    expect(history.single.targetId, isNull);
  });

  test('does not write without a mount id or valid guiding samples', () async {
    final now = DateTime.utc(2026, 5, 22, 4);
    final sessionId = await db.sessionsDao.startSession(name: 'No guiding');
    await addImage(
      sessionId: sessionId,
      capturedAt: now,
      exposureSeconds: 120,
      guideRmsTotal: null,
    );

    expect(
      await collector.collectSession(sessionId: sessionId, mountId: 'mount-a'),
      isNull,
    );
    expect(
      await collector.collectSession(sessionId: sessionId, mountId: '  '),
      isNull,
    );
    expect(await db.guideRmsHistoryDao.recentForMount('mount-a'), isEmpty);
  });
}
