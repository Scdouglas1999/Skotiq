// Tests for TargetProgressService — per-target progress + ETA computation.
//
// Setup: in-memory drift DB with one target, two integration goals, and a
// hand-crafted set of accepted-light frames in `captured_images` placed at
// known local-time instants. A fixed clock keeps the rolling-window logic
// deterministic across test runs and CI timezones.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/services/scheduler/integration_goal_service.dart';
import 'package:skotiq_core/src/services/scheduler/target_progress_service.dart';

void main() {
  late SkotiqDatabase database;
  late IntegrationGoalService goalService;
  late TargetProgressService progressService;

  // Fixed "now" for the rolling-window window. May 12, 10:00 local — the
  // last night-start before this is May 11 noon, so the 7-night window
  // opens at May 4 noon (local).
  final fixedNow = DateTime(2026, 5, 12, 10, 0);
  DateTime clock() => fixedNow;

  late int targetId;
  late DateTime goalCreatedAt;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    goalService = IntegrationGoalService(database);
    progressService = TargetProgressService(
      database: database,
      goalService: goalService,
      clock: clock,
    );

    targetId = await database
        .into(database.targets)
        .insert(TargetsCompanion.insert(name: 'M31', ra: 0.7, dec: 41.3));

    goalCreatedAt = DateTime.utc(2026, 1, 1);
    // Lum @ 60s × 100 frames, Ha @ 300s × 50 frames.
    await goalService.upsert(
      IntegrationGoal(
        targetId: targetId,
        filter: 'Lum',
        exposureSeconds: 60.0,
        frameCount: 100,
        priority: 5,
        createdAt: goalCreatedAt,
      ),
    );
    await goalService.upsert(
      IntegrationGoal(
        targetId: targetId,
        filter: 'Ha',
        exposureSeconds: 300.0,
        frameCount: 50,
        priority: 7,
        createdAt: goalCreatedAt,
      ),
    );
  });

  tearDown(() async {
    await database.close();
  });

  /// Insert [count] accepted light frames of [filter] all stamped at
  /// [capturedAt]. Returns the target_id used for convenience.
  Future<void> insertCaptures({
    required String filter,
    required int count,
    required DateTime capturedAt,
    double exposureSeconds = 60.0,
  }) async {
    for (var i = 0; i < count; i++) {
      await database
          .into(database.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: 'frame_${filter}_$i.fits',
              fileName: 'frame_${filter}_$i.fits',
              exposureDuration: exposureSeconds,
              capturedAt: capturedAt,
              frameType: const Value('light'),
              targetId: Value(targetId),
              filter: Value(filter),
            ),
          );
    }
  }

  group('forTarget — baseline scenario', () {
    test('30 Lum frames across 3 nights yields 20% complete, 10 frames/night, '
        '12-night ETA', () async {
      // Three distinct noon-to-noon nights inside the 7-night window:
      //   May 7 22:00 -> night starting May 7 noon
      //   May 9 23:00 -> night starting May 9 noon
      //   May 11 02:00 -> night starting May 10 noon
      await insertCaptures(
        filter: 'Lum',
        count: 10,
        capturedAt: DateTime(2026, 5, 7, 22, 0),
      );
      await insertCaptures(
        filter: 'Lum',
        count: 10,
        capturedAt: DateTime(2026, 5, 9, 23, 0),
      );
      await insertCaptures(
        filter: 'Lum',
        count: 10,
        capturedAt: DateTime(2026, 5, 11, 2, 0),
      );

      final progress = await progressService.forTarget(
        targetId: targetId,
        targetName: 'M31',
      );

      expect(progress.totalGoalFrames, 150);
      expect(progress.totalCapturedFrames, 30);
      expect(progress.percentComplete, closeTo(30 / 150, 1e-9));

      expect(progress.perFilter, hasLength(2));
      final lum = progress.perFilter.firstWhere((f) => f.filter == 'Lum');
      expect(lum.capturedFrames, 30);
      expect(lum.goalFrames, 100);
      expect(lum.percentComplete, closeTo(0.3, 1e-9));
      final ha = progress.perFilter.firstWhere((f) => f.filter == 'Ha');
      expect(ha.capturedFrames, 0);
      expect(ha.percentComplete, 0.0);

      expect(progress.avgFramesPerNight, closeTo(10.0, 1e-9));
      // remaining = 150 - 30 = 120; ceil(120 / 10) = 12.
      expect(progress.estimatedNightsRemaining, 12);

      expect(progress.lastImagedAt, isNotNull);
      expect(progress.hasGoals, isTrue);
      expect(progress.hasCaptures, isTrue);
      expect(progress.isComplete, isFalse);
    });
  });

  group('forTarget — edge cases', () {
    test('zero captured frames => estimatedNightsRemaining is null', () async {
      final progress = await progressService.forTarget(
        targetId: targetId,
        targetName: 'M31',
      );

      expect(progress.totalCapturedFrames, 0);
      expect(progress.percentComplete, 0.0);
      expect(progress.avgFramesPerNight, 0.0);
      expect(progress.estimatedNightsRemaining, isNull);
      expect(progress.lastImagedAt, isNull);
      expect(progress.hasCaptures, isFalse);
      expect(progress.isComplete, isFalse);
    });

    test('100% complete => estimatedNightsRemaining is null', () async {
      // Fill both goals: 100 Lum + 50 Ha, spread across three nights so
      // there is a real pace, but the goal is already met.
      await insertCaptures(
        filter: 'Lum',
        count: 100,
        capturedAt: DateTime(2026, 5, 9, 22, 0),
      );
      await insertCaptures(
        filter: 'Ha',
        count: 50,
        capturedAt: DateTime(2026, 5, 10, 22, 0),
        exposureSeconds: 300.0,
      );

      final progress = await progressService.forTarget(
        targetId: targetId,
        targetName: 'M31',
      );

      expect(progress.totalCapturedFrames, 150);
      expect(progress.totalGoalFrames, 150);
      expect(progress.percentComplete, closeTo(1.0, 1e-9));
      expect(progress.isComplete, isTrue);
      expect(
        progress.estimatedNightsRemaining,
        isNull,
        reason: 'no work left, so ETA must be null',
      );
      expect(progress.totalRemainingFrames, 0);
    });

    test(
      'frame captured 8 days ago does not count toward the window',
      () async {
        // Window opens at May 4 noon (local). A capture at May 3 22:00 falls
        // BEFORE that boundary and must be excluded from the avg pace.
        await insertCaptures(
          filter: 'Lum',
          count: 10,
          capturedAt: DateTime(2026, 5, 3, 22, 0),
        );
        // Add one in-window frame so the captured count is nonzero and the
        // ETA branch is exercised.
        await insertCaptures(
          filter: 'Lum',
          count: 5,
          capturedAt: DateTime(2026, 5, 10, 22, 0),
        );

        final progress = await progressService.forTarget(
          targetId: targetId,
          targetName: 'M31',
        );

        // Both batches go into the per-filter total — capturedFrames is
        // lifetime, not windowed.
        expect(progress.totalCapturedFrames, 15);
        // But the rolling-window pace only counts the 5 in-window frames
        // across 1 night = 5/night.
        expect(progress.avgFramesPerNight, closeTo(5.0, 1e-9));
        // remaining = 150 - 15 = 135; ceil(135 / 5) = 27.
        expect(progress.estimatedNightsRemaining, 27);
      },
    );

    test('hasGoals is false when no integration goals exist', () async {
      final emptyTargetId = await database
          .into(database.targets)
          .insert(
            TargetsCompanion.insert(name: 'No-goals', ra: 12.0, dec: 0.0),
          );
      final progress = await progressService.forTarget(
        targetId: emptyTargetId,
        targetName: 'No-goals',
      );
      expect(progress.hasGoals, isFalse);
      expect(progress.totalGoalFrames, 0);
      expect(progress.percentComplete, 0.0);
      expect(progress.estimatedNightsRemaining, isNull);
    });
  });

  group('forTargets — bulk path', () {
    test('returns one entry per requested target', () async {
      final secondId = await database
          .into(database.targets)
          .insert(
            TargetsCompanion.insert(name: 'NGC 7000', ra: 21.0, dec: 44.0),
          );
      await goalService.upsert(
        IntegrationGoal(
          targetId: secondId,
          filter: 'Ha',
          exposureSeconds: 600.0,
          frameCount: 10,
          priority: 5,
          createdAt: goalCreatedAt,
        ),
      );
      await insertCaptures(
        filter: 'Lum',
        count: 5,
        capturedAt: DateTime(2026, 5, 11, 1, 0),
      );

      final result = await progressService.forTargets([
        (id: targetId, name: 'M31'),
        (id: secondId, name: 'NGC 7000'),
      ]);

      expect(result.keys.toSet(), {targetId, secondId});
      expect(result[targetId]!.totalCapturedFrames, 5);
      expect(result[secondId]!.totalGoalFrames, 10);
      expect(result[secondId]!.totalCapturedFrames, 0);
    });
  });

  group('host-backed capturedImages', () {
    test('aggregates from in-memory image list without SQL', () async {
      final capturedAt = DateTime(2026, 5, 11, 1, 0);
      await insertCaptures(filter: 'Lum', count: 2, capturedAt: capturedAt);
      final images = await database.select(database.capturedImages).get();

      final progress = await progressService.forTarget(
        targetId: targetId,
        targetName: 'M31',
        capturedImages: images,
      );

      expect(progress.totalCapturedFrames, 2);
      expect(
        progress.perFilter.firstWhere((f) => f.filter == 'Lum').capturedFrames,
        2,
      );
    });
  });

  group('filter matching is case-insensitive', () {
    test("goal 'Lum' matches capture 'lum'", () async {
      await insertCaptures(
        filter: 'lum',
        count: 7,
        capturedAt: DateTime(2026, 5, 11, 1, 0),
      );
      final progress = await progressService.forTarget(
        targetId: targetId,
        targetName: 'M31',
      );
      final lum = progress.perFilter.firstWhere((f) => f.filter == 'Lum');
      expect(lum.capturedFrames, 7);
    });
  });
}
