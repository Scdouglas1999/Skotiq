// Tab-wiring tests for the multi-night planner.
//
// These complement `planner_screen_test.dart` (which covers the pre-existing
// Recommendation / Target Queue / Progress tabs) by asserting the *new* wiring:
// the Projects and This Week tabs, their `?tab=` deep-links, and the
// structural invariant that the rendered tab list and the IndexedStack child
// list stay in lockstep with the `PlannerTab` enum (the selected index is
// `PlannerTab.index`, so any drift mis-routes deep-links and taps).
//
// The planner body is an IndexedStack, which builds *every* child eagerly, so
// the leaf providers each tab reads must resolve without a real drift database
// or HTTP client. We override exactly those leaves with deterministic doubles,
// mirroring the override set in `planner_screen_test.dart` and the per-tab
// tests (`projects_tab_content_test.dart`, `week_forecast_strip_test.dart`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/screens/planner/planner_route.dart';

import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_app/screens/planner/widgets/projects_tab_content.dart';
import 'package:skotiq_app/screens/planner/widgets/scheduler_tab_content.dart';
import 'package:skotiq_app/screens/planner/widgets/progress_tab_content.dart';
import 'package:skotiq_app/screens/planner/widgets/week_forecast_strip.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../scheduler/scheduler_test_doubles.dart';

/// Stub AppSettingsNotifier with a real lat/lon so the planner's location
/// guard short-circuits without hitting the DB (the new forecast tab uses the
/// same guard). Mirrors the stub in `planner_screen_test.dart`.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    return const AppSettingsState(latitude: 40.0, longitude: -75.0);
  }
}

/// The full leaf-override set for pumping the whole [PlannerScreen]. Every tab
/// in the IndexedStack is built eagerly, so all five tabs' leaf providers are
/// stubbed here.
List<Override> _allTabOverrides() {
  return [
    // Recommendation tab.
    tonightSuggestionsProvider.overrideWith((ref) async => const []),
    smartNightExposureContextProvider.overrideWith((ref) async => null),
    appSettingsProvider.overrideWith(() => _StubAppSettingsNotifier()),
    // Progress tab.
    allTargetProgressProvider.overrideWith(
      (ref) async => <int, TargetProgress>{},
    ),
    // Target Queue (scheduler) tab.
    schedulerEngineProvider.overrideWithValue(buildTestSchedulerEngine()),
    schedulerStatusProvider.overrideWith(
      (ref) => FakeSchedulerStatusNotifier(
        const SchedulerStatus(state: SchedulerState.idle),
      ),
    ),
    currentSchedulerDecisionProvider.overrideWith(
      (ref) => FakeCurrentSchedulerDecisionNotifier(null),
    ),
    allIntegrationGoalsProvider
        .overrideWith((ref) async => <IntegrationGoal>[]),
    integrationGoalProgressProvider
        .overrideWith((ref, _) async => <IntegrationGoalProgress>[]),
    // Projects tab.
    projectListProvider.overrideWith((ref) => Stream.value(const <Project>[])),
    activeProjectProgressProvider.overrideWith((ref) async => null),
    // This Week tab (C10) — fail-closed forecast double, no HTTP.
    weekForecastProvider.overrideWith(
      (ref) async => const WeekForecast.unavailable(
        'Forecast disabled in tab-structure tests.',
      ),
    ),
  ];
}

/// [linkWord] is the `?tab=` word a link carries, read the way the router
/// reads it.
Widget _harness({PlannerTab? initialTab, String? linkWord}) {
  return ProviderScope(
    overrides: [..._allTabOverrides()],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: PlannerScreen(
          initialTab: initialTab ?? PlannerTab.fromQuery(linkWord),
        ),
      ),
    ),
  );
}

/// Index of the planner tab matching [label], per the rendered tab order.
int _tabIndex(String label) {
  const order = <String>[
    'Tonight',
    'Projects',
    'Schedule',
    'Framing',
    'Planetarium',
    'Your sky',
  ];
  final i = order.indexOf(label);
  if (i < 0) throw ArgumentError('Unknown planner tab label: $label');
  return i;
}

