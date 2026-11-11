import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/project_tracking_panel.dart';
import 'package:skotiq_app/screens/scheduler/widgets/integration_goals_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

ProjectProgress _project() {
  final now = DateTime.utc(2026, 7, 13);
  return ProjectProgress(
    target: DbTarget(
      id: 7,
      name: 'M31',
      ra: 0.71,
      dec: 41.27,
      minAltitude: 20,
      priority: 1,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 3600,
      createdAt: now,
      updatedAt: now,
      isFavorite: false,
    ),
    sessionCount: 0,
    acceptedFrames: 0,
    integratedSecs: 0,
    filters: const [],
    goalIntegrationSecs: 3600,
    lastImagedAt: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('untracked-target cleanup is canceled after a host switch',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          projectProgressListProvider.overrideWith(
            (ref) => AsyncValue.data([_project()]),
          ),
          untrackedTargetsCountProvider.overrideWith((ref) async => 3),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SizedBox(
              width: 1000,
              height: 800,
              child: ProjectTrackingPanel(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove untracked targets (3)'));
    await tester.pumpAndSettle();
    expect(find.text('Remove untracked targets?'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    verifyNever(hostA.removeUntrackedTargets);
    verifyNever(hostB.removeUntrackedTargets);
    expect(
      find.text('Imaging host changed. Cleanup was canceled.'),
      findsOneWidget,
    );
  });

  // The goal a card shows is the one Plan > Projects sets, so the card edits
  // it in the same per-filter editor rather than in a second, scalar goal.
  testWidgets('Edit goal opens the integration-goals editor for the target',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          projectProgressListProvider.overrideWith(
            (ref) => AsyncValue.data([_project()]),
          ),
          untrackedTargetsCountProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SizedBox(
              width: 1000,
              height: 800,
              child: ProjectTrackingPanel(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit Goal'));
    await tester.pumpAndSettle();
    expect(find.text('Integration goals — M31'), findsOneWidget);
    expect(find.byType(IntegrationGoalsEditor), findsOneWidget);

    // Drift closes a stream query on a zero-length timer after its last
    // listener goes; let it run before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
