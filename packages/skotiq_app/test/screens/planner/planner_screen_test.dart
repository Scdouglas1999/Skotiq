// Tests for the Plan Tonight screen tab structure, Scheduler tab included. The
// full Riverpod graph requires a real drift database and FFI backend, so we
// override the providers each tab actually reads with deterministic test
// doubles.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_app/screens/framing/altitude_chart.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_app/screens/suggestions/widgets/transient_alerts_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../scheduler/scheduler_test_doubles.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void use(SkotiqBackend backend) => state = backend;
}

List<Override> _commonOverrides() {
  final settingsDao = _MockSettingsDao();
  when(settingsDao.getAllSettings).thenAnswer((_) async => <String, String>{});
  when(() => settingsDao.getSetting(any())).thenAnswer((_) async => null);
  when(() => settingsDao.setSetting(any(), any())).thenAnswer((_) async {});

  return [
    // Recommendation tab dependencies — empty pool so the loading state
    // resolves quickly into the "no candidates" empty state without
    // touching the database.
    tonightSuggestionsProvider.overrideWith((ref) async => const []),
    smartNightExposureContextProvider.overrideWith((ref) async => null),
    appSettingsProvider.overrideWith(() => _StubAppSettingsNotifier()),
    settingsDaoProvider.overrideWithValue(settingsDao),
    loggingServiceProvider.overrideWithValue(_MockLogger()),
    activeTransientAlertsProvider.overrideWith(
      (ref) => Stream.value(const <TransientAlert>[]),
    ),
    // Progress tab dependency.
    allTargetProgressProvider.overrideWith(
      (ref) async => <int, TargetProgress>{},
    ),
    // Scheduler tab dependencies (mirror the scheduler_screen tests).
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
    // Projects tab + This Week tab dependencies. The planner body
    // is an IndexedStack, which builds *every* child eagerly regardless of the
    // selected tab, so these leaf providers must resolve without a DB / HTTP
    // client even when the test only asserts on the Recommendation tab.
    projectListProvider.overrideWith((ref) => Stream.value(const <Project>[])),
    activeProjectProgressProvider.overrideWith((ref) async => null),
    weekForecastProvider.overrideWith(
      (ref) async => const WeekForecast.unavailable(
        'Forecast disabled in tab-structure tests.',
      ),
    ),
  ];
}

/// Stub AppSettingsNotifier that immediately provides a known-good config
/// so the planner's location-check guard short-circuits without hitting
/// the DB. We give it a real lat/lon so the screen does not surface the
/// "set your location" error state and confuse the tab-structure assertions.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    return const AppSettingsState(
      latitude: 40.0,
      longitude: -75.0,
    );
  }
}

/// The live [AdaptiveTabBar.selectedIndex] — the single source of truth for
/// which planner tab is active.
int _selectedTabIndex(WidgetTester tester) =>
    tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar)).selectedIndex;

