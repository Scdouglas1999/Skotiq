// Covers scheduler controls and queue behavior in the Planner tab.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_app/screens/planner/widgets/scheduler_tab_content.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as ndb;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../scheduler/scheduler_test_doubles.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {
  _MockNetworkBackend() {
    // Keep remote identity deterministic for the queue's project scope.
    when(() => scheme).thenReturn('https');
    when(() => serverHost).thenReturn('host.local');
    when(() => serverPort).thenReturn(8080);
    when(() => pinnedFingerprint).thenReturn(null);
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Map<String, dynamic> _remoteSchedulerState({
  SchedulerState state = SchedulerState.idle,
  bool hasCandidates = true,
  SchedulerStartReadiness? readiness = const SchedulerStartReadiness(
    issues: [],
    available: true,
    solverRequired: true,
  ),
}) {
  return {
    'status': {'state': state.name},
    'decision': {
      'score': 0,
      'reasoning': <String>[],
      'scoredCandidates': hasCandidates
          ? <Object?>[
              {
                'targetId': 1,
                'targetName': 'M42',
                'totalScore': 1.0,
                'factors': <Object?>[],
                'hardConstraintFailed': false,
                'rejectionReasons': <Object?>[],
              },
            ]
          : <Object?>[],
      'rejected': <Object?>[],
      'evaluatedAt': DateTime.utc(2026, 7, 13).toIso8601String(),
      'isSwitch': false,
    },
    'config': SchedulerConfig.defaults.toStorageJson(),
    if (readiness != null) 'readiness': readiness.toStorageJson(),
  };
}

List<Override> _commonOverrides({
  IntegrationGoalService? goalService,
  TargetConstraintService? constraintService,
  bool overrideReadiness = true,
}) {
  return [
    if (overrideReadiness)
      schedulerEngineReadyProvider.overrideWith(
        (ref) => ref.read(schedulerEngineProvider),
      ),
    if (overrideReadiness)
      schedulerStartReadinessProvider.overrideWithValue(
        const SchedulerStartReadiness(
          issues: [],
          available: true,
          solverRequired: true,
        ),
      ),
    schedulerAutoReevalProvider.overrideWith((ref) {}),
    schedulerPreviewDecisionProvider.overrideWith(
      (ref) => Completer<SchedulerDecision>().future,
    ),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('local scheduler authority failure is visible and retryable',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(overrideReadiness: false),
          schedulerEngineReadyProvider.overrideWith((ref) async {
            attempts++;
            throw StateError('settings store unavailable');
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SchedulerTabContent()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('Could not load scheduler configuration'),
      findsOneWidget,
    );
    expect(find.textContaining('settings store unavailable'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
  });

  testWidgets(
      'remote Run button starts the host without constructing an engine',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final backend = _MockNetworkBackend();
    when(backend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(),
    );
    when(() => backend.controlScheduler('start')).thenAnswer(
      (_) async => _remoteSchedulerState(state: SchedulerState.running),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote client created an engine'),
          ),
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
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Run unattended all night'),
    );
    await tester.pumpAndSettle();

    verify(() => backend.controlScheduler('start')).called(1);
  });

  testWidgets('remote readiness blocker disables Run and never calls host',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final backend = _MockNetworkBackend();
    when(backend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(
        readiness: const SchedulerStartReadiness(
          issues: [
            SchedulerReadinessIssue(
              id: SchedulerReadinessIssueId.camera,
              severity: SchedulerReadinessSeverity.blocker,
              title: 'Camera',
              detail: 'Camera is not connected.',
            ),
          ],
          available: true,
          solverRequired: true,
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote client created an engine'),
          ),
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
    await tester.pumpAndSettle();

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Run unattended all night'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Camera'), findsOneWidget);
    verifyNever(() => backend.controlScheduler('start'));
  });

  testWidgets('remote warnings require cancel or explicit confirmation',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final backend = _MockNetworkBackend();
    const warning = SchedulerReadinessIssue(
      id: SchedulerReadinessIssueId.weather,
      severity: SchedulerReadinessSeverity.warning,
      title: 'Weather monitoring',
      detail: 'Weather monitoring is disabled.',
    );
    when(backend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(
        readiness: const SchedulerStartReadiness(
          issues: [warning],
          available: true,
          solverRequired: true,
        ),
      ),
    );
    when(() => backend.controlScheduler('start', confirmWarnings: true))
        .thenAnswer(
      (_) async => _remoteSchedulerState(state: SchedulerState.running),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote client created an engine'),
          ),
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
    await tester.pumpAndSettle();
    final runButton =
        find.widgetWithText(SkotiqButton, 'Run unattended all night');

    await tester.tap(runButton);
    await tester.pumpAndSettle();
    expect(find.text('Review unattended start'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(
      () => backend.controlScheduler('start', confirmWarnings: true),
    );

    await tester.tap(runButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start anyway'));
    await tester.pumpAndSettle();
    verify(
      () => backend.controlScheduler('start', confirmWarnings: true),
    ).called(1);
  });

  testWidgets('remote snapshot without readiness fails closed', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final backend = _MockNetworkBackend();
    when(backend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(readiness: null),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote client created an engine'),
          ),
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
    await tester.pumpAndSettle();

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Run unattended all night'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Host readiness unavailable'), findsOneWidget);
    verifyNever(() => backend.controlScheduler('start'));
  });

  testWidgets('empty scheduler explains why unattended start is disabled',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final backend = _MockNetworkBackend();
    when(backend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(hasCandidates: false),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote client created an engine'),
          ),
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
    await tester.pumpAndSettle();

    final button = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Run unattended all night'),
    );
    expect(button.onPressed, isNull);
    expect(
      find.textContaining('Add at least one target'),
      findsOneWidget,
    );
    verifyNever(() => backend.controlScheduler('start'));
  });

  testWidgets(
      'switching hosts retires an in-flight scheduler command immediately',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final oldBackend = _MockNetworkBackend();
    final newBackend = _MockNetworkBackend();
    final oldCommand = Completer<Map<String, dynamic>>();
    when(oldBackend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(),
    );
    when(newBackend.getSchedulerState).thenAnswer(
      (_) async => _remoteSchedulerState(),
    );
    when(() => oldBackend.controlScheduler('start')).thenAnswer(
      (_) => oldCommand.future,
    );
    when(() => newBackend.controlScheduler('start')).thenAnswer(
      (_) async => _remoteSchedulerState(state: SchedulerState.running),
    );
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, oldBackend);
            return notifier;
          }),
          schedulerEngineProvider.overrideWith(
            (ref) => throw StateError('remote client created an engine'),
          ),
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
    await tester.pumpAndSettle();

    final runButton =
        find.widgetWithText(SkotiqButton, 'Run unattended all night');
    await tester.tap(runButton);
    await tester.pump();
    verify(() => oldBackend.controlScheduler('start')).called(1);

    notifier.switchTo(newBackend);
    await tester.pumpAndSettle();

    // A pending request from the previous host must not leave the replacement
    // host busy.
    await tester.tap(runButton);
    await tester.pumpAndSettle();
    verify(() => newBackend.controlScheduler('start')).called(1);

    oldCommand.completeError(StateError('old host went away'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('old host went away'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'per-row delete icon opens confirmation dialog and on confirm wipes '
      'goals and constraints for that target even when embedded as a Plan '
      'Tonight tab', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = buildTestSchedulerEngine();
    final goalSvc = FakeIntegrationGoalService();
    final constraintSvc = FakeTargetConstraintService();
    final decision = decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [
        scoreFor(id: 1, name: 'NGC 7000', total: 2.4),
        scoreFor(id: 2, name: 'M31', total: 1.8),
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
            return FakeSchedulerStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return FakeCurrentSchedulerDecisionNotifier(decision);
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

    expect(find.text('Remove from scheduler?'), findsOneWidget);
    expect(find.textContaining('Remove M31'), findsOneWidget);

    // Confirm.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(goalSvc.deletedForTarget, [2]);
    expect(constraintSvc.deletedForTarget, [2]);
  });

  testWidgets('scheduler row cleanup is cancelled after a host switch',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = buildTestSchedulerEngine();
    final goalSvc = FakeIntegrationGoalService();
    final constraintSvc = FakeTargetConstraintService();
    final decision = decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [scoreFor(id: 2, name: 'M31', total: 1.8)],
    );
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(
            goalService: goalSvc,
            constraintService: constraintSvc,
          ),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, DisconnectedBackend());
            return notifier;
          }),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return FakeSchedulerStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return FakeCurrentSchedulerDecisionNotifier(decision);
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

    await tester.tap(find.byKey(const ValueKey('scheduler-delete-row-2')));
    await tester.pumpAndSettle();
    expect(find.text('Remove from scheduler?'), findsOneWidget);

    notifier.switchTo(DisconnectedBackend());
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(goalSvc.deletedForTarget, isEmpty);
    expect(constraintSvc.deletedForTarget, isEmpty);
    expect(find.textContaining('cleanup was cancelled'), findsOneWidget);
  });

  testWidgets('"Clear all" button works when SchedulerTabContent is embedded',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = buildTestSchedulerEngine();
    final goalSvc = FakeIntegrationGoalService();
    final constraintSvc = FakeTargetConstraintService();
    final decision = decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [
        scoreFor(id: 1, name: 'NGC 7000', total: 2.4),
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
            return FakeSchedulerStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return FakeCurrentSchedulerDecisionNotifier(decision);
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
    await tester.tap(find.widgetWithText(SkotiqButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(goalSvc.deleteAllCalls, 1);
    expect(constraintSvc.deleteAllCalls, 1);
  });

  testWidgets('queue header, decision panel, and Target queue render',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = buildTestSchedulerEngine();
    final decision = decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [scoreFor(id: 1, name: 'NGC 7000', total: 2.4)],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return FakeSchedulerStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return FakeCurrentSchedulerDecisionNotifier(decision);
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

    expect(find.text('Unattended autopilot'), findsOneWidget);
    expect(find.text('Scheduler queue'), findsOneWidget);
    expect(find.text('NGC 7000'), findsAtLeastNWidgets(1));

    final title = tester.renderObject<RenderParagraph>(
      find.text('Unattended autopilot'),
    );
    expect(
      title.didExceedMaxLines,
      isFalse,
      reason: 'the autopilot panel title is clipped at this panel width',
    );
  });

  testWidgets(
      'the autopilot panel title fits at the narrowest panel width, with the '
      'status badge dropping to its own line to make room', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1050, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = buildTestSchedulerEngine();
    final decision = decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [scoreFor(id: 1, name: 'NGC 7000', total: 2.4)],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerStatusProvider.overrideWith((ref) {
            return FakeSchedulerStatusNotifier(const SchedulerStatus(
              state: SchedulerState.running,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return FakeCurrentSchedulerDecisionNotifier(decision);
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

    final titleFinder = find.text('Unattended autopilot');
    final title = tester.renderObject<RenderParagraph>(titleFinder);
    expect(
      title.didExceedMaxLines,
      isFalse,
      reason: 'the autopilot panel title is clipped at the 280 px panel floor',
    );

    final badgeTop = tester.getTopLeft(find.text('Running')).dy;
    final titleBottom = tester.getBottomLeft(titleFinder).dy;
    expect(
      badgeTop,
      greaterThanOrEqualTo(titleBottom - 1.0),
      reason: 'the status badge should wrap below the title at this width',
    );

    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets(
      'rejected candidates render in "Other candidates considered" section '
      'with each primary reason chip; expanding a row reveals the full '
      'per-factor breakdown', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final engine = buildTestSchedulerEngine();
    final decision = decisionWith(
      chosenId: 1,
      chosenName: 'NGC 7000',
      scored: [
        scoreFor(id: 1, name: 'NGC 7000', total: 2.4),
      ],
      rejected: [
        rejectionFor(
          id: 2,
          name: 'M31',
          score: 1.1,
          primaryReason: 'below horizon',
          hardConstraintFailures: const [
            'altitude 12.0° below site minimum 25.0°',
          ],
        ),
        rejectionFor(
          id: 3,
          name: 'M42',
          score: 1.6,
          primaryReason: 'lower score than chosen (66% of winner)',
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
            return FakeSchedulerStatusNotifier(const SchedulerStatus(
              state: SchedulerState.idle,
            ));
          }),
          currentSchedulerDecisionProvider.overrideWith((ref) {
            return FakeCurrentSchedulerDecisionNotifier(decision);
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

    // The section header shows the count.
    expect(find.text('Other candidates considered (2)'), findsOneWidget);

    // Expand the section.
    await tester.tap(find.text('Other candidates considered (2)'));
    await tester.pumpAndSettle();

    // Both rejected rows render with their primary reason chips.
    expect(find.text('M31'), findsOneWidget);
    expect(find.text('M42'), findsOneWidget);
    expect(find.text('below horizon'), findsOneWidget);
    expect(
        find.text('lower score than chosen (66% of winner)'), findsOneWidget);

    // Tap the M31 row to expand its details. The expanded body shows the
    // hard-constraint failure list AND the per-factor score breakdown.
    await tester.tap(find.byKey(const ValueKey('rejected-row-2')));
    await tester.pumpAndSettle();
    expect(find.text('Failed hard constraints'), findsOneWidget);
    expect(find.textContaining('altitude 12.0'), findsOneWidget);
    expect(find.text('Score breakdown'), findsOneWidget);
    // Factor lines render with their numeric values — the test fakes
    // produce altitude + meridian factors with known weights.
    expect(find.textContaining('altitude:'), findsOneWidget);
    expect(find.textContaining('meridian:'), findsOneWidget);
  });
}
