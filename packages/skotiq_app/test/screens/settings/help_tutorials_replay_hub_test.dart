// Widget tests for the Help & Tutorials replay hub.
//
// These assert:
//   * the "Capture your first light" and "Re-run equipment setup" replay rows
//     render,
//   * no "Quick Start Tour" step-tour row remains,
//   * "Re-run equipment setup" resets the onboarding draft and routes to the
//     `/onboarding` spine.
//
// The replay-hub providers (tutorialProvider, onboardingDraftProvider) derive
// from databaseProvider/backendProvider, so an in-memory DB + MockBackend is
// enough to resolve the graph. The screen calls `context.go(...)`, which needs
// a real GoRouter ancestor — so this test pumps inside a MaterialApp.router
// rather than the harness's bare MaterialApp.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/settings/widgets/help_tutorials_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _FailingOnboardingNotifier extends OnboardingNotifier {
  _FailingOnboardingNotifier(super.ref);

  @override
  Future<void> reset() async {
    throw StateError('equipment reset failed');
  }
}

class _FailingTutorialNotifier extends TutorialNotifier {
  _FailingTutorialNotifier(super.dao);

  @override
  Future<void> restartTutorial(TutorialCategory category) async {
    throw StateError('tutorial restart failed');
  }
}

class _FailingOnboardingTourNotifier extends OnboardingTourNotifier {
  _FailingOnboardingTourNotifier(Ref ref, TutorialProgressDao progressDao)
      : super(
          dao: FirstLaunchTourDao(progressDao),
          ref: ref,
          totalCoreSteps: onboardingTourCoreStepCount,
        );

  @override
  Future<void> reset() async {
    throw StateError('onboarding tour reset failed');
  }
}

SkotiqDatabase _newInMemoryDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

