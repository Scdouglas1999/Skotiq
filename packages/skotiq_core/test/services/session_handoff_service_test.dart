import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart' hide CapturedImage;
import 'package:skotiq_core/src/database/database.dart'
    show CapturedImage, ImagingSession, Target;

void main() {
  group('SessionHandoffService bundle round-trip', () {
    const service = SessionHandoffService();

    test('round-trips a quick start context through serialized bundle', () {
      final bundle = service.exportBundle(
        QuickStartContext(
          sessionId: 42,
          sessionName: 'Horsehead',
          targetName: 'Horsehead Nebula',
          targetRa: 5.7,
          targetDec: -2.5,
          sequenceName: 'NB sequence',
          completedFrames: 18,
          totalFrames: 60,
          lastSessionDate: DateTime(2026, 3, 10),
          equipmentSnapshot: EquipmentSnapshot(
            cameraGain: 100,
            filterPosition: 2,
            exposureTime: 300,
            capturedAt: DateTime(2026, 3, 10),
          ),
          totalIntegrationHours: 1.5,
        ),
      );

      final decoded = SessionHandoffBundle.decode(bundle.encode());

      expect(decoded.sessionId, 42);
      expect(decoded.targetName, 'Horsehead Nebula');
      expect(decoded.equipmentSnapshot?.cameraGain, 100);
      expect(service.describe(decoded), contains('18/60'));
    });
  });

  // Multi-night carry-over detection
  group('SessionHandoffService.detectCarryOver', () {
    late SkotiqDatabase db;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;
    late TargetsDao targetsDao;
    late SessionHandoffService service;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(db);
      imagesDao = ImagesDao(db);
      targetsDao = TargetsDao(db);
      service = SessionHandoffService(
        sessionsDao: sessionsDao,
        imagesDao: imagesDao,
        targetsDao: targetsDao,
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<int> createTarget(String name, {String? catalogId}) async {
      return db
          .into(db.targets)
          .insert(
            TargetsCompanion.insert(
              name: name,
              ra: 0.7,
              dec: 41.3,
              catalogId: Value(catalogId),
            ),
          );
    }

    Future<int> insertSession({
      required int targetId,
      required DateTime startTime,
      String status = 'completed',
    }) async {
      return sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          targetId: Value(targetId),
          startTime: startTime,
          status: Value(status),
        ),
      );
    }

    Future<void> insertLight({
      required int sessionId,
      required int targetId,
      required String filter,
      double exposure = 300.0,
      DateTime? capturedAt,
    }) async {
      await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/fake/$filter-$sessionId.fits',
          fileName: 'frame.fits',
          sessionId: Value(sessionId),
          targetId: Value(targetId),
          frameType: const Value('light'),
          exposureDuration: exposure,
          filter: Value(filter),
          capturedAt: capturedAt ?? DateTime.now(),
        ),
      );
    }

    test('returns empty when sequence has no target headers', () async {
      final sequence = Sequence.create(name: 'empty', nodes: const {});
      final out = await service.detectCarryOver(sequence: sequence);
      expect(out, isEmpty);
    });

    test(
      'detects carry-over for a target imaged on a recent prior night',
      () async {
        final now = DateTime(2026, 5, 18, 22);
        final targetId = await createTarget('M31', catalogId: 'M31');
        final previousNight = now.subtract(const Duration(days: 1));
        final sid = await insertSession(
          targetId: targetId,
          startTime: previousNight,
        );
        for (var i = 0; i < 5; i++) {
          await insertLight(
            sessionId: sid,
            targetId: targetId,
            filter: 'L',
            exposure: 300,
          );
        }

        final header = TargetHeaderNode(
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        );
        final sequence = Sequence.create(
          name: 'tonight',
          nodes: {header.id: header},
          rootNodeId: header.id,
        );

        final out = await service.detectCarryOver(sequence: sequence, now: now);
        expect(out.length, 1);
        final co = out.first;
        expect(co.targetName, 'M31');
        expect(co.previousAcceptedFrames, 5);
        expect(co.previousIntegrationSecs, 1500.0);
        expect(co.campaignIntegrationSecs, 1500.0);
        expect(co.hasCarryOver, isTrue);
        expect(co.perFilterIntegrationSecs['l'], 1500.0);
      },
    );

    test(
      'skips targets whose most recent session is older than lookback',
      () async {
        final now = DateTime(2026, 5, 18, 22);
        final targetId = await createTarget('M31', catalogId: 'M31');
        // 90 days ago - outside the default 14-day window.
        final ancient = now.subtract(const Duration(days: 90));
        final sid = await insertSession(targetId: targetId, startTime: ancient);
        await insertLight(
          sessionId: sid,
          targetId: targetId,
          filter: 'L',
          exposure: 300,
        );

        final header = TargetHeaderNode(
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        );
        final sequence = Sequence.create(
          name: 'tonight',
          nodes: {header.id: header},
          rootNodeId: header.id,
        );

        final out = await service.detectCarryOver(sequence: sequence, now: now);
        expect(out, isEmpty);
      },
    );

    test(
      'reports unavailable, not empty, when no data source exists',
      () async {
        const noDb = SessionHandoffService();
        final header = TargetHeaderNode(
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        );
        final sequence = Sequence.create(
          name: 'tonight',
          nodes: {header.id: header},
          rootNodeId: header.id,
        );
        expect(
          () => noDb.detectCarryOver(sequence: sequence),
          throwsA(isA<SessionCarryOverUnavailable>()),
        );
      },
    );

    test(
      'detects carry-over from host-backed snapshots without DAOs',
      () async {
        const noDb = SessionHandoffService();
        final now = DateTime(2026, 5, 18, 22);
        final previousNight = now.subtract(const Duration(days: 1));

        final target = Target(
          id: 1,
          name: 'M31',
          catalogId: 'M31',
          ra: 0.7,
          dec: 41.3,
          minAltitude: 30,
          priority: 5,
          totalPlannedSubs: 0,
          capturedSubs: 0,
          totalIntegrationSecs: 0,
          goalIntegrationSecs: 0,
          createdAt: now,
          updatedAt: now,
          isFavorite: false,
        );
        final session = ImagingSession(
          id: 10,
          targetId: 1,
          startTime: previousNight,
          totalExposures: 5,
          successfulExposures: 5,
          failedExposures: 0,
          totalIntegrationSecs: 1500,
          autofocusCount: 0,
          status: 'completed',
        );
        final images = List<CapturedImage>.generate(
          5,
          (i) => CapturedImage(
            id: i,
            filePath: '/tmp/m31_$i.fits',
            fileName: 'm31_$i.fits',
            fileFormat: 'fits',
            sessionId: 10,
            targetId: 1,
            frameType: 'light',
            exposureDuration: 300,
            binX: 1,
            binY: 1,
            filter: 'L',
            isPlateSolved: false,
            capturedAt: previousNight,
            createdAt: previousNight,
            isAccepted: true,
          ),
        );

        final header = TargetHeaderNode(
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
        );
        final sequence = Sequence.create(
          name: 'tonight',
          nodes: {header.id: header},
          rootNodeId: header.id,
        );

        final out = await noDb.detectCarryOver(
          sequence: sequence,
          libraryTargets: [target],
          capturedImages: images,
          sessions: [session],
          now: now,
        );

        expect(out, hasLength(1));
        expect(out.first.previousAcceptedFrames, 5);
      },
    );
  });
}
