// The Rationale block at the bottom of the Recommendation tab explains the
// OPTIMIZER's pick, which is not necessarily the card sitting above it — a
// search or an active filter can leave a different hero card on screen. Titled
// only "Why this plan was chosen", it read as an explanation of that card and
// contradicted every number on it (peak altitude, moon separation, hours).
// It now names the target its numbers belong to.
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
          localizationsDelegates:
              SkotiqLocalizations.localizationsDelegates,
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

  testWidgets('the Rationale section names the target it explains',
      (tester) async {
    await pumpPlanner(tester);

    expect(find.text('Why NGC 6015 was chosen'), findsOneWidget);
    expect(find.text('Why this plan was chosen'), findsNothing);
  });

  // The named subtitle must go through the translation table, not be spliced
  // together in Dart: hard-coding 'Why $name was chosen' silently downgraded
  // the Spanish build from a translated subtitle to an English one, and the
  // key-parity test cannot see a string that never became a key.
  testWidgets('the named subtitle is translated, not hard-coded English',
      (tester) async {
    await pumpPlanner(tester, locale: const Locale('es'));

    expect(find.text('Por que se eligio NGC 6015'), findsOneWidget);
    expect(find.textContaining('was chosen'), findsNothing);
  });
}