/// Pump [HelpTutorialsSettings] inside a MaterialApp.router with a `/help`
/// (the screen under test) and a sentinel `/onboarding` route so navigation
/// from the replay rows can be asserted. Returns the container for post-pump
/// provider reads and the router so tests can inspect the current location.
Future<({ProviderContainer container, GoRouter router})> _pumpHelpScreen(
  WidgetTester tester, {
  required SkotiqDatabase db,
  bool failEquipmentReset = false,
  bool failTutorialRestart = false,
  bool failOnboardingTourReset = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, mockBackend()),
      ),
      databaseProvider.overrideWithValue(db),
      appVersionProvider.overrideWithValue(
        const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
      ),
      if (failEquipmentReset)
        onboardingDraftProvider.overrideWith(
          (ref) => _FailingOnboardingNotifier(ref),
        ),
      if (failTutorialRestart)
        tutorialProvider.overrideWith(
          (ref) => _FailingTutorialNotifier(db.tutorialProgressDao),
        ),
      if (failOnboardingTourReset)
        onboardingTourProvider.overrideWith(
          (ref) => _FailingOnboardingTourNotifier(
            ref,
            db.tutorialProgressDao,
          ),
        ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/help',
    routes: [
      GoRoute(
        path: '/help',
        builder: (context, state) =>
            const Scaffold(body: HelpTutorialsSettings()),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('ONBOARDING_SPINE')),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(seconds: 5));

  return (container: container, router: router);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the new first-light + equipment-setup replay rows',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());

    await _pumpHelpScreen(tester, db: db);

    expect(find.text('Capture your first light'), findsOneWidget);
    expect(find.text('Re-run equipment setup'), findsOneWidget);
    // The replay hub still carries the first-night + tour replays.
    expect(find.text('First night walkthrough'), findsOneWidget);
    expect(find.text('Re-run onboarding tour'), findsOneWidget);
  });

  testWidgets('drops the superseded "Quick Start Tour" step-tour row',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());

    await _pumpHelpScreen(tester, db: db);

    // Superseded by the real, camera-driven "Capture your first light" flow.
    expect(find.text('Quick Start Tour'), findsNothing);
    // The other step tours are untouched.
    expect(find.text('Equipment setup'), findsOneWidget);
    expect(find.text('Calibration frames'), findsOneWidget);
  });

  testWidgets(
      '"Re-run equipment setup" resets the draft and routes to /onboarding',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());

    final result = await _pumpHelpScreen(tester, db: db);
    final container = result.container;
    final router = result.router;

    // Dirty the onboarding draft so we can prove the reset ran. The draft
    // notifier hydrates asynchronously; wait for it before mutating so the
    // hydration write doesn't clobber our change.
    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;
    await notifier.setCaptureDirectory('/tmp/first-light-test');
    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      '/tmp/first-light-test',
      reason: 'precondition: the draft is dirty before the reset',
    );

    // Every row in this list starts something, so every row's button is
    // labelled "Start". The row TITLE is what distinguishes them, so target the
    // button inside the equipment-setup row via its SettingRow ancestor
    // title.
    final equipmentRow = find.ancestor(
      of: find.text('Re-run equipment setup'),
      matching: find.byType(SettingRow),
    );
    expect(equipmentRow, findsOneWidget);
    final rerunButton = find.descendant(
      of: equipmentRow,
      matching: find.widgetWithText(SkotiqButton, 'Start'),
    );
    expect(rerunButton, findsOneWidget);

    await tester.tap(rerunButton);
    await tester.pumpAndSettle();

    // Routed to the onboarding spine.
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/onboarding',
    );
    expect(find.text('ONBOARDING_SPINE'), findsOneWidget);

    // The draft was reset (capture directory cleared back to its default).
    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      isNot('/tmp/first-light-test'),
      reason: 'the reset must clear the dirtied draft',
    );
  });

  testWidgets('failed equipment replay stays put and offers retry feedback',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());
    final result = await _pumpHelpScreen(
      tester,
      db: db,
      failEquipmentReset: true,
    );

    final equipmentRow = find.ancestor(
      of: find.text('Re-run equipment setup'),
      matching: find.byType(SettingRow),
    );
    final rerunButton = find.descendant(
      of: equipmentRow,
      matching: find.widgetWithText(SkotiqButton, 'Start'),
    );

    await tester.tap(rerunButton);
    await tester.pumpAndSettle();

    expect(result.router.routeInformationProvider.value.uri.path, '/help');
    expect(
      find.text('Could not reset equipment setup. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('failed tutorial start reports the failure without false launch',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());
    final result = await _pumpHelpScreen(
      tester,
      db: db,
      failTutorialRestart: true,
    );

    final tutorialRow = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Equipment setup tutorial, Not started',
    );
    final startButton = find.descendant(
      of: tutorialRow,
      matching: find.widgetWithText(SkotiqButton, 'Start'),
    );
    await tester.tap(startButton);
    await tester.pumpAndSettle();

    expect(result.router.routeInformationProvider.value.uri.path, '/help');
    expect(
      find.text('Could not start Equipment setup. Please try again.'),
      findsOneWidget,
    );
    expect(
      result.container.read(tutorialProvider).activeCategory,
      isNull,
    );
  });

  testWidgets('failed onboarding-tour replay remains retryable',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(() async => db.close());
    final result = await _pumpHelpScreen(
      tester,
      db: db,
      failOnboardingTourReset: true,
    );

    final tourRow = find.ancestor(
      of: find.text('Re-run onboarding tour'),
      matching: find.byType(SettingRow),
    );
    final rerunButton = find.descendant(
      of: tourRow,
      matching: find.widgetWithText(SkotiqButton, 'Start'),
    );
    await tester.tap(rerunButton);
    await tester.pumpAndSettle();

    expect(result.router.routeInformationProvider.value.uri.path, '/help');
    expect(
      find.text('Could not restart the onboarding tour. Please try again.'),
      findsOneWidget,
    );
  });
}
