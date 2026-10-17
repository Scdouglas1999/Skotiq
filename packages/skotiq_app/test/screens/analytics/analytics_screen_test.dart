// Tests for the Analytics screen tab structure, Diagnostics tab included.
// We don't spin up the full Riverpod graph
// (which would require a real drift database, an Ffi backend, and the full
// event bus). Instead we override the stream providers each tab reads with
// deterministic test doubles that emit a single empty list, so the tab
// chrome renders without the heavy database stack.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../../harness/provider_teardown.dart';

/// Test-only TutorialNotifier that reports tutorials disabled so the
/// `ContextualTourPrompt` short-circuits before scheduling its 500 ms
/// `Future.delayed`. Without this override the test framework reports a
/// pending timer at teardown because the prompt is still waiting to fade in.
class _TutorialsDisabledNotifier extends TutorialNotifier {
  _TutorialsDisabledNotifier() : super(_NoopTutorialProgressDao()) {
    // ignore: invalid_use_of_protected_member
    state = const TutorialProgress(tutorialsEnabled: false);
  }
}

class _NoopTutorialProgressDao implements TutorialProgressDao {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    // The disabled notifier never reads from the DAO; if any helper does,
    // surface it loudly rather than swallow it.
    throw UnimplementedError(
      'NoopTutorialProgressDao.${invocation.memberName} called in test',
    );
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

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
    tutorialProvider.overrideWith((ref) => _TutorialsDisabledNotifier()),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('analyticsTabFromQuery', () {
    test('returns null for null input', () {
      expect(analyticsTabFromQuery(null), isNull);
    });

    test('returns null for an unrecognised value', () {
      expect(analyticsTabFromQuery('made-up-tab'), isNull);
    });

    test('maps canonical tab names', () {
      expect(analyticsTabFromQuery('session'), AnalyticsTab.session);
      expect(analyticsTabFromQuery('history'), AnalyticsTab.history);
      expect(analyticsTabFromQuery('projects'), AnalyticsTab.projects);
      expect(analyticsTabFromQuery('equipment'), AnalyticsTab.equipment);
      expect(analyticsTabFromQuery('science'), AnalyticsTab.science);
      expect(analyticsTabFromQuery('diagnostics'), AnalyticsTab.diagnostics);
    });

    test('accepts case-insensitive equipment aliases', () {
      expect(analyticsTabFromQuery('Diagnostics'), AnalyticsTab.diagnostics);
      expect(analyticsTabFromQuery('equipment-stats'), AnalyticsTab.equipment);
      expect(analyticsTabFromQuery('equipmentstats'), AnalyticsTab.equipment);
    });

    test('Diagnostics is the right-most enum entry', () {
      expect(
        AnalyticsTab.values.last,
        AnalyticsTab.diagnostics,
        reason:
            'UX consolidation places Diagnostics as the right-most Analytics tab',
      );
    });
  });

  testWidgets('renders all analytics tabs including Diagnostics',
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
        'Projects',
        // 06 names this tab 'Equipment'; the copy rules put it in
        // sentence case.
        'Equipment',
        'Science',
        'Diagnostics',
      ],
    );
    expect(find.text('Session'), findsWidgets);
    expect(find.text('History'), findsWidgets);
    expect(find.text('Diagnostics'), findsWidgets);
  });

  testWidgets('?tab=diagnostics selects the Diagnostics tab on initial render',
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
          home: const Scaffold(
            body: AnalyticsScreen(initialTabQuery: 'diagnostics'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      _selectedAdaptiveTabIndex(tester),
      AnalyticsTab.diagnostics.index,
      reason: '?tab=diagnostics must select the right-most Diagnostics tab.',
    );
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

  testWidgets('remote session detail directs review to the imaging host',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final backend = _MockNetworkBackend();
    final session = ImagingSession(
      id: 7,
      name: 'Remote M42',
      startTime: DateTime(2026, 7, 13),
      totalExposures: 12,
      successfulExposures: 12,
      failedExposures: 0,
      totalIntegrationSecs: 1440,
      autofocusCount: 1,
      status: 'completed',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          dbSessionImagesProvider(7).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.history),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Remote M42'));
    await tester.pumpAndSettle();

    // The refusal is ON the control, and in the NAME rather than only in the
    // tooltip: Flutter publishes `tooltip:` as `SemanticsProperties.tooltip`,
    // which the Linux AT-SPI bridge does not fold into the accessible name, so
    // a tooltip-only refusal on an icon-only button reaches a pointer and
    // nobody else. Read off the published node for that reason.
    final handle = tester.ensureSemantics();
    final reviewButton = find.byKey(const ValueKey('session_detail_review'));
    expect(reviewButton, findsOneWidget);
    expect(
      tester.getSemantics(reviewButton).label,
      allOf(
        startsWith('Review on imaging host — '),
        contains('Session Review works on the imaging host'),
      ),
    );
    expect(
      tester.widget<SkotiqIconButton>(reviewButton).tooltip,
      startsWith('Session Review works on the imaging host'),
    );
    expect(tester.widget<SkotiqIconButton>(reviewButton).onPressed, isNull);
    handle.dispose();

    await tester.ensureVisible(reviewButton);
    await tester.pump();
    await tester.tap(reviewButton, warnIfMissed: false);
    await tester.pump();

    expect(
      reviewButton,
      findsOneWidget,
      reason: 'the dialog stays up; a disabled action navigates nowhere',
    );

    await settleProviderTeardown(tester);
  });

  // Share is offered only where an OS share sheet exists: `shareXFiles()` is
  // unimplemented on the shipping desktop build. The CSV button beside it
  // covers desktop.
  testWidgets('desktop session detail offers no Share action', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final session = ImagingSession(
      id: 9,
      name: 'Local M81',
      startTime: DateTime(2026, 7, 25),
      totalExposures: 8,
      successfulExposures: 8,
      failedExposures: 0,
      totalIntegrationSecs: 24,
      autofocusCount: 0,
      status: 'completed',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          ..._commonOverrides(),
          allSessionsProvider.overrideWith(
            (ref) => Stream<List<ImagingSession>>.value([session]),
          ),
          dbSessionImagesProvider(9).overrideWith(
            (ref) => Stream<List<DbCapturedImage>>.value(const []),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: AnalyticsScreen(initialTab: AnalyticsTab.history),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Local M81'));
    // pump, not pumpAndSettle: in local mode the screen's image/thumbnail
    // futures never go idle.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The dialog is open (its export actions are there)…
    expect(findIconButtonByTooltip('Export to CSV'), findsOneWidget);
    // …and the unimplemented-on-desktop Share action is not.
    expect(findIconButtonByTooltip('Share'), findsNothing);

    await settleProviderTeardown(tester);
  }, skip: Platform.isAndroid || Platform.isIOS);

  // Phone responsiveness: the six-tab bar must not overflow on a phone in
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

        // The AdaptiveTabBar exists and renders all six tabs (collapsed to
        // icons below 480px, so we assert on the widget's tab list, not text).
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
  final bar = tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar));
  return bar.selectedIndex;
}

/// Finds a [SkotiqIconButton] by the tooltip it publishes.
///
/// `find.byTooltip` cannot: SkotiqIconButton draws its own overlay tooltip
/// rather than wrapping a Material [Tooltip]. The string is still the button's
/// Semantics label, so this is the same contract read from the widget.
Finder findIconButtonByTooltip(String tooltip) => find.byWidgetPredicate(
      (widget) => widget is SkotiqIconButton && widget.tooltip == tooltip,
      description: 'SkotiqIconButton(tooltip: "$tooltip")',
    );
