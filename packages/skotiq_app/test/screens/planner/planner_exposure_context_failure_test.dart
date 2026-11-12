// Plan Tonight on a companion read "Failed to generate plan" for good when
// the Smart Night exposure context could not be read: the whole plan failed
// on an input that only refines sub lengths, and Retry re-awaited the cached
// failure. The plan now ranks tonight's targets without it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
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

List<Override> _overrides(double integrationHours, Override exposureContext) {
  return [
    tonightSuggestionsProvider.overrideWith((ref) async => [_ngc7160]),
    exposureContext,
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

  testWidgets('a failed exposure context still ranks tonight\'s targets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(
          4,
          smartNightExposureContextProvider.overrideWith(
            (ref) async => throw StateError('host did not answer'),
          ),
        ),
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Failed to generate plan'), findsNothing);
    expect(find.textContaining('NGC 7160'), findsWidgets);
  });

  testWidgets('a failure that is not a missing site offers Retry, not Settings',
      (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final overrides = _overrides(
      4,
      smartNightExposureContextProvider.overrideWith((ref) async => null),
    )..[0] = tonightSuggestionsProvider.overrideWith(
        (ref) async => throw StateError('Bad state: No element'),
      );
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
          supportedLocales: SkotiqLocalizations.supportedLocales,
          home: const Scaffold(body: PlannerScreen()),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Failed to generate plan'), findsOneWidget);
  });
}
