// Widget tests for the Scheduler tab content (SchedulerTabContent), the
// body that the Plan Tonight `/planner?tab=scheduler` tab mounts. The
// standalone `/scheduler` route now redirects to that tab, so these tests
// drive the tab body directly.
//
// We don't spin up the full Riverpod graph (which would require a real
// drift database, an Ffi backend, and the full event bus). Instead we
// override the providers the widget actually reads
// (schedulerEngineProvider, schedulerStatusProvider,
// currentSchedulerDecisionProvider, plus the integration goals,
// constraint, and target streams) with deterministic test doubles.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:skotiq_app/screens/planner/widgets/scheduler_tab_content.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as ndb;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';

class _FakeSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}
  @override
  Future<void> pauseSequence() async {}
  @override
  Future<void> resumeSequence() async {}
  @override
  Future<void> stopSequence() async {}
  @override
  Future<void> parkForEndOfNight() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
}

/// In-memory fake of [IntegrationGoalService] for widget tests. Only
/// implements the methods the scheduler screen actually calls.
class _FakeIntegrationGoalService implements IntegrationGoalService {
  final List<int> deletedForTarget = [];
  int deleteAllCalls = 0;

  @override
  Future<void> deleteForTarget(int targetId) async {
    deletedForTarget.add(targetId);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        '_FakeIntegrationGoalService.${invocation.memberName} not implemented');
  }
}

class _FakeTargetConstraintService implements TargetConstraintService {
  final List<int> deletedForTarget = [];
  int deleteAllCalls = 0;

  @override
  Future<void> deleteForTarget(int targetId) async {
    deletedForTarget.add(targetId);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCalls++;
  }

  @override
  Future<void> dispose() async {}

  @override
  noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        '_FakeTargetConstraintService.${invocation.memberName} not implemented');
  }
}

/// Common overrides for the scheduler-screen tests: provides empty streams
/// for the three auto-reeval inputs and silences the integration-goal
/// progress fetch. Callers append their own per-test overrides.
List<Override> _commonOverrides({
  IntegrationGoalService? goalService,
  TargetConstraintService? constraintService,
}) {
  return [
    schedulerEngineReadyProvider.overrideWith(
      (ref) => ref.read(schedulerEngineProvider),
    ),
    schedulerPreviewDecisionProvider.overrideWith(
      (ref) => Completer<SchedulerDecision>().future,
    ),
    schedulerAutoReevalProvider.overrideWith((ref) {}),
    allDbTargetsProvider.overrideWith(
      (ref) => const Stream<List<ndb.Target>>.empty(),
    ),
    integrationGoalsStreamProvider.overrideWith(
      (ref) => const Stream<List<IntegrationGoal>>.empty(),
    ),
    targetConstraintsStreamProvider.overrideWith(
      (ref) => const Stream<List<TargetConstraint>>.empty(),
    ),
    integrationGoalProgressProvider.overrideWith(
      (ref, _) async => <IntegrationGoalProgress>[],
    ),
    if (goalService != null)
      integrationGoalServiceProvider.overrideWithValue(goalService),
    if (constraintService != null)
      targetConstraintServiceProvider.overrideWithValue(constraintService),
  ];
}

SchedulerEngine _buildTestEngine() {
  return SchedulerEngine(
    site: const SchedulerSite(
      latitudeDegrees: 40.0,
      longitudeDegrees: -75.0,
      localOffset: Duration(hours: -5),
    ),
    sequenceSink: _FakeSink(),
    candidateLoader: () async => const <SchedulerCandidate>[],
    clock: () => DateTime.utc(2026, 5, 11, 4, 0),
  );
}

TargetScore _score({
  required int id,
  required String name,
  required double total,
  bool hardFail = false,
  List<String> rejections = const [],
}) {
  return TargetScore(
    targetId: id,
    targetName: name,
    totalScore: total,
    factors: const [
      ScoreFactor(name: 'altitude', value: 0.7, weight: 1.0, weighted: 0.7),
      ScoreFactor(name: 'meridian', value: 0.5, weight: 1.0, weighted: 0.5),
    ],
    hardConstraintFailed: hardFail,
    rejectionReasons: rejections,
  );
}

