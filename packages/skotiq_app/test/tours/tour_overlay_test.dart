// The one overlay every tour is drawn by. Each test builds a small shell with
// real routes and real tour data, and puts the tour's targets on screen (or
// leaves them off) with the same keys the app's widgets carry.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/tours/tour.dart';
import 'package:skotiq_app/tours/tour_overlay.dart';
import 'package:skotiq_app/tours/tour_runner.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FailingDao extends TutorialProgressDao {
  _FailingDao(super.db);

  bool fail = false;

  @override
  Future<void> saveProgress(String category, int stepIndex) {
    if (fail) throw StateError('write failed');
    return super.saveProgress(category, stepIndex);
  }
}

typedef _Shell = ({
  ProviderContainer container,
  GoRouter router,
  TourRunner runner,
  List<String> taps,
});

/// A shell-shaped app: [TourOverlay] around the routed pages, as the app
/// shell mounts it. [pages] maps a route to its body; routes not named get a
/// page with one button, so a test can tell whether the app under the tour
/// still takes clicks.
Future<_Shell> _pumpShell(
  WidgetTester tester, {
  required SkotiqDatabase db,
  Map<AppRoute, WidgetBuilder> pages = const {},
  Size size = const Size(1280, 900),
  String initialLocation = '/settings',
  TutorialProgressDao? dao,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      if (dao != null) tutorialProgressDaoProvider.overrideWithValue(dao),
    ],
  );
  addTearDown(container.dispose);

  final taps = <String>[];
  Widget plain(AppRoute route) => Align(
        alignment: Alignment.topLeft,
        child: TextButton(
          onPressed: () => taps.add(route.name),
          child: Text('PAGE ${route.name}'),
        ),
      );

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => TourOverlay(child: child),
        routes: [
          for (final route in AppRoute.values)
            if (route.inShell &&
                route.parent == null &&
                !route.onlyRedirects &&
                !route.path.contains(':'))
              GoRoute(
                path: route.path,
                builder: (context, state) => Scaffold(
                  body: pages[route]?.call(context) ?? plain(route),
                ),
              ),
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
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Teardowns run last-registered first: take the overlay down before the
  // container it reads goes away.
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  final runner = container.read(tourRunnerProvider.notifier);
  await runner.ready;
  return (container: container, router: router, runner: runner, taps: taps);
}

