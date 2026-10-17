// Binding a Smart Exposure filter plan to a DepthLock goal.
//
// The binding carries the goal's revision, and the revision is the whole
// point: a goal that has been edited since the plan was authored must read as
// stale rather than quietly completing the plan on evidence gathered for a
// different region.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_exposure_properties.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../imaging/depthlock/depthlock_test_doubles.dart';

Future<List<FilterPlan>> _pumpSelector(
  WidgetTester tester, {
  required FakeDepthLockBackend backend,
  required FilterPlan plan,
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final edits = <FilterPlan>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        depthLockBackendProvider.overrideWithValue(backend),
        depthLockEventStreamProvider.overrideWithValue(
          const Stream<SkotiqEvent>.empty(),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: DepthGoalSelector(
              colors: SkotiqColors.dark,
              plan: plan,
              onChanged: edits.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return edits;
}

void main() {
  _nodeSummaryTests();
  _planFromGoalsTests();

  testWidgets('a filter with no goals carries no control', (tester) async {
    final edits = await _pumpSelector(
      tester,
      backend: FakeDepthLockBackend(),
      plan: const FilterPlan(filterName: 'L', count: 20, durationSecs: 300),
    );

    expect(find.text('Depth goal'), findsNothing);
    expect(edits, isEmpty);
  });

  testWidgets('choosing a goal stores its id AND its current revision', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-42',
          revision: 5,
          definition: depthLockDefinitionFixture(label: 'Tidal tail'),
        ),
      ],
    );
    final edits = await _pumpSelector(
      tester,
      backend: backend,
      plan: const FilterPlan(filterName: 'L', count: 20, durationSecs: 300),
    );

    expect(find.text('Depth goal'), findsOneWidget);
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tidal tail · Waiting').last);
    await tester.pumpAndSettle();

    expect(edits, hasLength(1));
    expect(edits.single.depthGoal?.goalId, 'goal-42');
    expect(edits.single.depthGoal?.revision, 5);
  });

  testWidgets('a goal matched case-insensitively still offers itself', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          definition: depthLockDefinitionFixture(filterName: 'Ha'),
        ),
      ],
    );
    await _pumpSelector(
      tester,
      backend: backend,
      plan: const FilterPlan(filterName: 'ha', count: 20, durationSecs: 300),
    );

    expect(find.text('Depth goal'), findsOneWidget);
  });

  testWidgets('a binding left behind by an edit reads as stale', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-42',
          revision: 6,
          definition: depthLockDefinitionFixture(
            label: 'Tidal tail',
            automaticCompletion: true,
          ),
        ),
      ],
    );
    final edits = await _pumpSelector(
      tester,
      backend: backend,
      plan: const FilterPlan(
        filterName: 'L',
        count: 20,
        durationSecs: 300,
        depthGoal: DepthGoalBinding(goalId: 'goal-42', revision: 4),
      ),
    );

    expect(
      find.textContaining('Goal was edited; rebind'),
      findsOneWidget,
    );
    expect(
      find.textContaining('bound to revision 4 and the goal is now on 6'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Rebind'));
    await tester.pumpAndSettle();
    expect(edits.single.depthGoal?.revision, 6);
  });

  testWidgets('a goal with automation off is marked advisory', (tester) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-42',
          revision: 5,
          definition: depthLockDefinitionFixture(automaticCompletion: false),
        ),
      ],
    );
    await _pumpSelector(
      tester,
      backend: backend,
      plan: const FilterPlan(
        filterName: 'L',
        count: 20,
        durationSecs: 300,
        depthGoal: DepthGoalBinding(goalId: 'goal-42', revision: 5),
      ),
    );

    expect(
      find.textContaining(
        'Advisory only — enable automatic completion on the goal',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a binding whose goal is gone says so instead of vanishing', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-1',
          definition: depthLockDefinitionFixture(label: 'Other region'),
        ),
      ],
    );
    await _pumpSelector(
      tester,
      backend: backend,
      plan: const FilterPlan(
        filterName: 'L',
        count: 20,
        durationSecs: 300,
        depthGoal: DepthGoalBinding(goalId: 'deleted-goal', revision: 2),
      ),
    );

    expect(
      find.textContaining('no longer on the host'),
      findsOneWidget,
    );
    expect(find.text('Missing goal (deleted-goal)'), findsOneWidget);
  });

  testWidgets('clearing the binding writes null, not a goal id', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-42',
          revision: 5,
          definition: depthLockDefinitionFixture(
            label: 'Tidal tail',
            automaticCompletion: true,
          ),
        ),
      ],
    );
    final edits = await _pumpSelector(
      tester,
      backend: backend,
      plan: const FilterPlan(
        filterName: 'L',
        count: 20,
        durationSecs: 300,
        depthGoal: DepthGoalBinding(goalId: 'goal-42', revision: 5),
      ),
    );

    await tester.tap(find.text('Tidal tail · Waiting'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();

    expect(edits, hasLength(1));
    expect(edits.single.depthGoal, isNull);
  });
}