SchedulerDecision _decisionWith({
  required int? chosenId,
  required String? chosenName,
  required List<TargetScore> scored,
}) {
  return SchedulerDecision(
    chosenTargetId: chosenId,
    chosenTargetName: chosenName,
    score: chosenId != null ? scored.first.totalScore : 0.0,
    reasoning: [
      if (chosenName != null)
        'Chose $chosenName at 2026-05-11T04:00:00Z (manual)'
      else
        'No eligible candidates',
    ],
    scoredCandidates: scored,
    evaluatedAt: DateTime.utc(2026, 5, 11, 4, 0),
    isSwitch: chosenId != null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders queue, decision panel, and control buttons',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    final decision = _decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [
        _score(id: 1, name: 'NGC 7000', total: 2.4),
        _score(id: 2, name: 'M31', total: 1.8),
        _score(
          id: 3,
          name: 'Setting Object',
          total: 0.3,
          hardFail: true,
          rejections: ['altitude 12.3° below site minimum 25.0°'],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(decision);
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SchedulerTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Header and state badge.
    expect(find.text('Unattended autopilot'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);

    // Three control buttons should be present in idle state: Start +
    // Re-evaluate (Pause/Resume/Stop hidden while idle).
    expect(find.widgetWithText(SkotiqButton, 'Run unattended all night'),
        findsOneWidget);
    expect(
        find.widgetWithText(SkotiqButton, 'Re-evaluate'), findsOneWidget);

    // Active target name appears in the decision panel.
    expect(find.text('NGC 7000'), findsAtLeastNWidgets(1));
    // The queue table heading.
    expect(find.text('Scheduler queue'), findsOneWidget);
    // All three candidate names render in the queue.
    expect(find.text('M31'), findsOneWidget);
    expect(find.text('Setting Object'), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'empty queue shows an EmptyState naming the cause with one button',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    final emptyDecision = _decisionWith(
      chosenId: null,
      chosenName: null,
      scored: const <TargetScore>[],
    );

    // Wrap the screen in a minimal GoRouter so the "Open target catalog"
    // button can call context.go('/planner') without throwing.
    final router = GoRouter(
      initialLocation: '/scheduler',
      routes: [
        GoRoute(
          path: '/scheduler',
          builder: (_, __) => const Scaffold(body: SchedulerTabContent()),
        ),
        GoRoute(
          path: '/planner',
          builder: (_, __) =>
              const Scaffold(body: Text('planner stub for test')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(emptyDecision);
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('No targets to schedule'), findsOneWidget);
    // Catalog and goal streams are overridden to never emit here, so the
    // empty state genuinely does not know which cause applies and must not
    // name one. See scheduler_empty_state_cause_test.dart for the diagnoses.
    expect(
      find.textContaining('produced no candidates'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Open target catalog'),
      findsOneWidget,
    );
    // ONE button (05 §12). The old card offered three plus a "Learn more"
    // expander whose paragraph explained the scoring engine — exactly the
    // screen-explaining prose 07 "What NOT to do" routes to the help popover.
    expect(
      find.descendant(
        of: find.byType(EmptyState),
        matching: find.byType(SkotiqButton),
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Learn more'), findsNothing);
    expect(find.text('How the scheduler picks targets'), findsNothing);
    expect(find.byType(EmptyState), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets('idle decision panel surfaces the explicit "Start" hint copy',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(null);
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SchedulerTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.textContaining(
          'Autopilot is stopped. Run unattended all night to begin '
          'evaluating'),
      findsAtLeastNWidgets(1),
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Run unattended all night'),
      findsOneWidget,
    );

    await settleProviderTeardown(tester);
  });

  testWidgets('running state shows Pause and Stop buttons', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(SchedulerStatus(
              state: SchedulerState.running,
              currentTargetId: 1,
              currentTargetName: 'NGC 7000',
              nextEvaluationAt: DateTime.now().add(const Duration(seconds: 45)),
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(_decisionWith(
              chosenId: 1,
              chosenName: 'NGC 7000',
              scored: [_score(id: 1, name: 'NGC 7000', total: 2.4)],
            ));
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SchedulerTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Running'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Pause'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Stop'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Run unattended all night'),
        findsNothing);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'per-row delete icon opens confirmation dialog and on confirm wipes '
      'goals and constraints for that target', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    final goalSvc = _FakeIntegrationGoalService();
    final constraintSvc = _FakeTargetConstraintService();
    final decision = _decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [
        _score(id: 1, name: 'NGC 7000', total: 2.4),
        _score(id: 2, name: 'M31', total: 1.8),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(
            goalService: goalSvc,
            constraintService: constraintSvc,
          ),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(decision);
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SchedulerTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Tap the delete icon on the second row (target id=2, M31).
    final deleteButton = find.byKey(const ValueKey('scheduler-delete-row-2'));
    expect(deleteButton, findsOneWidget);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    // Confirmation dialog should appear.
    expect(find.text('Remove from scheduler?'), findsOneWidget);
    expect(find.textContaining('Remove M31'), findsOneWidget);

    // Cancel first - nothing should happen.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(goalSvc.deletedForTarget, isEmpty);
    expect(constraintSvc.deletedForTarget, isEmpty);

    // Tap delete again and this time confirm.
    await tester.tap(find.byKey(const ValueKey('scheduler-delete-row-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(goalSvc.deletedForTarget, [2]);
    expect(constraintSvc.deletedForTarget, [2]);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      '"Clear all" button opens confirmation dialog and on confirm '
      'wipes every goal and constraint', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    final goalSvc = _FakeIntegrationGoalService();
    final constraintSvc = _FakeTargetConstraintService();
    final decision = _decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [
        _score(id: 1, name: 'NGC 7000', total: 2.4),
        _score(id: 2, name: 'M31', total: 1.8),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(
            goalService: goalSvc,
            constraintService: constraintSvc,
          ),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(decision);
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SchedulerTabContent()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final clearAll = find.byKey(const ValueKey('scheduler-clear-all'));
    expect(clearAll, findsOneWidget);
    await tester.tap(clearAll);
    await tester.pumpAndSettle();

    expect(find.text('Clear scheduler queue?'), findsOneWidget);

    // Confirm by tapping Clear.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(goalSvc.deleteAllCalls, 1);
    expect(constraintSvc.deleteAllCalls, 1);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      '"Clear all" button is hidden when there are no rows in the queue',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = _buildTestEngine();
    final emptyDecision = _decisionWith(
      chosenId: null,
      chosenName: null,
      scored: const <TargetScore>[],
    );

    final router = GoRouter(
      initialLocation: '/scheduler',
      routes: [
        GoRoute(
          path: '/scheduler',
          builder: (_, __) => const Scaffold(body: SchedulerTabContent()),
        ),
        GoRoute(
          path: '/planner',
          builder: (_, __) =>
              const Scaffold(body: Text('planner stub for test')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return _FakeStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return _FakeDecisionNotifier(emptyDecision);
          }),
          allIntegrationGoalsProvider.overrideWith(
            (ref) async => <IntegrationGoal>[],
          ),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('scheduler-clear-all')), findsNothing);

    await settleProviderTeardown(tester);
  });
}

class _FakeStatusNotifier extends SchedulerStatusNotifier {
  _FakeStatusNotifier(SchedulerStatus initial) : super(_DummyEngine()) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

class _FakeDecisionNotifier extends CurrentSchedulerDecisionNotifier {
  _FakeDecisionNotifier(SchedulerDecision? initial) : super(_DummyEngine()) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

/// Bare-bones SchedulerEngine that satisfies the notifier constructor
/// signature without doing any real work — the fake notifiers above only
/// pass their initial state up to the StateNotifier base class and never
/// listen to the engine's streams (the streams are still live, but they
/// emit nothing so the fake state stays put).
class _DummyEngine extends SchedulerEngine {
  _DummyEngine()
      : super(
          site: const SchedulerSite(
            latitudeDegrees: 0,
            longitudeDegrees: 0,
            localOffset: Duration.zero,
          ),
          sequenceSink: _FakeSink(),
          candidateLoader: () async => const <SchedulerCandidate>[],
        );
}
