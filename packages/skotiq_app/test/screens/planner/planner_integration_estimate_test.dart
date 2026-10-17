// The Plan Tonight detail column's "Estimated integration" row.
//
// The old hero card carried the same number twice: a chip that read it to a
// tenth of an hour and a line under it that spelled it out in hours and
// minutes. The spelling-out floored the hours and ROUNDED the minutes
// independently, so a night just under four hours printed "3h 60m" beside
// "~4.0h integration" — a clock face nobody owns, contradicting the chip an
// inch above it. The Observatory detail column states the number ONCE, in the
// key/value block; the carry still has to be right, which is what this checks.
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

const _targetId = 7;

const _ngc7160 = TargetSuggestion(
  targetId: _targetId,
  targetName: 'NGC 7160',
  raHours: 21.9,
  decDegrees: 62.6,
  totalScore: 81,
  visibility: TargetVisibilityInfo(
    currentAltitude: 61,
    currentAzimuth: 40,
    airmass: 1.1,
    moonDistance: 96,
    peakAltitude: 74,
    hoursAboveMinAlt: 6,
  ),
  objectType: 'Open cluster',
  magnitude: 6.1,
);

TargetIntegrationPreview _preview(double hours) => TargetIntegrationPreview(
      estimatedIntegrationHours: hours,
      usableWindowHours: 6,
      subExposureSecs: 120,
      filterNames: const ['Lum'],
    );

List<Override> _overrides(double integrationHours) {
  return [
    tonightSuggestionsProvider.overrideWith((ref) async => [_ngc7160]),
    smartNightExposureContextProvider.overrideWith((ref) async => null),
    plannerTargetIntegrationPreviewProvider(_targetId)
        .overrideWith((ref) async => _preview(integrationHours)),
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

  Future<void> pumpPlanner(WidgetTester tester, double integrationHours) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(integrationHours),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  // Both sides of the half-minute the rounding turns on, because a carry that
  // fires one minute early is the same defect wearing the other sign.
  testWidgets('59.5 minutes carries into the hour', (tester) async {
    await pumpPlanner(tester, 3 + 59.5 / 60);

    expect(find.text('4h'), findsOneWidget);
    expect(find.text('3h 60m'), findsNothing);
  });

  testWidgets('59.4 minutes stays in the hour it is in', (tester) async {
    await pumpPlanner(tester, 3 + 59.4 / 60);

    expect(find.text('3h 59m'), findsOneWidget);
  });

  testWidgets('a whole-hour estimate under an hour still reads in minutes',
      (tester) async {
    await pumpPlanner(tester, 59.6 / 60);

    // The carry has to take the hour with it: 59.6 minutes is "1h", not
    // "0h 60m" and not "60m".
    expect(find.text('1h'), findsOneWidget);
  });
}
