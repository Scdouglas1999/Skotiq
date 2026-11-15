// Tests for the Analytics screen tab structure.
// We don't spin up the full Riverpod graph
// (which would require a real drift database, an Ffi backend, and the full
// event bus). Instead we override the stream providers each tab reads with
// deterministic test doubles that emit a single empty list, so the tab
// chrome renders without the heavy database stack.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

List<Override> _commonOverrides() {
  return [
    allSessionsProvider.overrideWith(
      (ref) => Stream<List<ImagingSession>>.value(const []),
    ),
    standaloneImagesProvider.overrideWith(
      (ref) => Stream<List<DbCapturedImage>>.value(const []),
    ),
    allDbImagesProvider.overrideWith(
      (ref) => Stream<List<DbCapturedImage>>.value(const []),
    ),
    sequenceRunsProvider.overrideWith(
      (ref) => Stream<List<SequenceRun>>.value(const []),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnalyticsTab.fromQuery', () {
    test('returns null for null input', () {
      expect(AnalyticsTab.fromQuery(null), isNull);
    });

    test('returns null for an unrecognized value', () {
      expect(AnalyticsTab.fromQuery('made-up-tab'), isNull);
    });

    test('maps canonical tab names', () {
      expect(AnalyticsTab.fromQuery('session'), AnalyticsTab.session);
      expect(AnalyticsTab.fromQuery('history'), AnalyticsTab.history);
      expect(AnalyticsTab.fromQuery('science'), AnalyticsTab.science);
    });

    test('the tabs that merged into others name no tab of their own', () {
      expect(AnalyticsTab.fromQuery('Session'), AnalyticsTab.session);
      for (final word in ['equipment', 'equipment-stats', 'diagnostics']) {
        expect(AnalyticsTab.fromQuery(word), isNull, reason: word);
      }
    });
  });

  testWidgets('renders the analytics tabs',
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
          home: const Scaffold(body: AnalyticsScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // The tab strip is now an AdaptiveTabBar; each tab still renders its label
    // as Text (labels only collapse to icons below 480px width, and this is a
    // 1400px desktop viewport).
    // Labels can also appear inside the (offstage) tab bodies, so assert each
    // is present at least once. The structural one-per-enum guarantee is
    // covered separately by the AdaptiveTabBar.tabs length assertions.
    final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
    expect(
      bar.tabs.map((t) => t.label).toList(),
      const [
        'Session',
        'History',
        'Science',
      ],
    );
    expect(find.text('Session'), findsWidgets);
    expect(find.text('History'), findsWidgets);
  });

  testWidgets('a link to the Optics view opens Session on it', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._commonOverrides(),
          scienceDefaultSessionProvider.overrideWith((ref) async => 3),
          dbSessionImagesProvider.overrideWith(
            (ref, id) => Stream.value(const <DbCapturedImage>[]),
          ),
          sessionPsfTilesProvider.overrideWith(
            (ref, id) => Stream.value(const <PsfFieldTileRow>[]),
          ),
          sessionResidualVectorsProvider.overrideWith(
            (ref, id) => Stream.value(const <AstrometryResidualVectorRow>[]),
          ),
          allSessionsProvider.overrideWith(
            (ref) => Stream.value([
              ImagingSession(
                id: 3,
                name: 'A night',
                startTime: DateTime(2026, 7, 13, 21),
                endTime: DateTime(2026, 7, 13, 23),
                totalExposures: 0,
                successfulExposures: 0,
                failedExposures: 0,
                totalIntegrationSecs: 0,
                autofocusCount: 0,
                status: 'completed',
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: AnalyticsScreen(
              initialTab: AnalyticsTab.session,
              initialSessionView: SessionView.optics,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(_selectedAdaptiveTabIndex(tester), AnalyticsTab.session.index);
    final views = tester.widget<SegmentedControl>(
      find.byWidgetPredicate(
        (w) => w is SegmentedControl && w.segments.contains('Optics'),
      ),
    );
    expect(views.selectedIndex, SessionView.optics.index);
    expect(
      find.text('Select an imaging session to analyze'),
      findsNothing,
      reason: 'the Optics view analyzes the session the tab is reviewing',
    );
    expect(tester.takeException(), isNull);
  });

  // "View all alerts" did nothing the second time: the operator had moved to
  // another tab by hand, the location still named the link's tab, and going
  // to the location the router is already at changes nothing.
  testWidgets('a link to a tab works again after the tab was changed by hand',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final router = GoRouter(
      initialLocation: AppRoutes.analytics(tab: AnalyticsTab.science),
      routes: [
        GoRoute(
          path: AppRoute.analytics.path,
          builder: (context, state) => Scaffold(
            body: AnalyticsScreen(
              initialTab:
                  AnalyticsTab.fromQuery(state.uri.queryParameters['tab']),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _commonOverrides(),
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_selectedAdaptiveTabIndex(tester), AnalyticsTab.science.index);

    await tester.tap(find.text('History').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_selectedAdaptiveTabIndex(tester), AnalyticsTab.history.index);
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      AppRoutes.analytics(tab: AnalyticsTab.history),
    );

    router.go(AppRoutes.analytics(tab: AnalyticsTab.science));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_selectedAdaptiveTabIndex(tester), AnalyticsTab.science.index);
  });

  testWidgets('defaults to Session when no query param is supplied',
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
          home: const Scaffold(body: AnalyticsScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(_selectedAdaptiveTabIndex(tester), AnalyticsTab.session.index);
  });

  // Phone responsiveness: the tab bar must not overflow on a phone in
  // either orientation, and every tab must remain reachable (the bar scrolls).
  group('Analytics phone responsiveness (AdaptiveTabBar)', () {
    Future<void> pumpAt(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: _commonOverrides(),
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: AnalyticsScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    const phoneSizes = <Size>[
      Size(360, 640),
      Size(390, 844),
      Size(430, 932),
      // Rotated (landscape).
      Size(640, 360),
      Size(844, 390),
      Size(932, 430),
    ];

    for (final size in phoneSizes) {
      testWidgets(
          'no overflow + tab bar present at ${size.width}x${size.height}',
          (tester) async {
        await pumpAt(tester, size);

        // The AdaptiveTabBar exists and renders every tab.
        expect(find.byType(AdaptiveTabBar), findsOneWidget);
        final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
        expect(bar.tabs.length, AnalyticsTab.values.length);

        // No RenderFlex overflow anywhere on the screen.
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
        'tabs are reachable on a 360px phone — selecting a non-default tab '
        'switches the active body without overflowing the bar', (tester) async {
      await pumpAt(tester, const Size(360, 640));

      // The bar is a horizontally scrolling list; the selected tab can be
      // changed programmatically via onSelected and the bar keeps it visible.
      // We switch to History (a tab whose body this screen owns and which is
      // overflow-clean on a phone) to prove the phone tab-switch path works.
      final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
      bar.onSelected(AnalyticsTab.history.index);
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        _selectedAdaptiveTabIndex(tester),
        AnalyticsTab.history.index,
        reason: 'Selecting a tab on a 360px phone must update the selection; '
            'the AdaptiveTabBar scrolls it into view instead of overflowing.',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// Reads the live [AdaptiveTabBar.selectedIndex] from the pumped tree. The tab
/// bar is the single source of truth for which Analytics tab is active.
int _selectedAdaptiveTabIndex(WidgetTester tester) {
  // The page header's bar is the first; Science has a tab row of its own.
  final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar).first);
  return bar.selectedIndex;
}
