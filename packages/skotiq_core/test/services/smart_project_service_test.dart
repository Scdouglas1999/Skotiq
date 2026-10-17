import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';
import 'package:skotiq_core/src/models/imaging/integration_curve.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/smart_project_service.dart';

void main() {
  late SkotiqDatabase db;
  late IntegratedMastersDao mastersDao;
  late IntegrationGoalService goals;
  late SmartProjectService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    mastersDao = IntegratedMastersDao(db);
    goals = IntegrationGoalService(db);
    service = SmartProjectService(database: db, goals: goals);
  });

  tearDown(() async {
    await goals.dispose();
    await db.close();
  });

  // Seeding helpers

  Future<int> insertTarget(String name) async {
    return db
        .into(db.targets)
        .insert(TargetsCompanion.insert(name: name, ra: 1.0, dec: 2.0));
  }

  Future<int> insertSub({
    int? targetId,
    String filter = 'L',
    double exposure = 120.0,
    required DateTime capturedAt,
    bool accepted = true,
  }) async {
    return db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: '/lights/${capturedAt.microsecondsSinceEpoch}.fits',
            fileName: '${capturedAt.microsecondsSinceEpoch}.fits',
            frameType: const Value('light'),
            exposureDuration: exposure,
            capturedAt: capturedAt,
            targetId: Value(targetId),
            filter: Value(filter),
            isAccepted: Value(accepted),
          ),
        );
  }

  Future<int> insertMaster({int? targetId, String? filter = 'L'}) {
    return mastersDao.insertMaster(
      targetId: targetId,
      name: 'M51 master',
      status: IntegratedMasterStatus.accumulating,
      accumulationMode: AccumulationMode.runningWeightedMean,
      filter: filter,
    );
  }

  /// Fold one sub into a master with a weight + snr, recording the join row.
  Future<void> fold({
    required int masterId,
    required int imageId,
    required double weight,
    double? snr,
    bool accepted = true,
  }) async {
    await mastersDao.recordFoldedFrame(
      masterId: masterId,
      imageId: imageId,
      weight: accepted ? weight : null,
      accepted: accepted,
      snr: snr,
    );
  }

  /// Fold with the EXACT production accumulate signature: accepted, no weight.
  /// `MasterAccumulationService.addNight` records folds this way (weight
  /// defaults to null), so the growth/best-night/deficit math must work against
  /// null-weight accepted subs, not only against weighted folds.
  Future<void> foldAccumulate({
    required int masterId,
    required int imageId,
  }) async {
    await mastersDao.recordFoldedFrame(
      masterId: masterId,
      imageId: imageId,
      accepted: true,
    );
  }

  // Growth curve

  group('growthCurve', () {
    test(
      'accumulates integration time across distinct capture nights',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);

        // Night 1: two 120s subs. Night 2: three 120s subs. Night 3: one 300s.
        // Seeded as LOCAL wall-clock instants, which is how an observer names
        // when they were at the telescope. Nights run noon-to-noon local, so
        // the 00:30 and 01:00 subs belong to the night that started the
        // previous evening — not to their own calendar day.
        final n1 = DateTime(2026, 6, 1, 23);
        final n2 = DateTime(2026, 6, 3, 0, 30); // night of Jun 2
        final n3 = DateTime(2026, 6, 5, 1); // night of Jun 4

        final ids = <int>[];
        for (final cap in [n1, n1]) {
          ids.add(await insertSub(targetId: targetId, capturedAt: cap));
        }
        for (final cap in [n2, n2, n2]) {
          ids.add(await insertSub(targetId: targetId, capturedAt: cap));
        }
        ids.add(
          await insertSub(targetId: targetId, exposure: 300.0, capturedAt: n3),
        );

        for (final id in ids) {
          await fold(masterId: masterId, imageId: id, weight: 1.0);
        }

        final curve = await service.growthCurve(masterId);
        expect(curve, hasLength(3));

        // Ascending by date.
        expect(curve[0].date, DateTime(2026, 6, 1));
        expect(curve[1].date, DateTime(2026, 6, 2));
        expect(curve[2].date, DateTime(2026, 6, 4));

        // Cumulative seconds: 240 → 600 → 900.
        expect(curve[0].cumulativeIntegrationSeconds, 240.0);
        expect(curve[1].cumulativeIntegrationSeconds, 600.0);
        expect(curve[2].cumulativeIntegrationSeconds, 900.0);

        // Cumulative accepted-frame count: 2 → 5 → 6.
        expect(curve[0].framesToDate, 2);
        expect(curve[1].framesToDate, 5);
        expect(curve[2].framesToDate, 6);
      },
    );

    test(
      'excludes rejected (null-weight) subs from the growth total',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);
        final cap = DateTime.utc(2026, 6, 1, 23);

        final keep = await insertSub(targetId: targetId, capturedAt: cap);
        final drop = await insertSub(
          targetId: targetId,
          capturedAt: cap,
          accepted: false,
        );
        await fold(masterId: masterId, imageId: keep, weight: 1.0);
        await fold(
          masterId: masterId,
          imageId: drop,
          weight: 1.0,
          accepted: false,
        );

        final curve = await service.growthCurve(masterId);
        expect(curve, hasLength(1));
        expect(curve.single.framesToDate, 1);
        expect(curve.single.cumulativeIntegrationSeconds, 120.0);
      },
    );

    test('empty for a master with no folded subs', () async {
      final masterId = await insertMaster();
      expect(await service.growthCurve(masterId), isEmpty);
    });
  });

  // Best night

  group('bestNight', () {
    test('picks the night with the highest mean weight', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);

      final n1 = DateTime(2026, 6, 1, 23);
      final n2 = DateTime(2026, 6, 3, 23);

      // Night 1 mean weight = (0.4 + 0.6)/2 = 0.5.
      final a = await insertSub(targetId: targetId, capturedAt: n1);
      final b = await insertSub(targetId: targetId, capturedAt: n1);
      await fold(masterId: masterId, imageId: a, weight: 0.4);
      await fold(masterId: masterId, imageId: b, weight: 0.6);

      // Night 2 mean weight = (0.9 + 0.95)/2 = 0.925 (the winner).
      final c = await insertSub(targetId: targetId, capturedAt: n2);
      final d = await insertSub(targetId: targetId, capturedAt: n2);
      await fold(masterId: masterId, imageId: c, weight: 0.9);
      await fold(masterId: masterId, imageId: d, weight: 0.95);

      final best = await service.bestNight(masterId);
      expect(best, isNotNull);
      expect(best!.date, DateTime(2026, 6, 3));
      expect(best.frameCount, 2);
      expect(best.meanWeight, closeTo(0.925, 1e-9));
    });

    test('null when no accepted subs', () async {
      final masterId = await insertMaster();
      expect(await service.bestNight(masterId), isNull);
    });
  });

  // Re-reference advisory

  group('reReferenceAdvice', () {
    test(
      'recommends when a later night beats the reference past threshold',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);

        // Reference night (earliest): mean weight 0.5.
        final ref = DateTime(2026, 6, 1, 23);
        final r1 = await insertSub(targetId: targetId, capturedAt: ref);
        await fold(masterId: masterId, imageId: r1, weight: 0.5);

        // Later night: mean weight 0.8 → +60% over reference, above the 15%
        // default threshold.
        final later = DateTime(2026, 6, 4, 23);
        final l1 = await insertSub(targetId: targetId, capturedAt: later);
        await fold(masterId: masterId, imageId: l1, weight: 0.8);

        final advice = await service.reReferenceAdvice(masterId);
        expect(advice.recommended, isTrue);
        expect(advice.referenceDate, DateTime(2026, 6, 1));
        expect(advice.candidateDate, DateTime(2026, 6, 4));
        expect(advice.gainFraction, closeTo(0.6, 1e-9));
      },
    );

    test(
      'does not recommend when later nights only marginally beat reference',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);

        final ref = DateTime.utc(2026, 6, 1, 23);
        final r1 = await insertSub(targetId: targetId, capturedAt: ref);
        await fold(masterId: masterId, imageId: r1, weight: 0.80);

        // Later night only +5% → below the 15% threshold.
        final later = DateTime.utc(2026, 6, 4, 23);
        final l1 = await insertSub(targetId: targetId, capturedAt: later);
        await fold(masterId: masterId, imageId: l1, weight: 0.84);

        final advice = await service.reReferenceAdvice(masterId);
        expect(advice.recommended, isFalse);
        expect(advice.gainFraction, closeTo(0.05, 1e-9));
      },
    );

    test('never recommends for a single-night master', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);
      final cap = DateTime.utc(2026, 6, 1, 23);
      final s = await insertSub(targetId: targetId, capturedAt: cap);
      await fold(masterId: masterId, imageId: s, weight: 0.9);

      final advice = await service.reReferenceAdvice(masterId);
      expect(advice.recommended, isFalse);
      expect(advice.candidateDate, isNull);
    });
  });

  // PushDeficitToScheduler — the SAFE write seam

  group('pushDeficitToScheduler', () {
    test(
      'raises a smaller existing goal to the absolute deficit target',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);

        // 4 × 120s = 480s of L integration; current SNR 20 (from curve).
        final cap = DateTime.utc(2026, 6, 1, 23);
        for (var i = 0; i < 4; i++) {
          final id = await insertSub(
            targetId: targetId,
            filter: 'L',
            exposure: 120.0,
            capturedAt: cap,
          );
          await fold(masterId: masterId, imageId: id, weight: 1.0);
        }

        // Improvement curve: last point achieves SNR 20.
        final curve = IntegrationCurve(
          points: const [
            IntegrationCurvePoint(
              n: 4,
              snr: 20.0,
              fwhm: 2.0,
              cumulativeIntegrationS: 480.0,
            ),
          ],
          recommendation: IntegrationCurve.empty.recommendation,
        );
        await mastersDao.updateSmartFields(
          masterId,
          improvementCurveJson: jsonEncode(curve.toJson()),
        );

        // Pre-existing goal: 10 frames of L @ 120s (smaller than the deficit
        // target so the push raises it).
        await goals.upsert(
          IntegrationGoal(
            targetId: targetId,
            filter: 'L',
            exposureSeconds: 120.0,
            frameCount: 10,
            createdAt: DateTime.utc(2026, 6, 1),
          ),
        );

        // Target SNR 40 → need (40/20)^2 = 4× the time = 1920s; deficit 1440s →
        // ceil(1440/120) = 12 frames. The absolute deficit target is
        // captured(4) + 12 = 16, which exceeds the existing 10 → raised to 16.
        final result = await service.pushDeficitToScheduler(masterId, 40.0);
        expect(result.applied, isTrue);
        expect(result.currentSnr, 20.0);
        expect(result.deficitSeconds, closeTo(1440.0, 1e-6));
        expect(result.perFilter, hasLength(1));
        expect(result.perFilter.single.filter, 'L');
        expect(result.perFilter.single.deltaFrames, 12);
        expect(result.perFilter.single.newFrameCount, 16); // captured(4) + 12

        // Persisted: the goal frame_count was raised to the absolute target 16,
        // leaving everything else (exposure, filter, priority) untouched.
        final persisted = await goals.listForTarget(targetId);
        expect(persisted, hasLength(1));
        expect(persisted.single.frameCount, 16);
        expect(persisted.single.exposureSeconds, 120.0);
        expect(persisted.single.filter, 'L');
      },
    );

    test('never lowers a larger pre-existing operator goal', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);

      final cap = DateTime.utc(2026, 6, 1, 23);
      for (var i = 0; i < 4; i++) {
        final id = await insertSub(
          targetId: targetId,
          filter: 'L',
          exposure: 120.0,
          capturedAt: cap,
        );
        await fold(masterId: masterId, imageId: id, weight: 1.0);
      }
      final curve = IntegrationCurve(
        points: const [
          IntegrationCurvePoint(
            n: 4,
            snr: 20.0,
            fwhm: 2.0,
            cumulativeIntegrationS: 480.0,
          ),
        ],
        recommendation: IntegrationCurve.empty.recommendation,
      );
      await mastersDao.updateSmartFields(
        masterId,
        improvementCurveJson: jsonEncode(curve.toJson()),
      );

      // Operator already wants 50 frames — far more than the deficit target of
      // captured(4) + 12 = 16. The push must not lower their goal.
      await goals.upsert(
        IntegrationGoal(
          targetId: targetId,
          filter: 'L',
          exposureSeconds: 120.0,
          frameCount: 50,
          createdAt: DateTime.utc(2026, 6, 1),
        ),
      );

      final result = await service.pushDeficitToScheduler(masterId, 40.0);
      expect(result.applied, isTrue);
      expect(result.perFilter.single.newFrameCount, 50); // max(50, 16)

      final persisted = await goals.listForTarget(targetId);
      expect(persisted.single.frameCount, 50);
    });

    test(
      'is idempotent — re-running with the same target does not double-count',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);

        // 4 × 120s = 480s of L integration; current SNR 20 (from curve).
        final cap = DateTime.utc(2026, 6, 1, 23);
        for (var i = 0; i < 4; i++) {
          final id = await insertSub(
            targetId: targetId,
            filter: 'L',
            exposure: 120.0,
            capturedAt: cap,
          );
          await fold(masterId: masterId, imageId: id, weight: 1.0);
        }
        final curve = IntegrationCurve(
          points: const [
            IntegrationCurvePoint(
              n: 4,
              snr: 20.0,
              fwhm: 2.0,
              cumulativeIntegrationS: 480.0,
            ),
          ],
          recommendation: IntegrationCurve.empty.recommendation,
        );
        await mastersDao.updateSmartFields(
          masterId,
          improvementCurveJson: jsonEncode(curve.toJson()),
        );

        // First push seeds the goal at captured(4) + 12 = 16.
        final first = await service.pushDeficitToScheduler(masterId, 40.0);
        expect(first.applied, isTrue);
        expect(first.perFilter.single.newFrameCount, 16);
        final afterFirst = await goals.listForTarget(targetId);
        expect(afterFirst, hasLength(1));
        expect(afterFirst.single.frameCount, 16);

        // Re-running with the SAME target SNR must converge — NOT 16 + 12 = 28.
        // The deficit depends on the master's state alone, so the second run
        // upserts the same absolute target and the goal count is unchanged.
        final second = await service.pushDeficitToScheduler(masterId, 40.0);
        expect(
          second.perFilter.single.newFrameCount,
          16,
          reason: 're-running must not double-count the deficit',
        );
        final afterSecond = await goals.listForTarget(targetId);
        expect(
          afterSecond,
          hasLength(1),
          reason: 'no duplicate goal row is created',
        );
        expect(
          afterSecond.single.frameCount,
          16,
          reason: 'frame_count is idempotent across repeated pushes',
        );

        // A third run is likewise stable.
        await service.pushDeficitToScheduler(masterId, 40.0);
        final afterThird = await goals.listForTarget(targetId);
        expect(afterThird.single.frameCount, 16);
      },
    );

    test('seeds a new goal at captured + deficit when none exists', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);

      final cap = DateTime.utc(2026, 6, 1, 23);
      // 9 captured L subs (all accepted → captured count is 9).
      final ids = <int>[];
      for (var i = 0; i < 9; i++) {
        ids.add(
          await insertSub(
            targetId: targetId,
            filter: 'L',
            exposure: 60.0,
            capturedAt: cap,
          ),
        );
      }
      // Fold 9 of them; 9 × 60 = 540s.
      for (final id in ids) {
        await fold(masterId: masterId, imageId: id, weight: 1.0);
      }

      final curve = IntegrationCurve(
        points: const [
          IntegrationCurvePoint(
            n: 9,
            snr: 10.0,
            fwhm: 2.0,
            cumulativeIntegrationS: 540.0,
          ),
        ],
        recommendation: IntegrationCurve.empty.recommendation,
      );
      await mastersDao.updateSmartFields(
        masterId,
        improvementCurveJson: jsonEncode(curve.toJson()),
      );

      // Target SNR 20 → 4× time = 2160s; deficit 1620s → ceil(1620/60) = 27.
      final result = await service.pushDeficitToScheduler(masterId, 20.0);
      expect(result.applied, isTrue);
      expect(result.perFilter.single.deltaFrames, 27);

      // No prior goal → seeded at capturedCount(9) + 27 = 36, so the engine's
      // remaining = 36 − 9 = 27 equals exactly the deficit frames.
      final persisted = await goals.listForTarget(targetId);
      expect(persisted, hasLength(1));
      expect(persisted.single.frameCount, 36);
      expect(persisted.single.exposureSeconds, 60.0);
    });

    test('splits the deficit across multiple filters proportionally', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId, filter: null);

      final cap = DateTime.utc(2026, 6, 1, 23);
      // L: 3 × 100s = 300s. Ha: 1 × 100s = 100s. Total 400s.
      for (var i = 0; i < 3; i++) {
        final id = await insertSub(
          targetId: targetId,
          filter: 'L',
          exposure: 100.0,
          capturedAt: cap,
        );
        await fold(masterId: masterId, imageId: id, weight: 1.0);
      }
      final ha = await insertSub(
        targetId: targetId,
        filter: 'Ha',
        exposure: 100.0,
        capturedAt: cap,
      );
      await fold(masterId: masterId, imageId: ha, weight: 1.0);

      final curve = IntegrationCurve(
        points: const [
          IntegrationCurvePoint(
            n: 4,
            snr: 10.0,
            fwhm: 2.0,
            cumulativeIntegrationS: 400.0,
          ),
        ],
        recommendation: IntegrationCurve.empty.recommendation,
      );
      await mastersDao.updateSmartFields(
        masterId,
        improvementCurveJson: jsonEncode(curve.toJson()),
      );

      // Target SNR 20 → 4× time = 1600s; deficit 1200s. L gets 75% = 900s →
      // 9 frames; Ha gets 25% = 300s → 3 frames.
      final result = await service.pushDeficitToScheduler(masterId, 20.0);
      expect(result.applied, isTrue);
      final byFilter = {for (final f in result.perFilter) f.filter: f};
      expect(byFilter['L']!.deltaFrames, 9);
      expect(byFilter['Ha']!.deltaFrames, 3);
    });

    test('no-op when the master already meets the target SNR', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);
      final cap = DateTime.utc(2026, 6, 1, 23);
      final id = await insertSub(targetId: targetId, capturedAt: cap);
      await fold(masterId: masterId, imageId: id, weight: 1.0);

      final curve = IntegrationCurve(
        points: const [
          IntegrationCurvePoint(
            n: 1,
            snr: 50.0,
            fwhm: 2.0,
            cumulativeIntegrationS: 120.0,
          ),
        ],
        recommendation: IntegrationCurve.empty.recommendation,
      );
      await mastersDao.updateSmartFields(
        masterId,
        improvementCurveJson: jsonEncode(curve.toJson()),
      );

      final result = await service.pushDeficitToScheduler(masterId, 40.0);
      expect(result.applied, isFalse);
      expect(await goals.listForTarget(targetId), isEmpty);
    });

    test('no-op when the master has no target id', () async {
      final masterId = await insertMaster(targetId: null);
      final cap = DateTime.utc(2026, 6, 1, 23);
      final id = await insertSub(capturedAt: cap);
      await fold(masterId: masterId, imageId: id, weight: 1.0);

      final result = await service.pushDeficitToScheduler(masterId, 40.0);
      expect(result.applied, isFalse);
      expect(identical(result, DeficitPushResult.notApplied), isTrue);
    });

    test(
      'falls back to the target_snr/target_integration_s anchor with no curve',
      () async {
        final targetId = await insertTarget('M51');
        final masterId = await insertMaster(targetId: targetId);

        final cap = DateTime.utc(2026, 6, 1, 23);
        // 4 × 120s = 480s folded.
        for (var i = 0; i < 4; i++) {
          final id = await insertSub(
            targetId: targetId,
            filter: 'L',
            exposure: 120.0,
            capturedAt: cap,
          );
          await fold(masterId: masterId, imageId: id, weight: 1.0);
        }

        // Anchor: SNR 20 was achieved at 480s. No improvement curve persisted, so
        // the shot-noise fallback reconstructs currentSnr = 20 at 480s.
        await mastersDao.updateSmartFields(
          masterId,
          targetSnr: 20.0,
          targetIntegrationS: 480.0,
        );

        // Target SNR 40 → deficit 1440s → 12 frames.
        final result = await service.pushDeficitToScheduler(masterId, 40.0);
        expect(result.applied, isTrue);
        expect(result.currentSnr, closeTo(20.0, 1e-9));
        expect(result.perFilter.single.deltaFrames, 12);
      },
    );

    test('target_snr is the ACHIEVED anchor, not the goal: a goal-SNR argument '
        'above the achieved anchor still produces a deficit', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);

      final cap = DateTime.utc(2026, 6, 1, 23);
      for (var i = 0; i < 4; i++) {
        final id = await insertSub(
          targetId: targetId,
          filter: 'L',
          exposure: 120.0,
          capturedAt: cap,
        );
        await fold(masterId: masterId, imageId: id, weight: 1.0);
      }
      // Achieved anchor: SNR 20 reached at 480s (NOT a desired goal of 20).
      await mastersDao.updateSmartFields(
        masterId,
        targetSnr: 20.0,
        targetIntegrationS: 480.0,
      );

      // The desired goal SNR (the method argument) is 30 — above the achieved
      // anchor of 20 — so there must be a real deficit. currentSnr reconstructs
      // to the achieved 20, never to the goal 30.
      final result = await service.pushDeficitToScheduler(masterId, 30.0);
      expect(result.currentSnr, closeTo(20.0, 1e-9));
      expect(result.applied, isTrue);
      expect(result.targetSnr, 30.0);
      expect(result.deficitSeconds, greaterThan(0));
    });
  });

  // Accumulate path: production folds carry a NULL weight

  group('accumulate-path null-weight folds (production signature)', () {
    test('growthCurve includes accepted null-weight folds', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);

      final n1 = DateTime.utc(2026, 6, 1, 23);
      final n2 = DateTime.utc(2026, 6, 3, 0, 30);
      final ids = <int>[];
      for (final cap in [n1, n1, n2]) {
        ids.add(await insertSub(targetId: targetId, capturedAt: cap));
      }
      // Fold with the production accumulate signature (weight == null).
      for (final id in ids) {
        await foldAccumulate(masterId: masterId, imageId: id);
      }

      final curve = await service.growthCurve(masterId);
      // Two nights, all three accepted subs counted despite null weights.
      expect(curve, hasLength(2));
      expect(curve[0].framesToDate, 2);
      expect(curve[1].framesToDate, 3);
      expect(curve[0].cumulativeIntegrationSeconds, 240.0);
      expect(curve[1].cumulativeIntegrationSeconds, 360.0);
    });

    test('bestNight returns a night (with real frame counts) for null-weight '
        'folds', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);
      final cap = DateTime.utc(2026, 6, 1, 23);
      final a = await insertSub(targetId: targetId, capturedAt: cap);
      final b = await insertSub(targetId: targetId, capturedAt: cap);
      await foldAccumulate(masterId: masterId, imageId: a);
      await foldAccumulate(masterId: masterId, imageId: b);

      final best = await service.bestNight(masterId);
      expect(best, isNotNull);
      expect(best!.frameCount, 2);
      expect(best.integrationSeconds, 240.0);
      // No weights → meanWeight collapses to 0 (absent), but the night is real.
      expect(best.meanWeight, 0);
    });

    test('pushDeficitToScheduler fires for an accumulate master built entirely '
        'from null-weight folds', () async {
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);

      final cap = DateTime.utc(2026, 6, 1, 23);
      for (var i = 0; i < 4; i++) {
        final id = await insertSub(
          targetId: targetId,
          filter: 'L',
          exposure: 120.0,
          capturedAt: cap,
        );
        await foldAccumulate(masterId: masterId, imageId: id);
      }
      // Achieved anchor SNR 20 @ 480s (no improvement curve).
      await mastersDao.updateSmartFields(
        masterId,
        targetSnr: 20.0,
        targetIntegrationS: 480.0,
      );

      // Every sub here carries a null weight: dropping those empties the fold
      // set and the push becomes a no-op.
      final result = await service.pushDeficitToScheduler(masterId, 40.0);
      expect(result.applied, isTrue);
      expect(result.currentSnr, closeTo(20.0, 1e-9));
      expect(result.perFilter.single.deltaFrames, 12);
    });
  });

  // MasterAccumulationService persists native per-frame weights

  test(
    'addNight persists native per-frame weights so best-night has real data',
    () async {
      // Exercise the fold-record persistence directly through the DAO using the
      // weights the native add now surfaces (frameWeights). bestNight must then
      // report the true mean weight, not 0.
      final targetId = await insertTarget('M51');
      final masterId = await insertMaster(targetId: targetId);
      final cap = DateTime.utc(2026, 6, 1, 23);
      final a = await insertSub(targetId: targetId, capturedAt: cap);
      final b = await insertSub(targetId: targetId, capturedAt: cap);
      // Simulate MasterAccumulationService.addNight writing native weights.
      final frameWeights = <double>[0.8, 1.0];
      final ids = [a, b];
      for (var i = 0; i < ids.length; i++) {
        final w = frameWeights[i];
        await mastersDao.recordFoldedFrame(
          masterId: masterId,
          imageId: ids[i],
          weight: w > 0 ? w : null,
          accepted: true,
        );
      }

      final best = await service.bestNight(masterId);
      expect(best, isNotNull);
      expect(best!.frameCount, 2);
      expect(best.meanWeight, closeTo(0.9, 1e-9));
    },
  );
}
