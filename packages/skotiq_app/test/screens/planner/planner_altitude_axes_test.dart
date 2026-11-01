// Plan > Tonight's detail pane draws the selected target's altitude over the
// night. Without a scale the peak and the time it clears the limit cannot be
// read off the curve, so the chart labels degrees and clock hours.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../scheduler/scheduler_test_doubles.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40.0, longitude: -75.0);
}

const _ngc6015 = TargetSuggestion(
  targetId: 7,
  targetName: 'NGC 6015',
  raHours: 15.86,
  decDegrees: 62.3,
  totalScore: 76,
  visibility: TargetVisibilityInfo(
    currentAltitude: 55,
    currentAzimuth: 30,
    airmass: 1.2,
    moonDistance: 102,
    peakAltitude: 62,
    hoursAboveMinAlt: 5,
  ),
  objectType: 'Galaxy',
  magnitude: 11.2,
);

List<Override> _overrides() {
  return [
    tonightSuggestionsProvider.overrideWith((ref) async => [_ngc6015]),
    smartNightExposureContextProvider.overrideWith((ref) async => null),
    appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
    allTargetProgressProvider.overrideWith(
      (ref) async => <int, TargetProgress>{},
    ),
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
    projectListProvider.overrideWith((ref) => Stream.value(const <Project>[])),
    activeProjectProgressProvider.overrideWith((ref) async => null),
    weekForecastProvider.overrideWith(
      (ref) async => const WeekForecast.unavailable('Forecast off in tests.'),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpPlanner(WidgetTester tester, {Locale? locale}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [..._overrides()],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          locale: locale,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    // Localization delegates resolve on a microtask, then:
    // settings future -> observer location -> optimization plan.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the altitude chart labels its altitude and time axes',
      (tester) async {
    await pumpPlanner(tester);

    expect(find.text('90°'), findsOneWidget);
    expect(find.text('60°'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'^\d\dh$').hasMatch(w.data ?? ''),
      ),
      findsWidgets,
      reason: 'the hours along the bottom of the chart are labeled',
    );
  });
}
