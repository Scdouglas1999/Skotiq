import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/stack_and_share_models.dart';
import 'package:skotiq_core/src/services/stack_light_selector.dart';

/// C5 — Light-frame auto-selection service.
///
/// Seeds an in-memory [SkotiqDatabase] with a mix of frame types and
/// qualities and asserts the pure selection logic in [StackLightSelector]:
/// lights-only, accepted gate, quality threshold, reference picking, per-filter
/// counts, integration totals, target-name resolution, and the loud
/// [NoLightsToStackException] when nothing qualifies.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late SessionsDao sessionsDao;
  late TargetsDao targetsDao;
  late StackLightSelector selector;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = ImagesDao(db);
    sessionsDao = SessionsDao(db);
    targetsDao = TargetsDao(db);
    selector = StackLightSelector(
      imagesDao: imagesDao,
      sessionsDao: sessionsDao,
      targetsDao: targetsDao,
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// Inserts a target and returns its id.
  Future<int> seedTarget({String name = 'M42'}) {
    return targetsDao.createTarget(
      TargetsCompanion.insert(name: name, ra: 5.5, dec: -5.4),
    );
  }

  /// Inserts a session and returns its id.
  Future<int> seedSession({int? targetId}) {
    return sessionsDao.createSession(
      ImagingSessionsCompanion.insert(
        startTime: DateTime.utc(2026, 1, 1, 22),
        targetId: Value(targetId),
      ),
    );
  }

  /// Inserts a captured frame and returns its row id.
  Future<int> seedFrame({
    int? sessionId,
    int? targetId,
    String frameType = 'light',
    String? filter,
    double exposureDuration = 60.0,
    double? qualityScore,
    double? hfr,
    bool isAccepted = true,
    required DateTime capturedAt,
    String fileName = 'frame.fits',
  }) {
    return imagesDao.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/data/$fileName',
        fileName: fileName,
        sessionId: Value(sessionId),
        targetId: Value(targetId),
        frameType: Value(frameType),
        exposureDuration: exposureDuration,
        filter: Value(filter),
        qualityScore: Value(qualityScore),
        hfr: Value(hfr),
        isAccepted: Value(isAccepted),
        capturedAt: capturedAt,
      ),
    );
  }

  group('selectForSession', () {
    test('keeps lights only, honours accepted + quality gates', () async {
      final targetId = await seedTarget();
      final sessionId = await seedSession(targetId: targetId);

      // 3 qualifying lights (varied filters + scores).
      final l1Id = await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        qualityScore: 80,
        hfr: 2.5,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
        fileName: 'l1.fits',
      );
      final bestId = await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        qualityScore: 95,
        hfr: 2.0,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 5),
        fileName: 'l2_best.fits',
      );
      final haId = await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'Ha',
        qualityScore: 70,
        hfr: 3.0,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 10),
        fileName: 'ha1.fits',
      );

      // A dark and a flat — must be ignored entirely.
      await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        frameType: 'dark',
        qualityScore: 99,
        capturedAt: DateTime.utc(2026, 1, 1, 23, 0),
        fileName: 'dark.fits',
      );
      await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        frameType: 'flat',
        capturedAt: DateTime.utc(2026, 1, 1, 23, 5),
        fileName: 'flat.fits',
      );

      // A rejected light — dropped because rejectUnaccepted defaults true.
      await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        qualityScore: 90,
        isAccepted: false,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 15),
        fileName: 'rejected.fits',
      );

      // A low-quality light — dropped by the threshold.
      await seedFrame(
        sessionId: sessionId,
        targetId: targetId,
        filter: 'L',
        qualityScore: 20,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 20),
        fileName: 'lowq.fits',
      );

      final summary = await selector.selectForSession(
        sessionId: sessionId,
        config: const StackAndShareConfig(minQualityScore: 50),
      );

      // Lights-only, both gates honoured: exactly the 3 qualifying lights.
      expect(summary.selectedCount, 3);
      expect(summary.selected.map((s) => s.imageId).toSet(), {
        l1Id,
        bestId,
        haId,
      });

      // Excluded carries the rejected + low-quality lights (not darks/flats).
      expect(summary.excludedCount, 2);

      // Reference is the best-quality frame (95 score, lowest hfr).
      expect(summary.selected.firstWhere((s) => s.isReference).imageId, bestId);
      expect(summary.referencePath, '/data/l2_best.fits');

      // Per-filter counts: 2 L + 1 Ha.
      expect(summary.perFilterCounts, {'L': 2, 'Ha': 1});

      // Integration = 3 frames x 60s.
      expect(summary.totalIntegrationSecs, 180.0);

      // Each survivor also carries its OWN exposure. The stacker can refuse
      // individual subs, so the run has to be able to total the time that
      // actually made it into the master — the selection-wide figure above is
      // fixed before the engine has seen a frame.
      expect(
        summary.selected.map((s) => s.exposureSecs).toList(),
        everyElement(60.0),
      );

      // Target name resolved through the session's targetId.
      expect(summary.targetName, 'M42');
    });

    test(
      'reference tie-breaks on hfr then capturedAt when scores tie',
      () async {
        final sessionId = await seedSession();

        // Three lights, all score 90. The winner should be the lowest-hfr one.
        await seedFrame(
          sessionId: sessionId,
          filter: 'L',
          qualityScore: 90,
          hfr: 3.2,
          capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
          fileName: 'a.fits',
        );
        final lowestHfrId = await seedFrame(
          sessionId: sessionId,
          filter: 'L',
          qualityScore: 90,
          hfr: 2.1,
          capturedAt: DateTime.utc(2026, 1, 1, 22, 5),
          fileName: 'b.fits',
        );
        await seedFrame(
          sessionId: sessionId,
          filter: 'L',
          qualityScore: 90,
          hfr: 2.8,
          capturedAt: DateTime.utc(2026, 1, 1, 22, 10),
          fileName: 'c.fits',
        );

        final summary = await selector.selectForSession(
          sessionId: sessionId,
          config: const StackAndShareConfig(),
        );

        expect(
          summary.selected.firstWhere((s) => s.isReference).imageId,
          lowestHfrId,
        );
      },
    );

    test('graded frame outranks ungraded frame as reference', () async {
      final sessionId = await seedSession();

      final gradedId = await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: 60,
        hfr: 3.0,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
        fileName: 'graded.fits',
      );
      // Ungraded (null score) but tighter stars + newer — still loses, because
      // a measured score outranks an absent one.
      await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: null,
        hfr: 1.5,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 30),
        fileName: 'ungraded.fits',
      );

      final summary = await selector.selectForSession(
        sessionId: sessionId,
        config: const StackAndShareConfig(),
      );

      // Both survive (null score is admitted), graded is the reference.
      expect(summary.selectedCount, 2);
      expect(
        summary.selected.firstWhere((s) => s.isReference).imageId,
        gradedId,
      );
    });

    test('null-score frames are admitted (never silently scored)', () async {
      final sessionId = await seedSession();
      await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: null,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
      );

      final summary = await selector.selectForSession(
        sessionId: sessionId,
        config: const StackAndShareConfig(minQualityScore: 50),
      );
      expect(summary.selectedCount, 1);
      expect(summary.excludedCount, 0);
    });

    test('rejectUnaccepted=false keeps not-accepted lights', () async {
      final sessionId = await seedSession();
      await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: 80,
        isAccepted: false,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
      );

      final summary = await selector.selectForSession(
        sessionId: sessionId,
        config: const StackAndShareConfig(rejectUnaccepted: false),
      );
      expect(summary.selectedCount, 1);
    });

    test('frames with no filter group under the "(none)" bucket', () async {
      final sessionId = await seedSession();
      await seedFrame(
        sessionId: sessionId,
        filter: null,
        qualityScore: 80,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
        fileName: 'nofilter.fits',
      );
      await seedFrame(
        sessionId: sessionId,
        filter: '   ', // whitespace also collapses to the (none) bucket.
        qualityScore: 82,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 5),
        fileName: 'blank.fits',
      );

      final summary = await selector.selectForSession(
        sessionId: sessionId,
        config: const StackAndShareConfig(),
      );
      expect(summary.perFilterCounts, {StackLightSelector.noFilterBucket: 2});
    });

    test('throws NoLightsToStackException when no light qualifies', () async {
      final sessionId = await seedSession();
      // Only non-lights + a rejected + a low-quality light.
      await seedFrame(
        sessionId: sessionId,
        frameType: 'dark',
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
        fileName: 'dark.fits',
      );
      await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: 90,
        isAccepted: false,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 5),
        fileName: 'rej.fits',
      );
      await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: 10,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 10),
        fileName: 'low.fits',
      );

      expect(
        () => selector.selectForSession(
          sessionId: sessionId,
          config: const StackAndShareConfig(minQualityScore: 50),
        ),
        throwsA(
          isA<NoLightsToStackException>()
              .having((e) => e.framesExamined, 'framesExamined', 3)
              .having((e) => e.lightsExcluded, 'lightsExcluded', 2),
        ),
      );
    });

    test('throws StateError for a missing session', () async {
      expect(
        () => selector.selectForSession(
          sessionId: 999,
          config: const StackAndShareConfig(),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('targetName is null when the session has no target', () async {
      final sessionId = await seedSession();
      await seedFrame(
        sessionId: sessionId,
        filter: 'L',
        qualityScore: 80,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
      );

      final summary = await selector.selectForSession(
        sessionId: sessionId,
        config: const StackAndShareConfig(),
      );
      expect(summary.targetName, isNull);
    });
  });

  group('selectForTarget', () {
    test('selects across the target and resolves the target name', () async {
      final targetId = await seedTarget(name: 'NGC 7000');
      final sessionA = await seedSession(targetId: targetId);
      final sessionB = await seedSession(targetId: targetId);

      await seedFrame(
        sessionId: sessionA,
        targetId: targetId,
        filter: 'L',
        qualityScore: 75,
        hfr: 2.6,
        exposureDuration: 120,
        capturedAt: DateTime.utc(2026, 1, 1, 22, 0),
        fileName: 'a.fits',
      );
      final bestId = await seedFrame(
        sessionId: sessionB,
        targetId: targetId,
        filter: 'L',
        qualityScore: 92,
        hfr: 2.0,
        exposureDuration: 120,
        capturedAt: DateTime.utc(2026, 1, 2, 22, 0),
        fileName: 'b_best.fits',
      );

      final summary = await selector.selectForTarget(
        targetId: targetId,
        config: const StackAndShareConfig(),
      );

      expect(summary.selectedCount, 2);
      expect(summary.totalIntegrationSecs, 240.0);
      expect(summary.targetName, 'NGC 7000');
      expect(summary.selected.firstWhere((s) => s.isReference).imageId, bestId);
    });

    test('throws StateError for a missing target', () async {
      expect(
        () => selector.selectForTarget(
          targetId: 12345,
          config: const StackAndShareConfig(),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('exclusionReasonFor', () {
    test('derives the per-frame reason matching the gate order', () async {
      const config = StackAndShareConfig(minQualityScore: 50);

      final rejected = CapturedImage(
        id: 1,
        filePath: '/x',
        fileName: 'x',
        fileFormat: 'fits',
        frameType: 'light',
        exposureDuration: 60,
        binX: 1,
        binY: 1,
        isPlateSolved: false,
        capturedAt: DateTime.utc(2026, 1, 1),
        createdAt: DateTime.utc(2026, 1, 1),
        isAccepted: false,
        qualityScore:
            10, // also below threshold, but rejected wins (gate order)
      );
      expect(
        StackLightSelector.exclusionReasonFor(rejected, config),
        StackExclusionReason.rejected,
      );

      final lowQuality = CapturedImage(
        id: 2,
        filePath: '/y',
        fileName: 'y',
        fileFormat: 'fits',
        frameType: 'light',
        exposureDuration: 60,
        binX: 1,
        binY: 1,
        isPlateSolved: false,
        capturedAt: DateTime.utc(2026, 1, 1),
        createdAt: DateTime.utc(2026, 1, 1),
        isAccepted: true,
        qualityScore: 20,
      );
      expect(
        StackLightSelector.exclusionReasonFor(lowQuality, config),
        StackExclusionReason.lowQuality,
      );

      final kept = lowQuality.copyWith(qualityScore: const Value(80));
      expect(StackLightSelector.exclusionReasonFor(kept, config), isNull);

      final dark = kept.copyWith(
        frameType: 'dark',
        qualityScore: const Value(1),
      );
      expect(StackLightSelector.exclusionReasonFor(dark, config), isNull);
    });
  });
}
