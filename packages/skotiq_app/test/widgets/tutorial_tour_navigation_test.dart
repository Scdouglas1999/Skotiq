// Starting a Tutorial Tour from Settings > Help left the coach mark on the
// Settings screen: step 1 of Equipment Setup read "Click the Profiles tab",
// there is no Profiles tab on Settings, and the overlay's full-screen scrim
// swallowed the click on the left-nav entry that would have got the operator
// to a screen where the instruction made sense. All four steps behaved that
// way — a slideshow about a screen you were not on and could not reach.
//
// Two things are asserted here, because either one alone leaves the tour
// unusable: the tour must move to the screen it describes, and an un-anchored
// step must not eat input meant for the app underneath.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/widgets/tutorial_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

SkotiqDatabase _newInMemoryDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

/// A shell-shaped app: TutorialOverlay wraps the routed content, exactly as
/// `app_shell.dart` mounts it, so a tour that navigates keeps its overlay.
Future<({ProviderContainer container, GoRouter router, List<String> taps})>
    _pumpShell(WidgetTester tester, {required SkotiqDatabase db}) async {
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
    ],
  );
  addTearDown(container.dispose);

  final taps = <String>[];

  // Top-left, where the left nav lives — the control the operator tried to
  // click in the live repro while the tour overlay was up. The coach-mark card
  // itself owns the middle of the screen by design.
  Widget page(String label) => Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: TextButton(
            onPressed: () => taps.add(label),
            child: Text(label),
          ),
        ),
      );

  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      ShellRoute(
        builder: (context, state, child) => TutorialOverlay(child: child),
        routes: [
          GoRoute(path: '/settings', builder: (_, __) => page('SETTINGS')),
          GoRoute(path: '/equipment', builder: (_, __) => page('EQUIPMENT')),
        ],
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
  await tester.pumpAndSettle(const Duration(seconds: 2));

  return (container: container, router: router, taps: taps);
}

/// Drive enough frames for the provider update, the deferred `go` and the
/// route transition to land.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _location(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('starting a tour opens the screen the tour is about',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(db.close);
    final harness = await _pumpShell(tester, db: db);

    expect(_location(harness.router), '/settings');

    await harness.container
        .read(tutorialProvider.notifier)
        .restartTutorial(TutorialCategory.equipmentSetup);
    // Not pumpAndSettle: the overlay's spotlight ring repeats forever while a
    // tour is running, so nothing ever settles.
    await _pumpFrames(tester);

    expect(
      _location(harness.router),
      '/equipment',
      reason: 'the Equipment Setup tour describes the Equipment screen',
    );
    expect(find.text('Equipment profiles'), findsOneWidget);
  });

  testWidgets('an un-anchored step does not swallow clicks on the app',
      (tester) async {
    final db = _newInMemoryDb();
    addTearDown(db.close);
    final harness = await _pumpShell(tester, db: db);

    await harness.container
        .read(tutorialProvider.notifier)
        .restartTutorial(TutorialCategory.equipmentSetup);
    // Not pumpAndSettle: the overlay's spotlight ring repeats forever while a
    // tour is running, so nothing ever settles.
    await _pumpFrames(tester);

    // Nothing in this stub renders the tour's spotlight target, so the step is
    // un-anchored — the exact case that used to draw a full-screen barrier.
    expect(find.text('EQUIPMENT'), findsOneWidget);
    await tester.tap(find.text('EQUIPMENT'));
    await tester.pump();

    expect(
      harness.taps,
      contains('EQUIPMENT'),
      reason: 'the operator must still be able to use the screen the tour '
          'told them to use',
    );
  });

  group('tour routes', () {
    test('every tour that names a screen resolves a route for step 0', () {
      for (final category in TutorialCategory.values) {
        if (category == TutorialCategory.firstNight) continue;
        final steps = TutorialDefinitions.getStepsForCategory(category);
        expect(steps, isNotEmpty, reason: '$category has no steps');
        expect(
          tutorialRouteForStep(steps.first),
          isNotNull,
          reason: '$category would open on whatever screen the operator is on',
        );
      }
    });

    test('the first-night wizard is deliberately route-less', () {
      final steps =
          TutorialDefinitions.getStepsForCategory(TutorialCategory.firstNight);
      expect(tutorialRouteForStep(steps.first), isNull);
    });
  });
}
