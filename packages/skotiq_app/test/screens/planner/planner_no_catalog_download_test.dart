// A fresh install's planner offers the catalog download itself.
//
// Walk-2 F8: the whole planner was one empty state, "Install the object
// catalog", whose only action led to Settings > Catalogs, five cards down to
// the button. The download, its size, its progress and its failure now live
// where the user finds out the catalog is missing.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../scheduler/scheduler_test_doubles.dart';
import '../../harness/provider_teardown.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

class _MockLogger extends Mock implements LoggingService {}

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
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(''));

  testWidgets('the empty planner downloads the catalog in place',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);

    final download = Completer<void>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._commonOverrides(),
          appObserverLocationProvider.overrideWithValue(
            const LocationSettings(latitude: 40.0, longitude: -75.0),
          ),
          skyCatalogInstallProvider.overrideWith(
            (ref) => SkyCatalogInstallNotifier(
              (catalog, {onProgress, isCancelled}) async {
                await download.future;
                return null;
              },
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('The planner needs the object catalog'), findsOneWidget);
    expect(find.textContaining('about 60 MiB'), findsOneWidget);
    final button = find.widgetWithText(SkotiqButton, 'Download catalogs (60 MiB)');
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Downloading the sky catalogs'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Cancel'), findsOneWidget);

    download.completeError(
      const CatalogDownloadException(
        phase: 'download',
        message: 'Could not reach github.com or codeberg.org.',
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('The catalogs did not download'), findsOneWidget);
    expect(
      find.textContaining('Could not reach github.com or codeberg.org.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Try again'), findsOneWidget);

    await settleProviderTeardown(tester);
  });
}
