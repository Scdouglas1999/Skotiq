// The Target-queue empty state must name the cause that actually produced the
// empty queue. The scheduler's candidate query is project-scoped, so an active
// project with no members hides a fully-populated catalog — and generic copy
// sends that operator off to add targets and goals they already have.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planner/widgets/scheduler_tab_content.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as ndb;
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _FixedActiveProject extends ActiveProjectNotifier {
  // ignore: use_super_parameters
  _FixedActiveProject(Ref ref, int? id) : super(ref) {
    // ignore: invalid_use_of_protected_member
    state = id;
  }
}

/// A remote scheduler decision that scored nothing — the state the queue's
/// empty view renders for.
Map<String, dynamic> _emptyDecisionState() {
  return {
    'status': {'state': SchedulerState.idle.name},
    'decision': {
      'score': 0,
      'reasoning': <String>['No candidate targets available'],
      'scoredCandidates': <Object?>[],
      'rejected': <Object?>[],
      'evaluatedAt': DateTime.utc(2026, 8, 1).toIso8601String(),
      'isSwitch': false,
    },
    'config': SchedulerConfig.defaults.toStorageJson(),
  };
}

ndb.Target _target(int id, String name) => ndb.Target(
      id: id,
      name: name,
      ra: 17.28,
      dec: 43.13,
      minAltitude: 30,
      priority: 5,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 0,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      isFavorite: false,
    );

IntegrationGoal _goal(int targetId) => IntegrationGoal(
      id: targetId,
      targetId: targetId,
      filter: 'Luminance',
      exposureSeconds: 180,
      frameCount: 20,
      createdAt: DateTime.utc(2026),
    );

Future<void> _pumpQueue(
  WidgetTester tester, {
  required List<ndb.Target> catalog,
  required List<IntegrationGoal> goals,
  int? activeProjectId,
  CampaignProgress? activeProjectProgress,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final backend = _MockNetworkBackend();
  when(backend.getSchedulerState)
      .thenAnswer((_) async => _emptyDecisionState());
  // ActiveProjectNotifier scopes its persisted key by remote identity.
  when(() => backend.scheme).thenReturn('https');
  when(() => backend.serverHost).thenReturn('host.local');
  when(() => backend.serverPort).thenReturn(8080);
  when(() => backend.pinnedFingerprint).thenReturn(null);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        schedulerAutoReevalProvider.overrideWith((ref) {}),
        schedulerPreviewDecisionProvider.overrideWith(
          (ref) => Completer<SchedulerDecision>().future,
        ),
        schedulerEngineProvider.overrideWith(
          (ref) => throw StateError('remote client created an engine'),
        ),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        allDbTargetsProvider.overrideWith((ref) => Stream.value(catalog)),
        integrationGoalsStreamProvider.overrideWith(
          (ref) => Stream.value(goals),
        ),
        allIntegrationGoalsProvider.overrideWith((ref) async => goals),
        targetConstraintsStreamProvider.overrideWith(
          (ref) => const Stream<List<TargetConstraint>>.empty(),
        ),
        integrationGoalProgressProvider.overrideWith(
          (ref, _) async => <IntegrationGoalProgress>[],
        ),
        activeProjectIdProvider.overrideWith(
          (ref) => _FixedActiveProject(ref, activeProjectId),
        ),
        activeProjectProgressProvider.overrideWith(
          (ref) async => activeProjectProgress,
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: SchedulerTabContent()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an empty active project is named, not blamed on a missing catalog',
    (tester) async {
      await _pumpQueue(
        tester,
        catalog: [_target(1, 'M92'), _target(2, 'M13'), _target(3, 'M57')],
        goals: [_goal(1), _goal(2), _goal(3)],
        activeProjectId: 1,
        activeProjectProgress: CampaignProgress(
          project: Project(
            id: 1,
            name: 'Empty Project',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          targets: const <ProjectTargetProgress>[],
        ),
      );

      expect(find.textContaining('Empty Project'), findsWidgets);
      expect(
        find.textContaining('Add a target to your catalog'),
        findsNothing,
      );
      // The one action that actually resolves this cause.
      expect(
        find.byKey(const ValueKey('scheduler-clear-active-project')),
        findsOneWidget,
      );
    },
  );

  testWidgets('an empty catalog is still called an empty catalog',
      (tester) async {
    await _pumpQueue(
      tester,
      catalog: const <ndb.Target>[],
      goals: const <IntegrationGoal>[],
    );

    expect(find.text('No targets in your catalog'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('scheduler-clear-active-project')),
      findsNothing,
    );
  });

  testWidgets('targets without goals are told about goals, not about targets',
      (tester) async {
    await _pumpQueue(
      tester,
      catalog: [_target(1, 'M92')],
      goals: const <IntegrationGoal>[],
    );

    expect(find.text('No integration goals set'), findsOneWidget);
    expect(find.textContaining('Add a target to your catalog'), findsNothing);
  });
}
