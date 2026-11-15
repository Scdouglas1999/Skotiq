import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/targets/darkroom_targets_model.dart';
import 'package:skotiq_app/screens/planner/targets/plan_targets_tab.dart';
import 'package:skotiq_core/database.dart' as ndb;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import 'plan_targets_test_support.dart';

ndb.DbTarget _target(int id, String name) => ndb.DbTarget(
      id: id,
      name: name,
      objectType: 'Galaxy',
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

ndb.DbCapturedImage _frame(
  int id,
  int targetId, {
  String type = 'light',
  bool accepted = true,
  double seconds = 180,
}) =>
    ndb.DbCapturedImage(
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
      filter: 'L',
      isPlateSolved: false,
      capturedAt: DateTime(2026, 11, 3, 21).add(Duration(minutes: 4 * id)),
      createdAt: DateTime(2026, 11, 3, 21),
      isAccepted: accepted,
    );

final _ngc = _target(1, 'NGC0891');
final _m74 = _target(2, 'M74');

/// 638 accepted 180 s lights of NGC0891 (31.9 h), two rejected, one dark, and
/// one 60 s light of M74.
final _frames = [
  for (var i = 0; i < 638; i++) _frame(i + 1, 1),
  _frame(700, 1, accepted: false),
  _frame(701, 1, accepted: false),
  _frame(702, 1, type: 'dark'),
  _frame(800, 2, seconds: 60),
];

final _fall = Project(
  id: 7,
  name: 'Fall galaxies',
  createdAt: DateTime.utc(2026, 11, 1),
  updatedAt: DateTime.utc(2026, 11, 1),
);

List<Override> _overrides({
  List<ndb.DbTarget>? targets,
  List<Project> groups = const [],
}) =>
    [
      inMemoryDatabaseOverride(),
      allDbTargetsProvider.overrideWith(
        (ref) => Stream.value(targets ?? [_ngc, _m74]),
      ),
      allDbImagesProvider.overrideWith(
        (ref) => Stream.value(targets == null ? _frames : const []),
      ),
      projectListProvider.overrideWith((ref) => Stream.value(groups)),
      groupMembersProvider.overrideWith(
        (ref) async => {
          for (final g in groups) g.id!: {2},
        },
      ),
      ...planTargetsTabOverrides(),
    ];

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<ndb.DbTarget>? targets,
  List<Project> groups = const [],
  Size size = const Size(1400, 900),
  String? initialGroup,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(targets: targets, groups: groups),
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: PlanTargetsTab(initialGroup: initialGroup)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(PlanTargetsTab)),
  );
}

void _expectNoLayoutError(WidgetTester tester) {
  final error = tester.takeException();
  expect(
    error,
    isNull,
    reason: error is FlutterError ? error.toStringDeep() : '$error',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a target with no goal shows the hours the Darkroom shows, not 0s / 0s',
      (tester) async {
    final container = await _pump(tester);

    final row = container
        .read(planTargetsProvider)
        .requireValue
        .singleWhere((t) => t.name == 'NGC0891');
    final darkroom = buildDarkroomTargets(
      framesByTarget: {
        'NGC0891': [
          for (final f in _frames)
            if (f.targetId == 1 && f.frameType == 'light') f,
        ],
      },
      masters: const [],
      targetRows: [_ngc],
      foldedByMaster: const {},
    ).single;

    expect(row.integratedSecs, darkroom.keptSeconds);
    expect(row.integratedSecs, 638 * 180);
    // Listed and, as the first row, opened beside the list.
    expect(find.text('31.9h · no goal'), findsOneWidget);
    expect(find.textContaining('0s / 0s'), findsNothing);
  });

  testWidgets('choosing a group narrows the list and the autopilot to it',
      (tester) async {
    final container = await _pump(tester, groups: [_fall]);
    expect(find.byKey(const ValueKey('plan-target-row-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-target-row-2')), findsOneWidget);
    expect(container.read(activeProjectIdProvider), isNull);

    await tester.tap(find.byKey(const ValueKey('plan-targets-group-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fall galaxies').last);
    await tester.pumpAndSettle();

    // The autopilot's candidates are scoped by the active group.
    expect(container.read(activeProjectIdProvider), 7);
    expect(find.byKey(const ValueKey('plan-target-row-1')), findsNothing);
    expect(find.byKey(const ValueKey('plan-target-row-2')), findsOneWidget);
    expect(find.text('Autopilot · Fall galaxies'), findsOneWidget);
  });

  testWidgets('with no targets the tab shows one way forward and no filters',
      (tester) async {
    await _pump(tester, targets: const []);

    expect(find.text('No targets yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-targets-add-first')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-targets-search')), findsNothing);
    expect(find.byKey(const ValueKey('plan-targets-sort-chip')), findsNothing);
  });

  testWidgets('a link to the mosaics group opens the mosaics', (tester) async {
    await _pump(tester, initialGroup: 'mosaics');

    expect(find.text('No mosaics yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-targets-new-mosaic')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-target-row-1')), findsNothing);
  });

  testWidgets('at phone width every row keeps its name and nothing overflows',
      (tester) async {
    await _pump(tester, size: const Size(390, 844));

    expect(find.text('NGC0891'), findsOneWidget);
    expect(find.text('M74'), findsOneWidget);
    expect(find.text('31.9h · no goal'), findsOneWidget);
    _expectNoLayoutError(tester);
    // A row opens the target over the list.
    await tester.tap(find.text('NGC0891'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-target-back')), findsOneWidget);
    expect(find.text('Goals'), findsOneWidget);
    _expectNoLayoutError(tester);
  });
}
