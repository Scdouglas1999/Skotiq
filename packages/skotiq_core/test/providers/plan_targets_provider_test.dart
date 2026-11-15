import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart' show IntegrationGoal, Project;
import 'package:skotiq_core/providers.dart'
    show
        PlanTarget,
        allDbImagesProvider,
        allDbTargetsProvider,
        allSessionsProvider,
        autopilotRemovedTargetIdsProvider,
        groupMembersProvider,
        integrationGoalsStreamProvider,
        planTargetsProvider,
        projectListProvider;
import 'package:skotiq_core/src/database/database.dart' as db;

db.DbTarget _target(int id, String name) => db.DbTarget(
  id: id,
  name: name,
  ra: 2.37,
  dec: 42.3,
  minAltitude: 30.0,
  priority: 5,
  totalPlannedSubs: 0,
  capturedSubs: 0,
  totalIntegrationSecs: 0.0,
  goalIntegrationSecs: 0.0,
  createdAt: DateTime(2026, 11, 3),
  updatedAt: DateTime(2026, 11, 3),
  isFavorite: false,
);

db.DbCapturedImage _frame(
  int id,
  int targetId, {
  String type = 'light',
  bool accepted = true,
  double seconds = 180,
  String filter = 'L',
}) => db.DbCapturedImage(
  id: id,
  filePath: '/captures/$id.fits',
  fileName: '$id.fits',
  fileFormat: 'fits',
  sessionId: 1,
  targetId: targetId,
  frameType: type,
  exposureDuration: seconds,
  binX: 1,
  binY: 1,
  filter: filter,
  isPlateSolved: false,
  capturedAt: DateTime(2026, 11, 3, 21).add(Duration(minutes: 4 * id)),
  createdAt: DateTime(2026, 11, 3, 21),
  isAccepted: accepted,
);

final _fall = Project(
  id: 7,
  name: 'Fall galaxies',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
);

Future<List<PlanTarget>> _read(ProviderContainer container) async {
  final sub = container.listen(planTargetsProvider, (_, __) {});
  addTearDown(sub.close);
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
    final rows = container.read(planTargetsProvider).valueOrNull;
    if (rows != null) return rows;
  }
  fail('planTargetsProvider never produced rows');
}

/// Plan > Projects showed "0s / 0s" for a target Analytics and the Darkroom
/// showed 31.9 h for, because it counted only toward a goal. The row counts
/// the accepted light frames whether or not a goal is set.
void main() {
  ProviderContainer container({
    List<IntegrationGoal> goals = const [],
    Set<int> removed = const {},
  }) {
    final c = ProviderContainer(
      overrides: [
        allDbTargetsProvider.overrideWith(
          (ref) => Stream.value([_target(1, 'NGC0891'), _target(2, 'M74')]),
        ),
        allSessionsProvider.overrideWith((ref) => Stream.value(const [])),
        allDbImagesProvider.overrideWith(
          (ref) => Stream.value([
            for (var i = 0; i < 10; i++) _frame(i + 1, 1),
            _frame(11, 1, accepted: false),
            _frame(12, 1, type: 'dark'),
            _frame(13, 2, seconds: 60, filter: 'R'),
          ]),
        ),
        integrationGoalsStreamProvider.overrideWith(
          (ref) => Stream.value(goals),
        ),
        projectListProvider.overrideWith((ref) => Stream.value([_fall])),
        groupMembersProvider.overrideWith(
          (ref) async => {
            7: {2},
          },
        ),
        autopilotRemovedTargetIdsProvider.overrideWith((ref) async => removed),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a target with no goal still shows what was integrated', () async {
    final rows = await _read(container());
    final ngc = rows.singleWhere((r) => r.name == 'NGC0891');

    // Ten accepted lights of 180 s; the rejected light and the dark are out.
    expect(ngc.integratedSecs, 1800);
    expect(ngc.progress.acceptedFrames, 10);
    expect(ngc.progress.isTracked, isFalse);
  });

  test('with a goal the same frames count toward it', () async {
    final rows = await _read(
      container(
        goals: [
          IntegrationGoal(
            id: 1,
            targetId: 1,
            filter: 'L',
            exposureSeconds: 180,
            frameCount: 40,
            createdAt: DateTime.utc(2026, 11, 3),
          ),
        ],
      ),
    );
    final ngc = rows.singleWhere((r) => r.name == 'NGC0891');

    expect(ngc.integratedSecs, 1800);
    expect(ngc.progress.goal.goalSecs, 7200);
    expect(ngc.progress.completionFraction, 0.25);
  });

  test('a row carries its groups and whether the autopilot may pick it',
      () async {
    final rows = await _read(container(removed: {1}));
    final ngc = rows.singleWhere((r) => r.name == 'NGC0891');
    final m74 = rows.singleWhere((r) => r.name == 'M74');

    expect(ngc.groups, isEmpty);
    expect(ngc.inAutopilot, isFalse);
    expect(m74.groups.single.name, 'Fall galaxies');
    expect(m74.inGroup(7), isTrue);
    expect(m74.inAutopilot, isTrue);
  });
}