/// The tree summary has to say a plan can end early, because the tree is where
/// a run is read at a glance and nothing else in that row implies it.
void _nodeSummaryTests() {
  test('a bound plan is visible in the node summary', () {
    final node = SmartExposureNode(
      id: 'smart-1',
      plans: const <FilterPlan>[
        FilterPlan(filterName: 'L', count: 20, durationSecs: 300),
        FilterPlan(
          filterName: 'Ha',
          count: 10,
          durationSecs: 600,
          depthGoal: DepthGoalBinding(goalId: 'goal-42', revision: 5),
        ),
      ],
    );

    final fragments = nodeSummary(node)
        .whereType<StaticFragment>()
        .map((fragment) => fragment.text)
        .toList();
    expect(fragments, contains('depth goal: Ha'));
  });

  test('an unbound plan says nothing about depth', () {
    final node = SmartExposureNode(
      id: 'smart-2',
      plans: const <FilterPlan>[
        FilterPlan(filterName: 'L', count: 20, durationSecs: 300),
      ],
    );

    expect(
      nodeSummary(node).whereType<StaticFragment>().map((f) => f.text),
      isNot(anyElement(contains('depth goal'))),
    );
  });
}

/// Authoring the counts from what the bound goals still need.
void _planFromGoalsTests() {
  Future<List<FilterPlan>> pumpButton(
    WidgetTester tester, {
    required FakeDepthLockBackend backend,
    required SmartExposureNode node,
  }) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final written = <FilterPlan>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          depthLockBackendProvider.overrideWithValue(backend),
          depthLockEventStreamProvider.overrideWithValue(
            const Stream<SkotiqEvent>.empty(),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: PlanCountsFromGoalsButton(
                colors: SkotiqColors.dark,
                node: node,
                onPlansChanged: (plans) {
                  written
                    ..clear()
                    ..addAll(plans);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return written;
  }

  SmartExposureNode nodeWith(List<FilterPlan> plans) =>
      SmartExposureNode(id: 'smart-1', plans: plans);

  testWidgets('nothing bound, nothing to plan from', (tester) async {
    final written = await pumpButton(
      tester,
      backend: FakeDepthLockBackend(),
      node: nodeWith(const <FilterPlan>[
        FilterPlan(filterName: 'L', count: 20, durationSecs: 300),
      ]),
    );

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(
        SkotiqButton,
        'Plan counts from goals',
      ),
    );
    expect(button.onPressed, isNull);
    expect(written, isEmpty);
  });

  testWidgets('a bound reachable goal sets the count to what it still needs', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-L',
          revision: 3,
          definition: depthLockDefinitionFixture(filterName: 'L'),
          report: depthLockReportFixture(
            forecast: depthLockForecastFixture(
              framesToThreshold: 30,
              framesToConfirm: 16,
            ),
          ),
        ),
      ],
    );
    final written = await pumpButton(
      tester,
      backend: backend,
      node: nodeWith(const <FilterPlan>[
        FilterPlan(
          filterName: 'L',
          count: 20,
          durationSecs: 300,
          depthGoal: DepthGoalBinding(goalId: 'goal-L', revision: 3),
        ),
        FilterPlan(filterName: 'Ha', count: 12, durationSecs: 600),
      ]),
    );

    await tester.tap(
      find.widgetWithText(
        SkotiqButton,
        'Plan counts from goals',
      ),
    );
    await tester.pumpAndSettle();

    // 30 to the threshold plus the 16-exposure confirmation window.
    expect(written.first.count, 46);
    // The unbound row is the operator's own plan and is left alone.
    expect(written.last.count, 12);
    expect(find.textContaining('L → 46'), findsOneWidget);
  });

  testWidgets('an achieved goal zeroes its row and says why', (tester) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-L',
          revision: 3,
          definition: depthLockDefinitionFixture(filterName: 'L'),
          report: depthLockReportFixture(
            state: DepthLockState.achieved,
            forecast: depthLockForecastFixture(
              framesToThreshold: 0,
              framesToConfirm: 0,
            ),
          ),
        ),
        depthLockGoalFixture(
          id: 'goal-Ha',
          revision: 1,
          definition: depthLockDefinitionFixture(filterName: 'Ha'),
          report: depthLockReportFixture(
            forecast: depthLockForecastFixture(
              framesToThreshold: 10,
              framesToConfirm: 16,
            ),
          ),
        ),
      ],
    );
    final written = await pumpButton(
      tester,
      backend: backend,
      node: nodeWith(const <FilterPlan>[
        FilterPlan(
          filterName: 'L',
          count: 20,
          durationSecs: 300,
          depthGoal: DepthGoalBinding(goalId: 'goal-L', revision: 3),
        ),
        FilterPlan(
          filterName: 'Ha',
          count: 12,
          durationSecs: 600,
          depthGoal: DepthGoalBinding(goalId: 'goal-Ha', revision: 1),
        ),
      ]),
    );

    await tester.tap(
      find.widgetWithText(
        SkotiqButton,
        'Plan counts from goals',
      ),
    );
    await tester.pumpAndSettle();

    expect(written.first.count, 0);
    expect(written.last.count, 26);
    expect(find.textContaining('L → 0 (reached)'), findsOneWidget);
  });

  testWidgets('an unreachable goal leaves its row alone and names the cap', (
    tester,
  ) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-SII',
          revision: 2,
          definition: depthLockDefinitionFixture(filterName: 'SII'),
          report: depthLockReportFixture(
            forecast: depthLockForecastFixture(reachable: false),
          ),
        ),
        depthLockGoalFixture(
          id: 'goal-L',
          revision: 1,
          definition: depthLockDefinitionFixture(filterName: 'L'),
          report: depthLockReportFixture(
            forecast: depthLockForecastFixture(
              framesToThreshold: 4,
              framesToConfirm: 16,
            ),
          ),
        ),
      ],
    );
    final written = await pumpButton(
      tester,
      backend: backend,
      node: nodeWith(const <FilterPlan>[
        FilterPlan(
          filterName: 'SII',
          count: 40,
          durationSecs: 600,
          depthGoal: DepthGoalBinding(goalId: 'goal-SII', revision: 2),
        ),
        FilterPlan(
          filterName: 'L',
          count: 5,
          durationSecs: 300,
          depthGoal: DepthGoalBinding(goalId: 'goal-L', revision: 1),
        ),
      ]),
    );

    await tester.tap(
      find.widgetWithText(
        SkotiqButton,
        'Plan counts from goals',
      ),
    );
    await tester.pumpAndSettle();

    // More hours will not move it, so its authored count stands.
    expect(written.first.count, 40);
    expect(written.last.count, 20);
    expect(find.textContaining('SII (floor limit)'), findsOneWidget);
  });

  testWidgets('a stale binding is not planned from', (tester) async {
    final backend = FakeDepthLockBackend(
      goals: <DepthLockGoal>[
        depthLockGoalFixture(
          id: 'goal-L',
          revision: 5,
          definition: depthLockDefinitionFixture(filterName: 'L'),
          report: depthLockReportFixture(
            forecast: depthLockForecastFixture(framesToThreshold: 30),
          ),
        ),
      ],
    );
    final written = await pumpButton(
      tester,
      backend: backend,
      node: nodeWith(const <FilterPlan>[
        FilterPlan(
          filterName: 'L',
          count: 20,
          durationSecs: 300,
          // Bound to a revision the goal has moved past.
          depthGoal: DepthGoalBinding(goalId: 'goal-L', revision: 3),
        ),
      ]),
    );

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(
        SkotiqButton,
        'Plan counts from goals',
      ),
    );
    expect(button.onPressed, isNull);
    expect(written, isEmpty);
  });
}
