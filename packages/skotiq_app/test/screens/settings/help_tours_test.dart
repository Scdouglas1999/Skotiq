// Settings > Help & tutorials is where every tour that is not about one
// screen is started, resumed and reset.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/settings/widgets/help_tutorials_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_app/tours/tour.dart';
import 'package:skotiq_app/tours/tour_runner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _FailingDao extends TutorialProgressDao {
  _FailingDao(super.db);

  @override
  Future<void> restartProgress(String category) =>
      throw StateError('write failed');
}

class _FailingOnboardingNotifier extends OnboardingNotifier {
  _FailingOnboardingNotifier(super.ref);

  @override
  Future<void> reset() => throw StateError('equipment reset failed');
}

Future<({ProviderContainer container, GoRouter router})> _pumpHelp(
  WidgetTester tester, {
  required SkotiqDatabase db,
  bool failTourWrites = false,
  bool failEquipmentReset = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1400);
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
      if (failTourWrites)
        tutorialProgressDaoProvider.overrideWithValue(_FailingDao(db)),
      if (failEquipmentReset)
        onboardingDraftProvider.overrideWith(
          (ref) => _FailingOnboardingNotifier(ref),
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
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('ONBOARDING_SPINE'))),
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

/// The button of the row titled [title].
Finder _rowButton(String title) => find.descendant(
      of: find
          .ancestor(
            of: find.text(title),
            matching: find.byWidgetPredicate(
              (widget) => widget is SettingRow || widget is Semantics,
            ),
          )
          .first,
      matching: find.byType(SkotiqButton),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('lists the guided flows and every workflow tour', (tester) async {
    await _pumpHelp(tester, db: db);

    expect(find.text('First night walkthrough'), findsOneWidget);
    expect(find.text('Capture your first light'), findsOneWidget);
    expect(find.text('Re-run equipment setup'), findsOneWidget);
    expect(find.text('Re-run onboarding tour'), findsOneWidget);
    for (final tour in Tour.workflows) {
      expect(find.text(tour.title), findsOneWidget);
    }
    expect(find.text('Not started'), findsNWidgets(Tour.workflows.length));
  });

  for (final tour in Tour.workflows) {
    testWidgets('Start on "${tour.title}" runs that tour from its first step',
        (tester) async {
      final harness = await _pumpHelp(tester, db: db);

      await tester.tap(_rowButton(tour.title));
      await tester.pumpAndSettle();

      final run = harness.container.read(tourRunnerProvider);
      expect(run.active, tour);
      expect(run.stepIndex, 0);
    });
  }

  testWidgets('a tour left part-way says so and resumes there', (tester) async {
    final runner = TourRunner(db.tutorialProgressDao);
    await runner.start(Tour.automatedImaging);
    await runner.next();
    await runner.next();
    await runner.skip();
    runner.dispose();

    final harness = await _pumpHelp(tester, db: db);

    expect(
      find.text('2/${Tour.automatedImaging.steps.length} steps'),
      findsOneWidget,
    );
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();

    final run = harness.container.read(tourRunnerProvider);
    expect(run.active, Tour.automatedImaging);
    expect(run.stepIndex, 2);
  });

  testWidgets('a finished tour says Completed and offers Restart',
      (tester) async {
    final runner = TourRunner(db.tutorialProgressDao);
    await runner.start(Tour.calibrationFrames);
    await runner.finish();
    runner.dispose();

    final harness = await _pumpHelp(tester, db: db);

    expect(find.text('Completed'), findsOneWidget);
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();
    expect(
      harness.container.read(tourRunnerProvider).active,
      Tour.calibrationFrames,
    );
    expect(harness.container.read(tourRunnerProvider).stepIndex, 0);
  });

  testWidgets('the walkthrough row opens it, and resumes one left part-way',
      (tester) async {
    final harness = await _pumpHelp(tester, db: db);
    final runner = harness.container.read(tourRunnerProvider.notifier);

    await tester.tap(_rowButton('First night walkthrough'));
    await tester.pumpAndSettle();
    expect(runner.state.active, Tour.firstNight);
    expect(runner.state.stepIndex, 0);

    await runner.next();
    await runner.next();
    runner.close();
    await tester.pumpAndSettle();

    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(runner.state.active, Tour.firstNight);
    expect(runner.state.stepIndex, 2);
  });

  testWidgets('the onboarding tour row starts the onboarding tour',
      (tester) async {
    final harness = await _pumpHelp(tester, db: db);

    await tester.tap(_rowButton('Re-run onboarding tour'));
    await tester.pumpAndSettle();

    expect(
      harness.container.read(tourRunnerProvider).active,
      Tour.firstLaunch,
    );
  });

  testWidgets('a tour that cannot be saved does not start, and says so',
      (tester) async {
    final harness = await _pumpHelp(tester, db: db, failTourWrites: true);

    await tester.tap(_rowButton(Tour.equipmentSetup.title));
    await tester.pumpAndSettle();

    expect(harness.container.read(tourRunnerProvider).active, isNull);
    expect(
      find.text('Could not start Equipment setup. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('an onboarding tour that cannot be saved does not open',
      (tester) async {
    final harness = await _pumpHelp(tester, db: db, failTourWrites: true);

    await tester.tap(_rowButton('Re-run onboarding tour'));
    await tester.pumpAndSettle();
    expect(harness.container.read(tourRunnerProvider).active, isNull);
    expect(
      find.text('Could not open the onboarding tour. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed equipment-setup replay stays put and says so',
      (tester) async {
    final harness = await _pumpHelp(tester, db: db, failEquipmentReset: true);

    await tester.tap(_rowButton('Re-run equipment setup'));
    await tester.pumpAndSettle();

    expect(
      harness.router.routerDelegate.currentConfiguration.uri.path,
      '/help',
    );
    expect(
      find.text('Could not reset equipment setup. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('resetting progress forgets it and brings the welcome tour back',
      (tester) async {
    final seed = TourRunner(db.tutorialProgressDao);
    await seed.start(Tour.calibrationFrames);
    await seed.finish();
    seed.dispose();

    final harness = await _pumpHelp(tester, db: db);
    expect(find.text('Completed'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset').last);
    await tester.pumpAndSettle();

    final run = harness.container.read(tourRunnerProvider);
    expect(run.isCompleted(Tour.calibrationFrames), isFalse);
    expect(find.text('Completed'), findsNothing);
    expect(run.active, Tour.firstLaunch);
    expect(run.stepIndex, 0);
  });
}