/// Tour moves are awaited in the test body, never in `runAsync`: the runner's
/// writes are futures of the fake-async zone and only complete when it runs.
///
/// Enough frames for a move to be saved, the router to change page and an
/// absent target to be judged. Not pumpAndSettle: the pulse ring never
/// settles while a tour is on screen.
Future<void> _pumpFrames(WidgetTester tester, [int frames = 30]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _do(WidgetTester tester, Future<void> Function() move) async {
  await move();
  await _pumpFrames(tester);
}

String _location(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

/// A box carrying [target]'s key, as the app's own widget would.
Widget _anchor(TourTarget target, {double width = 120, double height = 40}) =>
    SizedBox(
      key: target.key,
      width: width,
      height: height,
      child: Text(target.name),
    );

Rect _cardRect(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: find.text('Skip tour').first,
            matching: find.byType(Material),
          )
          .first,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('the absent-target rule', () {
    const steps = [
      TourStep(id: 'a', title: 'A', description: ''),
      TourStep(
        id: 'b',
        title: 'B',
        description: '',
        target: TourTarget.imagingTabBar,
      ),
      TourStep(
        id: 'c',
        title: 'C',
        description: '',
        target: TourTarget.imagingAbortButton,
      ),
      TourStep(
        id: 'd',
        title: 'D',
        description: '',
        target: TourTarget.imagingStatsPanel,
      ),
      TourStep(
        id: 'e',
        title: 'E',
        description: '',
        target: TourTarget.imagingHistogram,
      ),
      TourStep(id: 'f', title: 'F', description: ''),
    ];
    int? landing(int index, TourDirection direction, Set<TourTarget> onShow) =>
        tourStepIndexPastAbsentTarget(
          steps: steps,
          index: index,
          direction: direction,
          isOnShow: onShow.contains,
        );
    const present = {TourTarget.imagingTabBar, TourTarget.imagingHistogram};

    test('a run of absent steps is passed over in one move', () {
      expect(landing(2, TourDirection.forward, present), 4);
      expect(landing(3, TourDirection.forward, present), 4);
    });

    test('going back past absent steps keeps going back', () {
      expect(landing(3, TourDirection.backward, present), 1);
    });

    test('a step whose target is on show stands', () {
      expect(landing(1, TourDirection.forward, present), isNull);
    });

    test('a card with no target always stands', () {
      expect(landing(0, TourDirection.forward, const {}), isNull);
      expect(landing(5, TourDirection.backward, present), isNull);
    });

    test('with nothing on show the rule stands down', () {
      expect(landing(2, TourDirection.forward, const {}), isNull);
    });

    test('the walk stops at the ends', () {
      const lone = [
        TourStep(
          id: 'x',
          title: 'X',
          description: '',
          target: TourTarget.imagingTabBar,
        ),
        TourStep(
          id: 'y',
          title: 'Y',
          description: '',
          target: TourTarget.imagingHistogram,
        ),
      ];
      expect(
        tourStepIndexPastAbsentTarget(
          steps: lone,
          index: 1,
          direction: TourDirection.forward,
          isOnShow: (target) => target == TourTarget.imagingTabBar,
        ),
        isNull,
      );
      expect(
        tourStepIndexPastAbsentTarget(
          steps: lone,
          index: 9,
          direction: TourDirection.forward,
          isOnShow: (_) => true,
        ),
        isNull,
      );
    });
  });

  group('coach marks', () {
    testWidgets('a tour opens the screen and tab its step is about',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      expect(_location(shell.router), '/settings');

      await _do(tester, () => shell.runner.start(Tour.equipmentSetup));

      expect(_location(shell.router), '/equipment?tab=profiles');
      expect(find.text('Equipment profiles'), findsOneWidget);
    });

    testWidgets('a tour that crosses screens follows its steps',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);

      await _do(tester, () => shell.runner.start(Tour.advancedFeatures));
      expect(_location(shell.router), '/settings',
          reason: 'the first step points at the rail, which is everywhere');

      await _do(tester, shell.runner.next);
      expect(_location(shell.router), '/weather');
      await _do(tester, shell.runner.next);
      expect(_location(shell.router), '/analytics');
    });

    testWidgets('a card with nothing to point at leaves the app usable',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.equipmentSetup));

      await tester.tap(find.text('PAGE equipment'));
      await tester.pump();

      expect(shell.taps, contains('equipment'));
    });

    testWidgets('the dim blocks the app and the cutout lets the target through',
        (tester) async {
      var targetTaps = 0;
      final outsideTaps = <String>[];
      final shell = await _pumpShell(
        tester,
        db: db,
        initialLocation: '/imaging',
        pages: {
          AppRoute.imaging: (_) => Stack(
                children: [
                  Positioned(
                    left: 40,
                    top: 40,
                    child: TextButton(
                      onPressed: () => outsideTaps.add('outside'),
                      child: const Text('OUTSIDE'),
                    ),
                  ),
                  Positioned(
                    left: 400,
                    top: 300,
                    child: GestureDetector(
                      onTap: () => targetTaps++,
                      child: _anchor(TourTarget.imagingTabBar),
                    ),
                  ),
                ],
              ),
        },
      );
      await _do(tester, () => shell.runner.start(Tour.imaging));
      await _do(tester, shell.runner.next);
      expect(find.text('View Tabs'), findsOneWidget);

      await tester.tapAt(const Offset(60, 60));
      await tester.tapAt(const Offset(460, 320));
      await tester.pump();

      expect(outsideTaps, isEmpty);
      expect(targetTaps, 1);
    });

    testWidgets('a step whose target is not on screen is never shown',
        (tester) async {
      final shell = await _pumpShell(
        tester,
        db: db,
        initialLocation: '/imaging',
        pages: {
          AppRoute.imaging: (_) => Column(
                children: [
                  _anchor(TourTarget.imagingTabBar),
                  _anchor(TourTarget.imagingPreviewArea),
                  // Zoom controls through loop button are not built at all.
                  _anchor(TourTarget.imagingHistogram),
                ],
              ),
        },
      );
      await _do(tester, () => shell.runner.start(Tour.imaging));
      await _do(tester, shell.runner.next);
      await _do(tester, shell.runner.next);
      expect(shell.runner.state.step!.target, TourTarget.imagingPreviewArea);

      final shown = <String>[];
      await shell.runner.next();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final title = tester
            .widgetList<Semantics>(find.byType(Semantics))
            .map((s) => s.properties.label)
            .whereType<String>()
            .where((label) => label.startsWith('Tutorial: '))
            .firstOrNull;
        if (title != null && !shown.contains(title)) shown.add(title);
      }

      expect(shell.runner.state.step!.target, TourTarget.imagingHistogram);
      expect(shown.last, 'Tutorial: Histogram');
      for (final absent in const [
        'Zoom Controls',
        'Exposure Time',
        'Gain Setting',
        'Filter Selection',
        'Snapshot Button',
        'Loop Capture',
        'Abort Button',
        'Image Statistics',
        'Mount Controls',
        'Focus Controls',
      ]) {
        expect(shown, isNot(contains('Tutorial: $absent')));
      }

      // Back from the landing goes back past the same absent run.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await shell.runner.ready;
      await _pumpFrames(tester);
      expect(shell.runner.state.step!.target, TourTarget.imagingPreviewArea);
    });

    testWidgets('a target kept alive on a hidden tab counts as absent',
        (tester) async {
      final shell = await _pumpShell(
        tester,
        db: db,
        initialLocation: '/imaging',
        pages: {
          AppRoute.imaging: (_) => Column(
                children: [
                  _anchor(TourTarget.imagingTabBar),
                  Expanded(
                    child: IndexedStack(
                      index: 0,
                      children: [
                        const Text('first tab'),
                        _anchor(TourTarget.imagingPreviewArea),
                      ],
                    ),
                  ),
                  Offstage(child: _anchor(TourTarget.imagingZoomControls)),
                  _anchor(TourTarget.imagingExposureSlider),
                ],
              ),
        },
      );
      expect(tourTargetIsOnShow(TourTarget.imagingTabBar), isTrue);
      expect(tourTargetIsOnShow(TourTarget.imagingPreviewArea), isFalse);
      expect(tourTargetIsOnShow(TourTarget.imagingZoomControls), isFalse);

      await _do(tester, () => shell.runner.start(Tour.imaging));
      await _do(tester, shell.runner.next);
      await _do(tester, shell.runner.next);

      expect(shell.runner.state.step!.target, TourTarget.imagingExposureSlider);
    });

    testWidgets('a target scrolled out of view is brought into view',
        (tester) async {
      final shell = await _pumpShell(
        tester,
        db: db,
        initialLocation: '/analytics',
        pages: {
          AppRoute.analytics: (_) => SingleChildScrollView(
                child: Column(
                  children: [
                    _anchor(TourTarget.analyticsSessionTab),
                    const SizedBox(height: 3000),
                    _anchor(TourTarget.analyticsThumbnails),
                  ],
                ),
              ),
        },
      );
      final target = find.byKey(TourTarget.analyticsThumbnails.key);
      expect(tester.getRect(target).top, greaterThan(900));

      await _do(tester, () => shell.runner.start(Tour.analytics));
      await _do(tester, () => shell.runner.goTo(6));

      expect(shell.runner.state.step!.target, TourTarget.analyticsThumbnails);
      final rect = tester.getRect(target);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(900));
      expect(find.text('Captured Images'), findsOneWidget);
    });

    testWidgets('on a phone a rail destination behind More points at More',
        (tester) async {
      await _pumpShell(
        tester,
        db: db,
        size: const Size(420, 900),
        pages: {
          AppRoute.settings: (_) => Align(
                alignment: Alignment.bottomRight,
                child: _anchor(TourTarget.navMore),
              ),
        },
      );
      expect(tourTargetIsOnShow(TourTarget.navEquipment), isTrue);
      expect(tourTargetIsOnShow(TourTarget.navSettings), isFalse);
    });

    for (final size in const [
      Size(1280, 900),
      Size(420, 900),
      Size(360, 520)
    ]) {
      testWidgets(
          'at ${size.width.toInt()}x${size.height.toInt()} every card of '
          'every tour stays inside the window with its buttons',
          (tester) async {
        final shell = await _pumpShell(tester, db: db, size: size);
        final window = Offset.zero & size;
        for (final tour in Tour.values) {
          if (tour.style != TourStyle.coachMarks) continue;
          await _do(tester, () => shell.runner.start(tour));
          for (var i = 0; i < tour.steps.length; i++) {
            await shell.runner.goTo(i);
            // A step on another screen settles once that screen has built.
            await _pumpFrames(tester, 15);
            final card = _cardRect(tester);
            expect(
              window.contains(card.topLeft) &&
                  window.contains(card.bottomRight - const Offset(1, 1)),
              isTrue,
              reason: '${tour.name}/${tour.steps[i].id}: $card in $window',
            );
            expect(find.text('Skip tour').hitTestable(), findsWidgets);
            expect(
              find
                  .text(i == tour.steps.length - 1 ? 'Done' : 'Next')
                  .hitTestable(),
              findsOneWidget,
              reason: '${tour.name}/${tour.steps[i].id}',
            );
          }
          expect(tester.takeException(), isNull, reason: tour.name);
        }
      });
    }

    testWidgets('Next, Back and Skip on the card move the tour',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.tonight));

      Future<void> press(String label) async {
        await tester.tap(find.text(label));
        await shell.runner.ready;
        await _pumpFrames(tester);
      }

      expect(find.text('Back'), findsNothing);
      await press('Next');
      expect(shell.runner.state.stepIndex, 1);
      await press('Back');
      expect(shell.runner.state.stepIndex, 0);
      await press('Next');
      await press('Skip tour');
      expect(shell.runner.state.active, isNull);
      expect(find.text('Skip tour'), findsNothing);
      expect(shell.runner.state.progress[Tour.tonight]!.skipped, isTrue);
    });

    testWidgets('the keyboard drives the tour and Escape always leaves it',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.tonight));

      Future<void> key(LogicalKeyboardKey k) async {
        await tester.sendKeyEvent(k);
        await shell.runner.ready;
        await _pumpFrames(tester);
      }

      await key(LogicalKeyboardKey.enter);
      expect(shell.runner.state.stepIndex, 1);
      await key(LogicalKeyboardKey.arrowRight);
      expect(shell.runner.state.stepIndex, 2);
      await key(LogicalKeyboardKey.backspace);
      expect(shell.runner.state.stepIndex, 1);
      await key(LogicalKeyboardKey.escape);
      expect(shell.runner.state.active, isNull);
    });

    testWidgets('a move that cannot be saved stays put and says so',
        (tester) async {
      final dao = _FailingDao(db);
      final shell = await _pumpShell(tester, db: db, dao: dao);
      await _do(tester, () => shell.runner.start(Tour.tonight));
      dao.fail = true;

      await tester.tap(find.text('Next'));
      await shell.runner.ready;
      await _pumpFrames(tester);

      expect(shell.runner.state.stepIndex, 0);
      expect(find.text('Welcome to Tonight'), findsOneWidget);
      expect(
        find.text('Could not save tutorial progress. Please try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the card says it is live to assistive tech', (tester) async {
      final handle = tester.ensureSemantics();
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.tonight));

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Tutorial step 1 of 6: ')),
      );
      expect(node.flagsCollection.isEnabled.name, 'isTrue');
      handle.dispose();
    });

    testWidgets('no ticker runs once the tour is over', (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.tonight));
      expect(tester.binding.hasScheduledFrame, isTrue);

      await _do(tester, shell.runner.skip);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('the walkthrough', () {
    testWidgets('is a dialog with Next, Back and its own way out',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.firstNight));

      expect(find.text('Welcome to your first night'), findsOneWidget);
      expect(find.text('Step 1 of 7'), findsOneWidget);
      expect(find.textContaining('Show me'), findsNothing);

      await tester.tap(find.text('Next'));
      await shell.runner.ready;
      await tester.pumpAndSettle();
      expect(find.text('1. Connect your equipment'), findsOneWidget);
      expect(find.text('Show me on the Equipment screen'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await shell.runner.ready;
      await tester.pumpAndSettle();
      expect(find.text('Welcome to your first night'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(shell.runner.state.active, isNull);
      expect(find.text('Welcome to your first night'), findsNothing);
    });

    testWidgets('"Show me" opens the screen and leaves a way back',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.firstNight));
      await shell.runner.next();
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Show me on the Equipment screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show me on the Equipment screen'));
      await tester.pumpAndSettle();

      expect(_location(shell.router), '/equipment');
      expect(find.text('1. Connect your equipment'), findsNothing);
      await tester.tap(find.text('PAGE equipment'));
      expect(shell.taps, contains('equipment'),
          reason: 'the parked walkthrough does not cover the screen');

      await tester.tap(find.text('Back to the walkthrough'));
      await tester.pumpAndSettle();
      expect(find.text('1. Connect your equipment'), findsOneWidget);
      expect(shell.runner.state.stepIndex, 1);
    });

    testWidgets('a parked walkthrough can be closed and keeps its step',
        (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.firstNight));
      await shell.runner.next();
      await shell.runner.next();
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.text('Show me on the Polar alignment screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show me on the Polar alignment screen'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(shell.runner.state.active, isNull);
      expect(find.text('Back to the walkthrough'), findsNothing);
      expect(shell.runner.state.stepsDone(Tour.firstNight), 2);
    });

    testWidgets('"Skip forever" and Done end it', (tester) async {
      final shell = await _pumpShell(tester, db: db);
      await _do(tester, () => shell.runner.start(Tour.firstNight));
      await tester.tap(find.text('Skip forever'));
      await shell.runner.ready;
      await tester.pumpAndSettle();
      expect(shell.runner.state.active, isNull);
      expect(shell.runner.state.progress[Tour.firstNight]!.skipped, isTrue);

      await _do(tester, () => shell.runner.start(Tour.firstNight));
      await shell.runner.goTo(6);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await shell.runner.ready;
      await tester.pumpAndSettle();
      expect(shell.runner.state.isCompleted(Tour.firstNight), isTrue);
    });

    testWidgets('fits a phone', (tester) async {
      final shell =
          await _pumpShell(tester, db: db, size: const Size(420, 900));
      await _do(tester, () => shell.runner.start(Tour.firstNight));
      for (var i = 0; i < Tour.firstNight.steps.length; i++) {
        await shell.runner.goTo(i);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'step $i');
        expect(find.text('Skip forever').hitTestable(), findsOneWidget);
      }
    });
  });
}
