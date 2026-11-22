// The planner's Tonight tab under midnight sun.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'scheduler_test_doubles.dart';
import '../../harness/provider_teardown.dart';
import 'package:skotiq_core/utils.dart';

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

class _FakeCatalogState extends StateNotifier<CatalogState>
    implements CatalogStateNotifier {
  _FakeCatalogState()
      : super(const CatalogState(
          dsoCatalogStatus: CatalogStatus(
            catalog: SkyCatalog.dso,
            state: CatalogInstallStatus.installed,
            installedPath: 'NGC.csv',
          ),
        ));

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'Unexpected CatalogStateNotifier call: ${invocation.memberName}');
}

class _StoppedClock implements Clock {
  const _StoppedClock(this.at);

  final DateTime at;

  @override
  DateTime now() => at;

  @override
  DateTime nowUtc() => at.toUtc();

  @override
  Duration get utcOffset => at.timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

// Midnight sun: tonight's suggestions are empty, as Smart Night refuses the
// same night, and the planner says why instead of blaming the filters.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(''));

  Future<void> pumpPlanner(WidgetTester tester, LocationSettings site) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._commonOverrides(),
          appObserverLocationProvider.overrideWithValue(site),
          clockProvider.overrideWithValue(
            _StoppedClock(DateTime.utc(2024, 6, 21, 22)),
          ),
          catalogStateProvider.overrideWith((ref) => _FakeCatalogState()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('under midnight sun the planner says the Sun does not set',
      (tester) async {
    await pumpPlanner(
      tester,
      const LocationSettings(latitude: 78.2, longitude: 15.6),
    );
    expect(find.text('The Sun does not set here tonight'), findsOneWidget);
    expect(find.text('No targets match these filters'), findsNothing);
    await settleProviderTeardown(tester);
  });

  testWidgets('a night with dark keeps the filters empty state',
      (tester) async {
    await pumpPlanner(
      tester,
      const LocationSettings(latitude: 40.0, longitude: -75.0),
    );
    expect(find.text('The Sun does not set here tonight'), findsNothing);
    expect(find.text('No targets match these filters'), findsOneWidget);
    await settleProviderTeardown(tester);
  });
}
