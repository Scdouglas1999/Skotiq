import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/campaign_rollup_service.dart';
import 'package:skotiq_core/src/services/imaging_records_repository.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CampaignRollupService', () {
    late SkotiqDatabase db;
    late SessionsDao sessionsDao;
    late ImagesDao imagesDao;
    late TargetsDao targetsDao;
    late IntegrationGoalService goalService;
    late CampaignRollupService service;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      sessionsDao = SessionsDao(db);
      imagesDao = ImagesDao(db);
      targetsDao = TargetsDao(db);
      goalService = IntegrationGoalService(db);
      service = CampaignRollupService(
        records: ImagingRecordsRepository.local(
          sessionsDao: sessionsDao,
          imagesDao: imagesDao,
        ),
        targetsDao: targetsDao,
        goalService: goalService,
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<int> createTarget(String name) async {
      return db
          .into(db.targets)
          .insert(TargetsCompanion.insert(name: name, ra: 5.6, dec: -5.4));
    }

    Future<int> insertSession({
      required int targetId,
      required String name,
      required DateTime startTime,
      DateTime? endTime,
      double? avgHfr,
      double? avgSeeing,
      double totalIntegrationSecs = 0.0,
      int successfulExposures = 0,
      String status = 'completed',
    }) async {
      final id = await sessionsDao.createSession(
        ImagingSessionsCompanion.insert(
          name: Value(name),
          targetId: Value(targetId),
          startTime: startTime,
          endTime: Value(endTime),
          status: Value(status),
        ),
      );
      await sessionsDao.updateSessionStats(
        id,
        successfulExposures: successfulExposures,
        totalIntegrationSecs: totalIntegrationSecs,
        avgHfr: avgHfr,
      );
      if (avgSeeing != null) {
        await sessionsDao.updateWeatherConditions(id, avgSeeing: avgSeeing);
      }
      return id;
    }

    Future<void> insertLight({
      required int sessionId,
      required int targetId,
      required String filter,
      double exposure = 60.0,
      DateTime? capturedAt,
    }) async {
      await imagesDao.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/fake/$filter-$sessionId-${exposure.toInt()}.fits',
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

    test('aggregates per-filter integration across multiple sessions', () async {
      final targetId = await createTarget('M42');

      final n1 = await insertSession(
        targetId: targetId,
        name: 'Night 1',
        startTime: DateTime.utc(2026, 1, 1, 22),
        endTime: DateTime.utc(2026, 1, 2, 1),
        avgHfr: 2.3,
        successfulExposures: 12,
        totalIntegrationSecs: 720,
      );
      final n2 = await insertSession(
        targetId: targetId,
        name: 'Night 2',
        startTime: DateTime.utc(2026, 1, 3, 22),
        endTime: DateTime.utc(2026, 1, 4, 2),
        avgHfr: 2.7,
        successfulExposures: 20,
        totalIntegrationSecs: 1200,
        avgSeeing: 2.5,
      );

      // 5x L + 2x R on night 1
      for (var i = 0; i < 5; i++) {
        await insertLight(
          sessionId: n1,
          targetId: targetId,
          filter: 'L',
          exposure: 60,
        );
      }
      for (var i = 0; i < 2; i++) {
        await insertLight(
          sessionId: n1,
          targetId: targetId,
          filter: 'R',
          exposure: 120,
        );
      }
      // 10x L on night 2 — mixed case to confirm normalisation
      for (var i = 0; i < 10; i++) {
        await insertLight(
          sessionId: n2,
          targetId: targetId,
          filter: 'l',
          exposure: 60,
        );
      }

      final rollup = await service.buildForTarget(targetId);

      expect(rollup.targetName, 'M42');
      expect(rollup.sessionCount, 2);
      // Drift stores DateTimes as Unix seconds and returns them in local
      // time, so we compare the underlying instants directly.
      expect(
        rollup.firstSessionAt!.millisecondsSinceEpoch,
        DateTime.utc(2026, 1, 1, 22).millisecondsSinceEpoch,
      );
      expect(
        rollup.lastSessionAt!.millisecondsSinceEpoch,
        DateTime.utc(2026, 1, 3, 22).millisecondsSinceEpoch,
      );
      // Sessions sorted most-recent-first.
      expect(rollup.sessions.first.sessionId, n2);

      // L and R rollups; L is grouped case-insensitively.
      expect(rollup.filters.map((f) => f.filter.toLowerCase()).toList(), [
        'l',
        'r',
      ]);
      final l = rollup.filters.firstWhere((f) => f.filter.toLowerCase() == 'l');
      expect(l.capturedFrames, 15);
      expect(l.capturedIntegrationSecs, 900.0);
      final r = rollup.filters.firstWhere((f) => f.filter.toLowerCase() == 'r');
      expect(r.capturedFrames, 2);
      expect(r.capturedIntegrationSecs, 240.0);

      // total integration sums.
      expect(rollup.totalCapturedIntegrationSecs, 1140.0);

      // mean HFR is weighted by successful exposure counts:
      // (2.3*12 + 2.7*20) / 32 = (27.6 + 54.0) / 32 = 2.55
      expect(rollup.meanSessionHfr, closeTo(2.55, 1e-6));
      expect(rollup.meanSessionSeeing, closeTo(2.5, 1e-6));

      // Efficiency means: n1 720/10800=0.0667, n2 1200/14400=0.0833; mean ~0.075
      expect(rollup.meanEffectiveImagingFraction, closeTo(0.075, 1e-3));
    });

    test(
      'attaches goals and reports progress, including goal-only filters',
      () async {
        final targetId = await createTarget('NGC7000');
        final sId = await insertSession(
          targetId: targetId,
          name: 'Pelican',
          startTime: DateTime.utc(2026, 2, 1, 22),
          endTime: DateTime.utc(2026, 2, 2, 1),
          successfulExposures: 4,
          totalIntegrationSecs: 4 * 180.0,
        );
        for (var i = 0; i < 4; i++) {
          await insertLight(
            sessionId: sId,
            targetId: targetId,
            filter: 'Ha',
            exposure: 180,
          );
        }

        // Two goals: one for the captured Ha filter, one for OIII with no
        // captures yet — the rollup should show OIII as a 0% row.
        await goalService.upsert(
          IntegrationGoal(
            targetId: targetId,
            filter: 'Ha',
            exposureSeconds: 180,
            frameCount: 20,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );
        await goalService.upsert(
          IntegrationGoal(
            targetId: targetId,
            filter: 'OIII',
            exposureSeconds: 180,
            frameCount: 15,
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        );

        final rollup = await service.buildForTarget(targetId);
        expect(rollup.hasGoals, isTrue);
        final ha = rollup.filters.firstWhere((f) => f.filter == 'Ha');
        expect(ha.goalFrames, 20);
        expect(ha.percentComplete, closeTo(4 / 20, 1e-6));
        expect(ha.remainingFrames, 16);
        expect(ha.goalIntegrationSecs, 3600.0);

        final oiii = rollup.filters.firstWhere((f) => f.filter == 'OIII');
        expect(oiii.capturedFrames, 0);
        expect(oiii.goalFrames, 15);
        expect(oiii.percentComplete, 0.0);
        expect(rollup.isComplete, isFalse);
        expect(rollup.totalGoalIntegrationSecs, 20 * 180.0 + 15 * 180.0);
      },
    );

    test('isComplete is true only when every goal is met', () async {
      final targetId = await createTarget('Heart');
      final sId = await insertSession(
        targetId: targetId,
        name: 'Done',
        startTime: DateTime.utc(2026, 3, 1, 22),
        endTime: DateTime.utc(2026, 3, 2, 0),
        successfulExposures: 10,
        totalIntegrationSecs: 1800,
      );
      for (var i = 0; i < 10; i++) {
        await insertLight(
          sessionId: sId,
          targetId: targetId,
          filter: 'L',
          exposure: 180,
        );
      }
      await goalService.upsert(
        IntegrationGoal(
          targetId: targetId,
          filter: 'L',
          exposureSeconds: 180,
          frameCount: 10,
          createdAt: DateTime.utc(2026, 2, 1),
        ),
      );
      final rollup = await service.buildForTarget(targetId);
      expect(rollup.isComplete, isTrue);
    });

    test('throws StateError for unknown target id', () async {
      await expectLater(
        service.buildForTarget(99999),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'buildForAllTargets returns entries for targets without sessions',
      () async {
        final t1 = await createTarget('Untouched');
        final t2 = await createTarget('M101');
        final sId = await insertSession(
          targetId: t2,
          name: 'M101 night',
          startTime: DateTime.utc(2026, 4, 1, 22),
          endTime: DateTime.utc(2026, 4, 2, 0),
          successfulExposures: 1,
          totalIntegrationSecs: 60,
        );
        await insertLight(sessionId: sId, targetId: t2, filter: 'L');

        final all = await service.buildForAllTargets();
        expect(all.keys.toSet(), {t1, t2});
        expect(all[t1]!.sessionCount, 0);
        expect(all[t1]!.filters, isEmpty);
        expect(all[t2]!.sessionCount, 1);
        expect(all[t2]!.filters, hasLength(1));
      },
    );
  });
}
