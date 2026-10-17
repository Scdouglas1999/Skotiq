import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_layout_provider.dart';
import 'package:skotiq_app/screens/dashboard/dashboard_screen.dart';
import 'package:skotiq_app/screens/dashboard/widgets/glass_card.dart';
import 'package:skotiq_app/screens/dashboard/widgets/next_use_prompt_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

/// All-disabled dashboard layout so no tile pulls skotiq_planetarium's
/// periodic observation-time timer (which would trip the timer-leak invariant).
/// Mirrors the notifier used in readiness_overlay_coach_gate_test.dart.
class _AllDisabledDashboardLayoutNotifier extends DashboardLayoutNotifier {
  @override
  Future<DashboardLayout> build() async {
    final disabled = DashboardLayout.defaultLayout()
        .tiles
        .map((tile) => tile.copyWith(enabled: false))
        .toList();
    return DashboardLayout(
      version: DashboardLayout.currentVersion,
      tiles: disabled,
      secondaryZoneWidth: 0.4,
    );
  }
}

/// Settings notifier with Smart Night auto-prompt ON and a real location, so
/// the Smart Night prompt becomes eligible once an equipment profile is set.
class _SmartNightReadySettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        latitude: 40,
        longitude: -75,
        smartNightAutoPromptEnabled: true,
      );
}

/// Builds a router whose root renders [card] inside the shared [container], plus
/// a stub route per next-use deep link. Each stub renders a unique [Key] marker
/// so a test can assert that tapping the primary button actually navigated.
GoRouter _router({
  required ProviderContainer container,
  required Widget card,
}) {
  GoRoute stub(String path) => GoRoute(
        path: path,
        builder: (context, state) => Scaffold(
          key: ValueKey('route:$path'),
          body: const SizedBox.shrink(),
        ),
      );

  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(body: card),
          ),
        ),
      ),
      stub('/planner'),
      stub('/framing'),
      stub('/settings'),
      stub('/equipment'),
      stub('/imaging'),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const card = NextUsePromptCard(colors: SkotiqColors.dark);

  testWidgets('renders nothing when no next-use step is pending',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        nextUsePromptProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(container: container, card: card),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DashboardGlassCard), findsNothing);
    expect(find.text('Plan tonight automatically'), findsNothing);
  });

  testWidgets('shows the first step title, body, and action label',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final firstStep = kNextUseSteps.first;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        nextUsePromptProvider.overrideWithValue(firstStep),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(container: container, card: card),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DashboardGlassCard), findsOneWidget);
    expect(find.text(firstStep.title), findsOneWidget);
    expect(find.text(firstStep.body), findsOneWidget);
    expect(find.text(firstStep.actionLabel), findsOneWidget);
    expect(find.byIcon(LucideIcons.arrowRight), findsOneWidget);
  });

  testWidgets('primary button navigates to the step deep-link route',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    // frameTarget routes to a clean path ("/framing") with no query string, so
    // the stub-route assertion below is unambiguous.
    final step = stepFor(NextUseActionId.frameTarget);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        nextUsePromptProvider.overrideWithValue(step),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final router = _router(container: container, card: card);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text(step.actionLabel));
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/framing');
    expect(find.byKey(const ValueKey('route:/framing')), findsOneWidget);
  });

  testWidgets('skip-this writes the next_use.<id> dismissal row',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final step = kNextUseSteps.first;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        nextUsePromptProvider.overrideWithValue(step),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(container: container, card: card),
      ),
    );
    await tester.pumpAndSettle();

    final dao = container.read(tutorialProgressDaoProvider);
    final screenId = nextUsePromptScreenId(step.id);
    expect(await dao.isPromptDismissedForScreen(screenId), isFalse);

    // The inline ghost button retires the step for good — the dismissal row it
    // writes is permanent — so it must not be labelled as a deferral like
    // "Not now", which promises the step comes back.
    expect(find.text('Not now'), findsNothing);
    expect(find.text('Skip this step'), findsOneWidget);

    await tester.tap(find.text('Skip this step'));
    await tester.pumpAndSettle();

    expect(await dao.isPromptDismissedForScreen(screenId), isTrue);
  });

  testWidgets('hide-all-tips dismisses every next-use step', (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        nextUsePromptProvider.overrideWithValue(kNextUseSteps.first),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(container: container, card: card),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.moreVertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide all tips'));
    await tester.pumpAndSettle();

    final dao = container.read(tutorialProgressDaoProvider);
    for (final id in NextUseActionId.values) {
      expect(
        await dao.isPromptDismissedForScreen(nextUsePromptScreenId(id)),
        isTrue,
        reason: 'expected ${id.name} to be dismissed',
      );
    }
  });

  testWidgets('suppressed while the Smart Night prompt is eligible',
      (tester) async {
    final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        // A real next-use step is pending...
        nextUsePromptProvider.overrideWithValue(kNextUseSteps.first),
        // ...but Smart Night is base-eligible (complete optics + auto-prompt on
        // + real location + idle sequence), so this card must stand down.
        appSettingsProvider.overrideWith(_SmartNightReadySettingsNotifier.new),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(
            id: 7,
            name: 'Backyard rig',
            focalLength: 600,
            aperture: 80,
            filterNames: ['L'],
          ),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        sequenceExecutionStateProvider
            .overrideWith((ref) => SequenceExecutionState.idle),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _router(container: container, card: card),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DashboardGlassCard), findsNothing);
    expect(find.text(kNextUseSteps.first.title), findsNothing);
  });

  for (final executionState in <SequenceExecutionState>[
    SequenceExecutionState.running,
    SequenceExecutionState.paused,
    SequenceExecutionState.stopping,
    SequenceExecutionState.recovering,
    SequenceExecutionState.stopFailed,
    SequenceExecutionState.cleanupFailed,
    SequenceExecutionState.finalizing,
  ]) {
    testWidgets(
      'suppressed while sequence state is ${executionState.name}',
      (tester) async {
        final database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            nextUsePromptProvider.overrideWithValue(kNextUseSteps.first),
            sequenceExecutionStateProvider.overrideWith(
              (ref) => executionState,
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        await tester.pumpWidget(
          MaterialApp.router(
            routerConfig: _router(container: container, card: card),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(DashboardGlassCard), findsNothing);
        expect(find.text(kNextUseSteps.first.title), findsNothing);
      },
    );
  }

  testWidgets('Tonight does NOT float the next-use prompt over the page',
      (tester) async {
    // 02 rule 5: setup guidance lives in ONE place, the first-light checklist
    // on Tonight. The floating prompt used to be painted over the dashboard as
    // a second, louder copy of the same nudges; the Observatory rebuild dropped
    // it, and this guards the removal.
    // Drop the cosmetic RenderFlex overflow at the cramped test surface; any
    // other Flutter error still trips takeException.
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);

    await pumpAppScreen(
      tester,
      const DashboardScreen(),
      size: const Size(780, 600),
      settle: false,
      extraOverrides: [
        dashboardLayoutProvider
            .overrideWith(_AllDisabledDashboardLayoutNotifier.new),
        nextUsePromptProvider.overrideWithValue(null),
      ],
    );
    // Drive a few frames so dashboardLayoutProvider resolves to data and the
    // Stack commits. pumpAndSettle is unsafe: the status-pulse never settles.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(NextUsePromptCard), findsNothing,
        reason: 'The Tonight page carries no floating setup prompt; the '
            'checklist is the one place a setup problem is stated.');
  });
}