/// The live [AdaptiveTabBar.selectedIndex] — the single source of truth for
/// which planner tab is active.
int _selectedTabIndex(WidgetTester tester) =>
    tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar)).selectedIndex;

/// Asserts that the tab labelled [label] is the selected one.
void _expectSelected(WidgetTester tester, String label) {
  expect(_selectedTabIndex(tester), _tabIndex(label));
}

/// Taps a planner tab by its label.
///
/// The strip is horizontally scrollable (05 §4 keeps its overflow behaviour),
/// and inside `PageHeader` it is handed only a share of the header's free
/// width, so a tab near the end can be scrolled out of view. Bring it in before
/// tapping, or the gesture lands on the clip and the selection never changes.
Future<void> _tapTab(WidgetTester tester, String label) async {
  final bar = find.byType(AdaptiveTabBar);
  final tab = find.descendant(of: bar, matching: find.text(label));
  final strip =
      find.descendant(of: bar, matching: find.byType(Scrollable)).first;

  // Scroll the strip until the tab is WHOLLY inside it, re-measuring each
  // time. `ensureVisible` alone is not enough: the bar re-measures its edge
  // affordances in a post-frame callback, and showing or hiding a chevron
  // changes the viewport width, which moves every tab out from under the tap
  // point that was just computed.
  // Fixed pumps, never `pumpAndSettle`: the planner runs a 1s sky clock that
  // never goes quiet, so settling here times out rather than waiting for the
  // scroll.
  for (var attempt = 0; attempt < 12; attempt++) {
    await tester.pump(const Duration(milliseconds: 120));
    final barRect = tester.getRect(bar);
    final tabRect = tester.getRect(tab);
    if (tabRect.left >= barRect.left && tabRect.right <= barRect.right) break;
    await tester.drag(strip, const Offset(-80, 0));
  }

  await tester.pump(const Duration(milliseconds: 120));
  await tester.tap(tab);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlannerTab.fromQuery — consolidated Projects + Schedule wiring', () {
    test('maps Projects + the folded Progress aliases', () {
      // Projects now absorbs the former standalone Progress tab, so its legacy
      // deep-links resolve onto Projects (the all-targets scope).
      expect(PlannerTab.fromQuery('projects'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('project'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('campaign'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('campaigns'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('progress'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('history'), PlannerTab.projects);
    });

    test('maps Schedule + the folded Target Queue / This Week aliases', () {
      // Schedule unifies the former Target Queue scheduler and This Week
      // forecast, so all of their legacy deep-links resolve onto Schedule.
      expect(PlannerTab.fromQuery('schedule'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('scheduler'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('queue'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('target-queue'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('week'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('forecast'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('thisweek'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('this-week'), PlannerTab.schedule);
    });

    test('is case-insensitive for the consolidated tabs', () {
      expect(PlannerTab.fromQuery('Projects'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('CAMPAIGNS'), PlannerTab.projects);
      expect(PlannerTab.fromQuery('Week'), PlannerTab.schedule);
      expect(PlannerTab.fromQuery('This-Week'), PlannerTab.schedule);
    });

    test('still maps the pre-existing tabs (no regression)', () {
      expect(PlannerTab.fromQuery('recommendation'), PlannerTab.recommendation);
      expect(PlannerTab.fromQuery('framing'), PlannerTab.framing);
      expect(PlannerTab.fromQuery('planetarium'), PlannerTab.planetarium);
    });

    test('returns null for junk and for null', () {
      expect(PlannerTab.fromQuery(null), isNull);
      expect(PlannerTab.fromQuery(''), isNull);
      expect(PlannerTab.fromQuery('weeky'), isNull);
      expect(PlannerTab.fromQuery('project-x'), isNull);
      expect(PlannerTab.fromQuery('not-a-tab'), isNull);
    });

    test('enum declares the intended planning-to-execution order', () {
      // Recommendation → the consolidated Projects (campaign + all-targets
      // progress) → Schedule (forecast + queue) → the sky-work tabs (Framing,
      // Planetarium) → Discover. Guards against an accidental reorder of the
      // enum — the selected index is PlannerTab.index.
      expect(
        PlannerTab.values,
        const [
          PlannerTab.recommendation,
          PlannerTab.projects,
          PlannerTab.schedule,
          PlannerTab.framing,
          PlannerTab.planetarium,
          PlannerTab.discover,
        ],
      );
    });
  });

  group('PlannerScreen tab structure', () {
    void sizeDesktop(WidgetTester tester) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets(
        'tab list length and IndexedStack child count both equal '
        'PlannerTab.values.length (enum/list drift guard)', (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness());
      await tester.pump(const Duration(milliseconds: 200));

      // One AdaptiveTab per enum value in the single tab bar.
      expect(find.byType(AdaptiveTabBar), findsOneWidget);
      final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
      expect(
        bar.tabs.length,
        PlannerTab.values.length,
        reason: 'The rendered tab strip must have exactly one tab per '
            'PlannerTab value; a mismatch means the tabs list drifted from '
            'the enum.',
      );

      // One IndexedStack child per enum value. A tab body may nest its own
      // IndexedStack (the embedded scheduler; the Framing/Planetarium/Discover
      // views), so identify the planner's top-level stack as the one whose
      // children include the TickerMode wrappers that gate the heavy live-sky
      // views (Framing/Planetarium/Discover) — those wrappers are unique to the
      // planner's own stack. IndexedStack keeps unselected children mounted but
      // Offstage, so we inspect the widget config directly rather than rely on
      // rendered descendants.
      final plannerStack = tester
          .widgetList<IndexedStack>(
            find.byType(IndexedStack, skipOffstage: false),
          )
          .singleWhere(
            (s) => s.children.any((c) => c is TickerMode),
            orElse: () => throw StateError(
              'No IndexedStack holds the planner tab bodies.',
            ),
          );
      expect(
        plannerStack.children.length,
        PlannerTab.values.length,
        reason: 'The IndexedStack must hold exactly one child per PlannerTab '
            'value; the selected index is PlannerTab.index, so a missing or '
            'extra child mis-routes the body for some tab.',
      );

      // Projects is built eagerly (Offstage when not selected) in its campaign
      // scope, so ProjectsTabContent is built, not the all-targets
      // ProgressTabContent. Schedule reads host state, so it is built only
      // while selected.
      expect(
        find.byType(ProjectsTabContent, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byType(SchedulerTabContent, skipOffstage: false),
        findsNothing,
      );
      // ProgressTabContent is the Projects tab's *other* scope — not built until
      // the user switches to "All Targets". WeekForecastStrip only mounts atop
      // the scheduler when the forecast has rankable nights (here the forecast
      // double is unavailable), so neither is present in the default state.
      expect(
        find.byType(ProgressTabContent, skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byType(WeekForecastStrip, skipOffstage: false),
        findsNothing,
      );
    });

    // Read from code and seen on Analytics: after the tab was changed by
    // hand the location still named the link's tab, so the same link again
    // went nowhere.
    testWidgets('a link to a tab works again after the tab was changed by hand',
        (tester) async {
      sizeDesktop(tester);
      final router = GoRouter(
        initialLocation: AppRoutes.planner(tab: PlannerTab.projects),
        routes: [
          GoRoute(
            path: AppRoute.planner.path,
            builder: (context, state) => Scaffold(
              body: PlannerScreen(
                initialTab:
                    PlannerTab.fromQuery(state.uri.queryParameters['tab']),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [..._allTabOverrides()],
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      _expectSelected(tester, 'Projects');

      await tester.tap(find.text('Schedule').first);
      await tester.pump(const Duration(milliseconds: 200));
      _expectSelected(tester, 'Schedule');

      router.go(AppRoutes.planner(tab: PlannerTab.projects));
      await tester.pump(const Duration(milliseconds: 200));
      _expectSelected(tester, 'Projects');
    });

    testWidgets('?tab=projects selects the Projects tab on initial render',
        (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness(linkWord: 'projects'));
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Projects');
    });

    testWidgets('?tab=campaigns alias selects the Projects tab',
        (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness(linkWord: 'campaigns'));
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Projects');
    });

    testWidgets('?tab=week (folded) selects the Schedule tab on initial render',
        (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness(linkWord: 'week'));
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Schedule');
    });

    testWidgets('?tab=forecast alias selects the Schedule tab', (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness(linkWord: 'forecast'));
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Schedule');
    });

    testWidgets('junk ?tab= falls back to the default Recommendation tab',
        (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness(linkWord: 'not-a-tab'));
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Tonight');
    });

    testWidgets('tapping the Schedule tab switches the selection',
        (tester) async {
      // Covers the user-gesture path (onSelected -> setState) for a
      // consolidated tab specifically: a regression that wired the label but
      // dropped the entry's onSelected would still pass the deep-link tests.
      sizeDesktop(tester);
      await tester.pumpWidget(_harness());
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Tonight');

      await _tapTab(tester, 'Schedule');
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Schedule');
    });

    testWidgets('tapping the Projects tab switches the selection',
        (tester) async {
      sizeDesktop(tester);
      await tester.pumpWidget(_harness());
      await tester.pump(const Duration(milliseconds: 200));

      await _tapTab(tester, 'Projects');
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Projects');
    });
  });

  // A companion's Schedule and Your sky tabs poll the imaging host while
  // mounted, so a hidden tab must not be mounted at all.
  group('Planner hidden tabs read no host state', () {
    testWidgets('Your sky atlas readers run only while the tab is shown',
        (tester) async {
      var regionBuilds = 0;
      var coverageBuilds = 0;
      var disposed = 0;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          ..._allTabOverrides(),
          skyAtlasRegionsProvider.overrideWith((ref) {
            regionBuilds++;
            ref.onDispose(() => disposed++);
            return Stream.value(const <SkyAtlasRegionRow>[]);
          }),
          skyAtlasCoverageProvider.overrideWith((ref) {
            coverageBuilds++;
            ref.onDispose(() => disposed++);
            return Stream.value(const <AtlasTileCoverage>[]);
          }),
          skyAtlasTotalsProvider.overrideWith((ref) async => null),
          skyAtlasEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      _expectSelected(tester, 'Tonight');
      expect(regionBuilds, 0);
      expect(coverageBuilds, 0);

      await _tapTab(tester, 'Your sky');
      await tester.pump(const Duration(milliseconds: 200));
      _expectSelected(tester, 'Your sky');
      expect(regionBuilds, 1);
      expect(coverageBuilds, 1);

      await _tapTab(tester, 'Planetarium');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      _expectSelected(tester, 'Planetarium');
      expect(disposed, 2, reason: 'leaving the tab releases both readers');
    });
  });

  // Phone responsiveness: the five-tab bar must not overflow on a phone in
  // either orientation, and every tab must remain reachable (the bar scrolls).
  group('Planner phone responsiveness (AdaptiveTabBar)', () {
    const phoneSizes = <Size>[
      Size(360, 640),
      Size(390, 844),
      Size(430, 932),
      Size(640, 360),
      Size(844, 390),
      Size(932, 430),
    ];

    for (final size in phoneSizes) {
      testWidgets(
          'no overflow + five-tab bar present at ${size.width}x${size.height}',
          (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(_harness());
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byType(AdaptiveTabBar), findsOneWidget);
        final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
        expect(bar.tabs.length, PlannerTab.values.length);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
        'right-most Discover tab is reachable at 360px (bar scrolls it into '
        'view)', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(_harness());
      await tester.pump(const Duration(milliseconds: 200));

      final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
      bar.onSelected(PlannerTab.discover.index);
      await tester.pump(const Duration(milliseconds: 300));

      _expectSelected(tester, 'Your sky');
      expect(tester.takeException(), isNull);
    });
  });
}
