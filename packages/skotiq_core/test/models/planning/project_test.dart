import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/planning/project.dart';
import 'package:skotiq_core/src/models/planning/project_progress.dart';

void main() {
  group('Project.fromRow', () {
    test('converts Unix seconds to DateTime and round-trips fields', () {
      // 2026-05-30T00:00:00Z and an hour later, expressed in Unix seconds.
      const createdUnix = 1780099200; // 2026-05-30T12:00:00Z (illustrative)
      const updatedUnix = createdUnix + 3600;

      final project = Project.fromRow(
        id: 7,
        name: 'Winter Nebulae',
        description: 'Orion + Horsehead campaign',
        colorArgb: 0xFF5B9EC4,
        createdAtUnix: createdUnix,
        updatedAtUnix: updatedUnix,
      );

      expect(project.id, 7);
      expect(project.name, 'Winter Nebulae');
      expect(project.description, 'Orion + Horsehead campaign');
      expect(project.colorArgb, 0xFF5B9EC4);
      expect(project.createdAt.millisecondsSinceEpoch, createdUnix * 1000);
      expect(project.updatedAt.millisecondsSinceEpoch, updatedUnix * 1000);
    });

    test('accepts null description and color', () {
      final project = Project.fromRow(
        id: 1,
        name: 'Galaxy Season',
        createdAtUnix: 1000,
        updatedAtUnix: 2000,
      );
      expect(project.description, isNull);
      expect(project.colorArgb, isNull);
    });
  });

  group('Project equality, copyWith, JSON', () {
    Project sample() => Project(
      id: 3,
      name: 'P',
      description: 'd',
      colorArgb: 0xFFFFFFFF,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
    );

    test('value equality and hashCode', () {
      expect(sample(), equals(sample()));
      expect(sample().hashCode, sample().hashCode);
      expect(sample() == sample().copyWith(name: 'Q'), isFalse);
    });

    test('copyWith overrides and clear flags', () {
      final base = sample();
      final renamed = base.copyWith(name: 'Renamed');
      expect(renamed.name, 'Renamed');
      expect(renamed.description, 'd');

      final cleared = base.copyWith(clearDescription: true, clearColor: true);
      expect(cleared.description, isNull);
      expect(cleared.colorArgb, isNull);
      // Clear takes precedence over a provided value.
      final clearedWins = base.copyWith(
        description: 'ignored',
        clearDescription: true,
      );
      expect(clearedWins.description, isNull);
    });

    test('toJson serializes timestamps as ISO-8601 UTC', () {
      final json = sample().toJson();
      expect(json['id'], 3);
      expect(json['name'], 'P');
      expect(json['colorArgb'], 0xFFFFFFFF);
      expect(
        json['createdAt'],
        DateTime.fromMillisecondsSinceEpoch(
          1000 * 1000,
        ).toUtc().toIso8601String(),
      );
    });
  });

  group('ProjectTarget', () {
    test('fromRow converts Unix seconds and round-trips', () {
      final pt = ProjectTarget.fromRow(
        id: 5,
        projectId: 2,
        targetId: 99,
        priorityOverride: 8,
        addedAtUnix: 4242,
      );
      expect(pt.id, 5);
      expect(pt.projectId, 2);
      expect(pt.targetId, 99);
      expect(pt.priorityOverride, 8);
      expect(pt.addedAt.millisecondsSinceEpoch, 4242 * 1000);
    });

    test('null priorityOverride means inherit target priority', () {
      final pt = ProjectTarget.fromRow(
        id: 1,
        projectId: 1,
        targetId: 1,
        addedAtUnix: 0,
      );
      expect(pt.priorityOverride, isNull);
    });

    test('copyWith clearPriorityOverride wins over provided value', () {
      final pt = ProjectTarget(
        projectId: 1,
        targetId: 1,
        priorityOverride: 9,
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final cleared = pt.copyWith(
        priorityOverride: 3,
        clearPriorityOverride: true,
      );
      expect(cleared.priorityOverride, isNull);
    });

    test('equality and JSON', () {
      final a = ProjectTarget(
        id: 1,
        projectId: 2,
        targetId: 3,
        priorityOverride: 4,
        addedAt: DateTime.fromMillisecondsSinceEpoch(5000),
      );
      final b = ProjectTarget(
        id: 1,
        projectId: 2,
        targetId: 3,
        priorityOverride: 4,
        addedAt: DateTime.fromMillisecondsSinceEpoch(5000),
      );
      expect(a, equals(b));
      final json = a.toJson();
      expect(json['projectId'], 2);
      expect(json['targetId'], 3);
      expect(json['priorityOverride'], 4);
    });
  });

  group('FilterProgressLine', () {
    test('accrued/goal seconds and remaining frames', () {
      const line = FilterProgressLine(
        filter: 'Ha',
        exposureSeconds: 300,
        goalFrames: 20,
        capturedFrames: 8,
      );
      expect(line.accruedSeconds, 8 * 300.0);
      expect(line.goalSeconds, 20 * 300.0);
      expect(line.remainingFrames, 12);
      expect(line.isComplete, isFalse);
    });

    test('over-capture clamps remaining frames to zero and is complete', () {
      const line = FilterProgressLine(
        filter: 'L',
        exposureSeconds: 60,
        goalFrames: 10,
        capturedFrames: 15,
      );
      expect(line.remainingFrames, 0);
      expect(line.isComplete, isTrue);
    });

    test('JSON round-trip shape', () {
      const line = FilterProgressLine(
        filter: 'O3',
        exposureSeconds: 120,
        goalFrames: 5,
        capturedFrames: 2,
      );
      final json = line.toJson();
      expect(json['filter'], 'O3');
      expect(json['exposureSeconds'], 120);
      expect(json['goalFrames'], 5);
      expect(json['capturedFrames'], 2);
      expect(json['remainingFrames'], 3);
      expect(json['accruedSeconds'], 240.0);
      expect(json['goalSeconds'], 600.0);
    });
  });

  group('ProjectTargetProgress', () {
    ProjectTargetProgress build(List<FilterProgressLine> filters) =>
        ProjectTargetProgress(
          targetId: 1,
          targetName: 'M31',
          raHours: 0.712,
          decDegrees: 41.27,
          filters: filters,
        );

    test('aggregates accrued/goal/remaining across filters', () {
      final p = build(const [
        FilterProgressLine(
          filter: 'L',
          exposureSeconds: 60,
          goalFrames: 10,
          capturedFrames: 5,
        ),
        FilterProgressLine(
          filter: 'R',
          exposureSeconds: 120,
          goalFrames: 5,
          capturedFrames: 0,
        ),
      ]);
      // L: accrued 300, goal 600. R: accrued 0, goal 600.
      expect(p.accruedSeconds, 300.0);
      expect(p.goalSeconds, 1200.0);
      expect(p.remainingSeconds, 900.0);
      expect(p.percentComplete, closeTo(0.25, 1e-9));
      expect(p.isComplete, isFalse);
    });

    test('percentComplete clamps to 1.0 when over-captured', () {
      final p = build(const [
        FilterProgressLine(
          filter: 'L',
          exposureSeconds: 60,
          goalFrames: 10,
          capturedFrames: 30,
        ),
      ]);
      expect(p.percentComplete, 1.0);
      expect(p.remainingSeconds, 0.0);
      expect(p.isComplete, isTrue);
    });

    test('goalSeconds == 0 is not complete (inert / unconfigured)', () {
      final p = build(const [
        FilterProgressLine(
          filter: 'L',
          exposureSeconds: 60,
          goalFrames: 0,
          capturedFrames: 0,
        ),
      ]);
      expect(p.goalSeconds, 0.0);
      expect(p.percentComplete, 0.0);
      expect(p.isComplete, isFalse);
    });

    test('no filters at all is not complete', () {
      final p = build(const []);
      expect(p.goalSeconds, 0.0);
      expect(p.percentComplete, 0.0);
      expect(p.isComplete, isFalse);
    });

    test('exactly met goal is complete with zero remaining', () {
      final p = build(const [
        FilterProgressLine(
          filter: 'L',
          exposureSeconds: 60,
          goalFrames: 10,
          capturedFrames: 10,
        ),
      ]);
      expect(p.remainingSeconds, 0.0);
      expect(p.percentComplete, 1.0);
      expect(p.isComplete, isTrue);
    });

    test('JSON round-trip shape', () {
      final p = build(const [
        FilterProgressLine(
          filter: 'L',
          exposureSeconds: 60,
          goalFrames: 10,
          capturedFrames: 5,
        ),
      ]);
      final json = p.toJson();
      expect(json['targetId'], 1);
      expect(json['targetName'], 'M31');
      expect(json['raHours'], 0.712);
      expect(json['decDegrees'], 41.27);
      expect((json['filters'] as List).length, 1);
      expect(json['accruedSeconds'], 300.0);
      expect(json['goalSeconds'], 600.0);
      expect(json['isComplete'], false);
    });
  });

  group('CampaignProgress', () {
    Project proj() => Project(
      id: 1,
      name: 'Campaign',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );

    ProjectTargetProgress target({
      required int id,
      required int goalFrames,
      required int capturedFrames,
    }) => ProjectTargetProgress(
      targetId: id,
      targetName: 'T$id',
      raHours: 0,
      decDegrees: 0,
      filters: [
        FilterProgressLine(
          filter: 'L',
          exposureSeconds: 60,
          goalFrames: goalFrames,
          capturedFrames: capturedFrames,
        ),
      ],
    );

    test('totals, counts, and incompleteTargets filter', () {
      final complete = target(id: 1, goalFrames: 10, capturedFrames: 10);
      final partial = target(id: 2, goalFrames: 10, capturedFrames: 4);
      final inert = target(id: 3, goalFrames: 0, capturedFrames: 0);

      final progress = CampaignProgress(
        project: proj(),
        targets: [complete, partial, inert],
      );

      expect(progress.totalTargets, 3);
      expect(progress.completeTargets, 1);

      // accrued: 600 + 240 + 0 = 840; goal: 600 + 600 + 0 = 1200.
      expect(progress.totalAccruedSeconds, 840.0);
      expect(progress.totalGoalSeconds, 1200.0);
      expect(progress.totalRemainingSeconds, 360.0);
      expect(progress.totalPercentComplete, closeTo(0.7, 1e-9));

      final incomplete = progress.incompleteTargets;
      // partial + inert are incomplete; complete is excluded.
      expect(incomplete.map((t) => t.targetId), [2, 3]);
    });

    test('empty project reports zero progress without dividing by zero', () {
      final progress = CampaignProgress(project: proj(), targets: const []);
      expect(progress.totalTargets, 0);
      expect(progress.completeTargets, 0);
      expect(progress.totalGoalSeconds, 0.0);
      expect(progress.totalPercentComplete, 0.0);
      expect(progress.incompleteTargets, isEmpty);
    });

    test('over-captured project clamps totalPercentComplete to 1.0', () {
      final over = target(id: 1, goalFrames: 10, capturedFrames: 50);
      final progress = CampaignProgress(project: proj(), targets: [over]);
      expect(progress.totalPercentComplete, 1.0);
      expect(progress.totalRemainingSeconds, 0.0);
    });

    test('JSON round-trip shape', () {
      final progress = CampaignProgress(
        project: proj(),
        targets: [target(id: 1, goalFrames: 10, capturedFrames: 5)],
      );
      final json = progress.toJson();
      expect(json['project'], isA<Map<String, dynamic>>());
      expect((json['targets'] as List).length, 1);
      expect(json['totalTargets'], 1);
      expect(json['totalAccruedSeconds'], 300.0);
      expect(json['totalGoalSeconds'], 600.0);
    });
  });
}