/// Opens the observing-list dialog.
///
/// A candidate row carries ONE button (05 §9) and the SELECTED row spends it on
/// "Image tonight", so the list lives on the detail column's field preview,
/// where every target can reach it — including the only one when the list holds
/// a single candidate.
Future<void> _openObservingListDialog(WidgetTester tester) async {
  // By SEMANTICS, not `byTooltip`: SkotiqIconButton wraps its glyph in a
  // SkotiqTooltip, which is not Material's Tooltip, and publishes the
  // words on the node instead.
  final button = find.bySemanticsLabel('Add to observing list');
  await tester.ensureVisible(button.first);
  await tester.pump();
  await tester.tap(button.first);
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
  setUpAll(() => registerFallbackValue(''));

  testWidgets('catalog search fits above a compact landscape keyboard',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(932, 430);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const PlannerScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final search = find.widgetWithText(TextField, 'Search catalogs');
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 230);
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(search.hitTestable(), findsOneWidget);
    expect(find.byType(AdaptiveTabBar), findsNothing);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'catalog search fits when an outer shell consumes keyboard insets',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(932, 430);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                // The outer planner tab strip consumes 52 px, leaving the
                // Recommendation tab the same 34 px production slot measured
                // after the shared shell resizes for the keyboard.
                height: 86,
                child: PlannerScreen(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final search = find.widgetWithText(TextField, 'Search catalogs');
    expect(tester.takeException(), isNull);
    expect(search.hitTestable(), findsOneWidget);
    // The Observatory search field is the shared SkotiqTextField in its
    // dense form (05 §8: 32 normal, 28 dense), so a 34px slot still holds it.
    // Measured on the field, not on the Material `TextField` inside it: the
    // well sizes itself and gives the editable a bare line-height slot, so the
    // inner box reports the 14px text line rather than the control's height.
    expect(
      tester
          .getSize(
            find.ancestor(
              of: search,
              matching: find.byType(SkotiqTextField),
            ),
          )
          .height,
      fieldHeightDense,
    );

    await settleProviderTeardown(tester);
  });

  group('plannerTabFromQuery', () {
    test('returns null for null input', () {
      expect(plannerTabFromQuery(null), isNull);
    });

    test('returns null for an unrecognised value', () {
      expect(plannerTabFromQuery('made-up-tab'), isNull);
    });

    test('maps canonical tab names', () {
      expect(plannerTabFromQuery('recommendation'), PlannerTab.recommendation);
      // Scheduler folded into Schedule; Progress folded into Projects.
      expect(plannerTabFromQuery('scheduler'), PlannerTab.schedule);
      expect(plannerTabFromQuery('progress'), PlannerTab.projects);
    });

    test('accepts case-insensitive aliases', () {
      expect(plannerTabFromQuery('Scheduler'), PlannerTab.schedule);
      expect(plannerTabFromQuery('queue'), PlannerTab.schedule);
      expect(plannerTabFromQuery('target-queue'), PlannerTab.schedule);
      expect(plannerTabFromQuery('history'), PlannerTab.projects);
      expect(plannerTabFromQuery('recommend'), PlannerTab.recommendation);
    });

    test('Recommendation is the first enum entry', () {
      expect(
        PlannerTab.values.first,
        PlannerTab.recommendation,
        reason:
            'UX consolidation places Recommendation as the default leftmost '
            'tab so the previous Plan Tonight body remains the landing page.',
      );
    });
  });

  testWidgets(
      'renders all sub-tabs (Tonight, Projects, Schedule, '
      'Framing, Planetarium, Your sky)', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // The tab strip is now an AdaptiveTabBar; on this 1400px desktop viewport
    // labels render as Text (icons-only collapse only happens below 480px).
    expect(find.byType(AdaptiveTabBar), findsOneWidget);
    final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
    expect(
      bar.tabs.map((t) => t.label).toList(),
      const [
        'Tonight',
        'Projects',
        'Schedule',
        'Framing',
        'Planetarium',
        'Your sky',
      ],
    );

    await settleProviderTeardown(tester);
  });

  testWidgets('defaults to Recommendation when no query param is supplied',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(_selectedTabIndex(tester), PlannerTab.recommendation.index);

    await settleProviderTeardown(tester);
  });

  // 06 SS Plan moves the transient-alerts card OFF this tab: it is a feed about
  // the sky, not a planning control, and it lives on Analytics > Science >
  // Transients (reachable from the top bar's alert action). The check is that
  // the Tonight tab no longer carries a second alerts surface.
  testWidgets('Tonight no longer carries the transient-alerts card',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(TransientAlertsPanel), findsNothing);
    expect(find.text('Transient Alerts'), findsNothing);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      '?tab=scheduler (folded) selects the Schedule tab on initial '
      'render', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PlannerScreen(initialTabQuery: 'scheduler'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(_selectedTabIndex(tester), PlannerTab.schedule.index);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      '?tab=progress (folded) selects the Projects tab on initial '
      'render', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PlannerScreen(initialTabQuery: 'progress'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(_selectedTabIndex(tester), PlannerTab.projects.index);

    await settleProviderTeardown(tester);
  });

  // Behavior tests beyond initial selection.

  testWidgets(
      'tapping_Target_Queue_tab_switches_selection_away_from_Recommendation: '
      'verifies setState pathway flips _currentSubTab when a sibling tab is '
      'tapped', (tester) async {
    // The initial-selection tests cover where the screen lands at first
    // pump; this one covers the *user gesture* path through
    // SubTabButton.onTap → setState. A regression that left
    // SubTabButton.isSelected wired correctly but broke the tap callback
    // (e.g. by routing the tap through a stale closure) would still pass
    // the static "?tab=" tests but silently freeze the user on whichever
    // tab they landed on.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Pre-condition: Recommendation selected by default.
    expect(_selectedTabIndex(tester), PlannerTab.recommendation.index,
        reason: 'Sanity: Recommendation must be selected by default.');

    // Tap Schedule. find.text matches the tab's label text.
    await _tapTab(tester, 'Schedule');
    await tester.pump(const Duration(milliseconds: 200));

    // Post-condition: Schedule is selected (single-selection model).
    expect(_selectedTabIndex(tester), PlannerTab.schedule.index,
        reason: 'Tapping the Schedule tab must mark it as selected; if the '
            'onSelected callback or setState pathway is broken the strip would '
            'continue to show Recommendation as selected.');

    await settleProviderTeardown(tester);
  });

  testWidgets('tapping the right-most Discover tab switches the selection',
      (tester) async {
    // Companion to the Schedule tap test — covers the right-most tab and
    // proves the tap callback works for every entry, not just a middle one. A
    // regression that dropped the last entry's onSelected (e.g. a missing index
    // in the asMap().entries loop) would pass the Schedule test but fail here.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // Tap Discover (the right-most tab).
    await _tapTab(tester, 'Your sky');
    await tester.pump(const Duration(milliseconds: 200));

    expect(_selectedTabIndex(tester), PlannerTab.discover.index,
        reason: 'Tapping Discover must mark it as selected; if the right-most '
            'entry in the tabs loop lost its onSelected, the user gets stuck '
            'on Recommendation.');

    await settleProviderTeardown(tester);
  });

  testWidgets('the selected target exposes a Frame it action', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 7,
      targetName: 'North America Nebula',
      raHours: 20.98,
      decDegrees: 44.33,
      totalScore: 91,
      visibility: TargetVisibilityInfo(
        currentAltitude: 62,
        currentAzimuth: 120,
        airmass: 1.1,
        moonDistance: 110,
        peakAltitude: 75,
        hoursAboveMinAlt: 5.5,
      ),
      objectType: 'Emission Nebula',
      magnitude: 4.0,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    // The recommendation body only renders once the async settings stub has
    // resolved: appSettingsProvider (Future) -> appObserverLocationProvider ->
    // _plannerOptimizationProvider. On the very first frame the location is
    // still null, so the optimization provider throws StateError and the tab
    // shows the "Location not configured" error state. A second pump lets the
    // settings future complete so the candidate/recommendation rows build.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 06 SS Plan gives the detail column ONE pair of actions - "Frame it" and
    // the page's single primary "Build sequence" - instead of repeating a
    // framing button on the hero AND on every candidate row.
    expect(
      find.widgetWithText(SkotiqButton, 'Frame it'),
      findsOneWidget,
      reason: 'the selected target must still reach the framing surface',
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Build sequence'),
      findsOneWidget,
      reason: 'the page has exactly one primary action',
    );

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'every candidate row carries its own action, not only the top one',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Two distinct suggestions so the optimizer promotes one to the primary
    // card while the other only ever appears as a candidate row. Candidate rows
    // need their own path to the sequencer, or only the top recommendation is
    // reachable.
    const primary = TargetSuggestion(
      targetId: 11,
      targetName: 'North America Nebula',
      raHours: 20.98,
      decDegrees: 44.33,
      totalScore: 95,
      visibility: TargetVisibilityInfo(
        currentAltitude: 62,
        currentAzimuth: 120,
        airmass: 1.1,
        moonDistance: 110,
        peakAltitude: 75,
        hoursAboveMinAlt: 5.5,
      ),
      objectType: 'Emission Nebula',
      magnitude: 4.0,
    );
    const secondary = TargetSuggestion(
      targetId: 12,
      targetName: 'Pelican Nebula',
      raHours: 20.85,
      decDegrees: 44.36,
      totalScore: 80,
      visibility: TargetVisibilityInfo(
        currentAltitude: 60,
        currentAzimuth: 122,
        airmass: 1.15,
        moonDistance: 108,
        peakAltitude: 73,
        hoursAboveMinAlt: 5.2,
      ),
      objectType: 'Emission Nebula',
      magnitude: 8.0,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider
              .overrideWith((ref) async => [primary, secondary]),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    // Second pump drains the async settings -> location -> optimization chain
    // so the candidate rows build instead of the location-error fallback.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 05 SS9 gives a candidate ONE button. The top row's is the "do it now"
    // action; every other row parks the target. Neither is the page's primary,
    // and no row is left without a way to act on it.
    expect(
      find.widgetWithText(SkotiqButton, 'Image tonight'),
      findsOneWidget,
      reason: 'the top candidate carries the do-it-now action',
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Add'),
      findsOneWidget,
      reason: 'the other candidate is not stranded without an action',
    );

    await settleProviderTeardown(tester);
  });

  testWidgets('the selected target shows its altitude, with no expand toggle',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 42,
      targetName: 'Andromeda Galaxy',
      raHours: 0.67,
      decDegrees: 41.27,
      totalScore: 88,
      visibility: TargetVisibilityInfo(
        currentAltitude: 55,
        currentAzimuth: 180,
        airmass: 1.2,
        moonDistance: 90,
        peakAltitude: 70,
        hoursAboveMinAlt: 6.0,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    // Second pump drains the async settings -> location -> optimization chain
    // so the candidate rows build instead of the location-error fallback.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Show altitude curve'), findsNothing);
    expect(find.text('Hide altitude curve'), findsNothing);
    // 06 SS Plan puts ONE 110px altitude well in the detail column. The old
    // layout repeated a full AltitudeChart on the hero AND on every candidate
    // row, which is the same measurement stated N+1 times.
    expect(
      find.byType(AltitudeChart),
      findsNothing,
      reason: 'the Framing tab owns the full altitude instrument, not a row',
    );
    // The four readouts above the well state the same night in figures, so the
    // curve is never the only place a number lives.
    expect(find.text('ALT NOW'), findsOneWidget);
    expect(find.text('WINDOW'), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'candidate create-and-add rolls back a partial list and keeps the dialog open',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 51,
      targetName: 'Rosette Nebula',
      raHours: 6.55,
      decDegrees: 5.0,
      totalScore: 86,
      visibility: TargetVisibilityInfo(
        currentAltitude: 50,
        currentAzimuth: 170,
        airmass: 1.3,
        moonDistance: 100,
        peakAltitude: 63,
        hoursAboveMinAlt: 4.5,
      ),
      catalogId: 'NGC 2237',
      objectType: 'Emission Nebula',
      magnitude: 9.0,
      sizeArcmin: 80,
    );
    final backend = _MockNetworkBackend();
    when(
      () => backend.createObservingList(
        name: 'Winter targets',
        description: null,
      ),
    ).thenAnswer((_) async => 77);
    when(
      () => backend.addObservingListItem(
        listId: 77,
        objectName: 'Rosette Nebula',
        catalogId: 'NGC 2237',
        objectType: 'Emission Nebula',
        ra: 6.55,
        dec: 5.0,
        magnitude: 9.0,
        sizeArcmin: 80,
        notes: null,
      ),
    ).thenThrow(StateError('host item write failed'));
    when(() => backend.deleteObservingList(77)).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          observingListsProvider.overrideWith(
            (ref) => Stream.value(const <ObservingList>[]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await _openObservingListDialog(tester);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Create new list…'),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Winter targets');
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Create and add'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'A failed combined mutation must remain retryable.');
    expect(
      find.textContaining('Failed to create list and add target'),
      findsOneWidget,
    );
    verify(() => backend.deleteObservingList(77)).called(1);
    expect(tester.takeException(), isNull);

    await settleProviderTeardown(tester);
  });

  testWidgets('candidate add dialog closes on host switch without touching B',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 52,
      targetName: 'Andromeda Galaxy',
      raHours: 0.71,
      decDegrees: 41.27,
      totalScore: 90,
      visibility: TargetVisibilityInfo(
        currentAltitude: 58,
        currentAzimuth: 190,
        airmass: 1.2,
        moonDistance: 95,
        peakAltitude: 72,
        hoursAboveMinAlt: 6,
      ),
      catalogId: 'M31',
      objectType: 'Galaxy',
      magnitude: 3.4,
      sizeArcmin: 190,
    );
    final now = DateTime.utc(2026, 7, 13);
    final list = ObservingList(
      id: 5,
      name: 'Galaxies',
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final pending = Completer<int>();
    when(
      () => hostA.addObservingListItem(
        listId: 5,
        objectName: 'Andromeda Galaxy',
        catalogId: 'M31',
        objectType: 'Galaxy',
        ra: 0.71,
        dec: 41.27,
        magnitude: 3.4,
        sizeArcmin: 190,
        notes: null,
      ),
    ).thenAnswer((_) => pending.future);
    late _SwappableBackendNotifier backendNotifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
          backendProvider.overrideWith(
            (ref) => backendNotifier = _SwappableBackendNotifier(ref, hostA),
          ),
          observingListsProvider.overrideWith(
            (ref) => Stream.value([list]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await _openObservingListDialog(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Galaxies'));
    await tester.pump();

    backendNotifier.use(hostB);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    pending.complete(92);
    await tester.pump();
    verifyNever(
      () => hostB.addObservingListItem(
        listId: any(named: 'listId'),
        objectName: any(named: 'objectName'),
        catalogId: any(named: 'catalogId'),
        objectType: any(named: 'objectType'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        magnitude: any(named: 'magnitude'),
        sizeArcmin: any(named: 'sizeArcmin'),
        notes: any(named: 'notes'),
      ),
    );
    expect(tester.takeException(), isNull);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'a duplicate add closes with a plain-language outcome, not a '
      'raw Dart exception', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 61,
      targetName: 'NGC6015',
      raHours: 15.86,
      decDegrees: 62.31,
      totalScore: 81,
      visibility: TargetVisibilityInfo(
        currentAltitude: 40,
        currentAzimuth: 40,
        airmass: 1.5,
        moonDistance: 101,
        peakAltitude: 62.6,
        hoursAboveMinAlt: 5,
      ),
      catalogId: 'NGC6015',
      objectType: 'Galaxy',
    );
    final stamp = DateTime.utc(2026, 7, 29);
    final list = ObservingList(
      id: 5,
      name: 'Summer Galaxies',
      sortOrder: 0,
      createdAt: stamp,
      updatedAt: stamp,
    );
    final backend = _MockNetworkBackend();
    // Membership unknown (host cannot answer), so the row stays enabled and the
    // add is attempted — the exact state the reporter hit.
    when(() => backend.getListsContaining('NGC6015'))
        .thenThrow(Exception('not supported'));
    when(
      () => backend.addObservingListItem(
        listId: 5,
        objectName: 'NGC6015',
        catalogId: 'NGC6015',
        objectType: 'Galaxy',
        ra: 15.86,
        dec: 62.31,
        magnitude: null,
        sizeArcmin: null,
        notes: null,
      ),
    ).thenThrow(
      const ServerError(
        code: 'conflict',
        message: 'NGC6015 is already in this list',
        httpStatus: 409,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          observingListsProvider.overrideWith((ref) => Stream.value([list])),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await _openObservingListDialog(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Summer Galaxies'));
    await tester.pumpAndSettle();

    // The dialog does not sit there accusing the user of a failure...
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('Failed to add item'), findsNothing);
    // ...it states what actually happened.
    expect(find.text('NGC6015 is already in this list'), findsOneWidget);

    await settleProviderTeardown(tester);
  });

  testWidgets(
      'a list that already holds the target says so instead of '
      'offering a no-op add', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 62,
      targetName: 'NGC6015',
      raHours: 15.86,
      decDegrees: 62.31,
      totalScore: 81,
      visibility: TargetVisibilityInfo(
        currentAltitude: 40,
        currentAzimuth: 40,
        airmass: 1.5,
        moonDistance: 101,
        peakAltitude: 62.6,
        hoursAboveMinAlt: 5,
      ),
      catalogId: 'NGC6015',
      objectType: 'Galaxy',
    );
    final stamp = DateTime.utc(2026, 7, 29);
    final list = ObservingList(
      id: 5,
      name: 'Summer Galaxies',
      sortOrder: 0,
      createdAt: stamp,
      updatedAt: stamp,
    );
    final backend = _MockNetworkBackend();
    when(() => backend.getListsContaining('NGC6015'))
        .thenAnswer((_) async => [list]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          observingListsProvider.overrideWith((ref) => Stream.value([list])),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await _openObservingListDialog(tester);
    await tester.pumpAndSettle();

    expect(find.text('Already added'), findsOneWidget);
    await tester.tap(find.text('Summer Galaxies'));
    await tester.pumpAndSettle();
    verifyNever(
      () => backend.addObservingListItem(
        listId: any(named: 'listId'),
        objectName: any(named: 'objectName'),
        catalogId: any(named: 'catalogId'),
        objectType: any(named: 'objectType'),
        ra: any(named: 'ra'),
        dec: any(named: 'dec'),
        magnitude: any(named: 'magnitude'),
        sizeArcmin: any(named: 'sizeArcmin'),
        notes: any(named: 'notes'),
      ),
    );

    await settleProviderTeardown(tester);
  });

  testWidgets('the altitude the target reaches is stated once, and named',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const suggestion = TargetSuggestion(
      targetId: 71,
      targetName: 'NGC6015',
      raHours: 15.86,
      decDegrees: 62.31,
      totalScore: 81,
      visibility: TargetVisibilityInfo(
        currentAltitude: 40,
        currentAzimuth: 40,
        airmass: 1.5,
        moonDistance: 101,
        peakAltitude: 62.6,
        hoursAboveMinAlt: 5,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider.overrideWith((ref) async => [suggestion]),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // A bare "Peak 63°" chip beside the chart's transit altitude looked like
    // the app contradicting itself. 06 SS Plan removes the chip row entirely:
    // the detail column states the altitude ONCE, as a labelled Readout, so
    // there is no second number to disagree with.
    expect(find.text('Peak 63°'), findsNothing);
    expect(find.textContaining('Peak in dark'), findsNothing,
        reason: 'the chip that needed the disambiguating label is gone');
    expect(find.text('TRANSIT'), findsWidgets,
        reason: 'the transit altitude is a labelled readout, not a bare chip');

    await settleProviderTeardown(tester);
  });

  // 06 SS Plan replaces the multi-column candidate grid with ONE column beside
  // a 380px detail panel: the extra width now buys the selected target's
  // field, readouts, altitude and facts rather than a second stack of rows.
  // The rows still stack, and the list still gives up its width to the panel.
  testWidgets('extra width buys the detail column, not a second card column',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const first = TargetSuggestion(
      targetId: 81,
      targetName: 'NGC6015',
      raHours: 15.86,
      decDegrees: 62.31,
      totalScore: 81,
      visibility: TargetVisibilityInfo(
        currentAltitude: 40,
        currentAzimuth: 40,
        airmass: 1.5,
        moonDistance: 101,
        peakAltitude: 62.6,
        hoursAboveMinAlt: 5,
      ),
    );
    const second = TargetSuggestion(
      targetId: 82,
      targetName: 'NGC6140',
      raHours: 16.35,
      decDegrees: 65.4,
      totalScore: 79,
      visibility: TargetVisibilityInfo(
        currentAltitude: 38,
        currentAzimuth: 42,
        airmass: 1.6,
        moonDistance: 99,
        peakAltitude: 60,
        hoursAboveMinAlt: 4.5,
      ),
    );

    Future<void> pumpAtWidth(double width) async {
      tester.view.physicalSize = Size(width, 1400);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            ..._commonOverrides(),
            tonightSuggestionsProvider
                .overrideWith((ref) async => [first, second]),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: PlannerScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Rect cardRect(int targetId) =>
        tester.getRect(find.byKey(ValueKey('candidate-$targetId')));

    await pumpAtWidth(1400);
    expect(
      cardRect(81).top,
      lessThan(cardRect(82).top),
      reason: 'the candidates are one column, in score order',
    );
    final narrowWidth = cardRect(81).width;

    await pumpAtWidth(2600);
    expect(
      cardRect(81).top,
      lessThan(cardRect(82).top),
      reason: 'still one column: the width goes to the detail panel',
    );
    expect(
      cardRect(81).width,
      greaterThan(narrowWidth),
      reason: 'the list keeps the width the 380px panel does not take',
    );
    expect(
      2600 - cardRect(81).right,
      greaterThan(300),
      reason: 'the detail column holds its 380px beside the list',
    );

    await settleProviderTeardown(tester);
  });

  // After switching the sort, the accessibility tree must report the first
  // candidate as the target the row's buttons act on.
  testWidgets(
      'a re-sort moves the candidate cards and their semantics together',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const brightest = TargetSuggestion(
      targetId: 91,
      targetName: 'gam Cyg',
      raHours: 20.37,
      decDegrees: 40.26,
      totalScore: 96,
      magnitude: 2.2,
      visibility: TargetVisibilityInfo(
        currentAltitude: 70,
        currentAzimuth: 90,
        airmass: 1.1,
        moonDistance: 122,
        peakAltitude: 89,
        hoursAboveMinAlt: 7,
      ),
    );
    const topScorer = TargetSuggestion(
      targetId: 92,
      targetName: 'M39',
      raHours: 21.53,
      decDegrees: 48.43,
      totalScore: 98,
      magnitude: 4.6,
      visibility: TargetVisibilityInfo(
        currentAltitude: 65,
        currentAzimuth: 95,
        airmass: 1.2,
        moonDistance: 118,
        peakAltitude: 81,
        hoursAboveMinAlt: 6,
      ),
    );

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          tonightSuggestionsProvider
              .overrideWith((ref) async => [topScorer, brightest]),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    Finder card(int id) => find.byKey(ValueKey('candidate-$id'));

    /// The name the card's own semantics subtree reports.
    String reportedName(int id) => tester
        .getSemantics(
          find.descendant(of: card(id), matching: find.byType(Text)).first,
        )
        .label;

    expect(tester.getRect(card(92)).top, lessThan(tester.getRect(card(91)).top),
        reason: 'sorted by score, M39 (98) leads');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlannerScreen)),
    );
    container.read(suggestionFilterProvider.notifier).state =
        const SuggestionFilterState(plannerSort: PlannerSortMode.magnitude);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getRect(card(91)).top, lessThan(tester.getRect(card(92)).top),
        reason: 'sorted by magnitude, gam Cyg (2.2) leads');
    // The tree kept a stale copy of the previously-first card, so the reported
    // leading candidate was not the one the row's buttons acted on.
    expect(reportedName(91), contains('gam Cyg'));
    expect(reportedName(92), contains('M39'));

    semantics.dispose();
    await settleProviderTeardown(tester);
  });

  testWidgets(
      'the object-type filter opens in the same kind of surface as its '
      'sibling chips', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1600, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Type: any'));
    // Fixed pumps, not pumpAndSettle: this screen carries a perpetual
    // animation (tour prompt / skeleton shimmer) that never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Magnitude / Size / Alt / Moon all use a centered dialog. "Type" was the
    // one chip that threw a bottom sheet, so two neighbouring chips opened
    // their panels at opposite ends of the window.
    expect(find.text('Object types'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    final dialog = tester.getRect(find.byType(AlertDialog));
    final chip = tester.getRect(find.text('Type: any'));
    expect(
      (dialog.center.dy - 500).abs() < 250,
      isTrue,
      reason: 'the panel should be centered like its siblings, not pinned to '
          'the bottom of a 1000px window (was ~y=870); got $dialog for a chip '
          'at $chip',
    );

    await settleProviderTeardown(tester);
  });
}
